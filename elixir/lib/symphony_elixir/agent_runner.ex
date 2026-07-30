defmodule SymphonyElixir.AgentRunner do
  @moduledoc """
  Executes a single issue in its workspace using the configured coding agent.
  """

  import Bitwise, only: [<<<: 2]
  require Logger
  alias SymphonyElixir.Agent.Adapter
  alias SymphonyElixir.{Config, Linear.Issue, PromptBuilder, Tracker, Workspace}

  @empty_turn_threshold_ms 5_000
  @max_consecutive_empty_turns 3
  @empty_turn_backoff_base_ms 2_000

  @spec run(map(), pid() | nil, keyword()) :: :ok | {:error, term()}
  def run(issue, codex_update_recipient \\ nil, opts \\ []) do
    Logger.info("Starting agent run for #{issue_context(issue)}")

    case Workspace.create_for_issue(issue) do
      {:ok, workspace} ->
        try do
          with :ok <- Workspace.run_before_run_hook(workspace, issue),
               :ok <- run_codex_turns(workspace, issue, codex_update_recipient, opts) do
            :ok
          else
            {:error, reason} ->
              Logger.error("Agent run failed for #{issue_context(issue)}: #{inspect(reason)}")
              {:error, reason}
          end
        after
          Workspace.run_after_run_hook(workspace, issue)
        end

      {:error, reason} ->
        Logger.error("Agent run failed for #{issue_context(issue)}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp codex_message_handler(recipient, issue) do
    fn message ->
      send_codex_update(recipient, issue, message)
    end
  end

  defp send_codex_update(recipient, %Issue{id: issue_id}, message)
       when is_binary(issue_id) and is_pid(recipient) do
    send(recipient, {:codex_worker_update, issue_id, message})
    :ok
  end

  defp send_codex_update(_recipient, _issue, _message), do: :ok

  defp run_codex_turns(workspace, issue, codex_update_recipient, opts) do
    issue_state_fetcher = Keyword.get(opts, :issue_state_fetcher, &Tracker.fetch_issue_states_by_ids/1)
    adapter_type = Config.settings!().agent.agent_adapter
    adapter = Adapter.create(adapter_type)

    # Adapters like Claude handle multi-turn internally via --max-turns,
    # so the external loop should only run once. Codex uses the external
    # loop because its app-server thread persists context between turns.
    external_max_turns =
      case adapter_type do
        "codex" -> Keyword.get(opts, :max_turns, Config.settings!().agent.max_turns)
        _ -> 1
      end

    with {:ok, session} <- adapter.start_session(workspace) do
      try do
        do_run_codex_turns(
          adapter,
          session,
          workspace,
          issue,
          codex_update_recipient,
          opts,
          issue_state_fetcher,
          1,
          external_max_turns,
          0
        )
      after
        adapter.stop_session(session)
      end
    end
  end

  defp do_run_codex_turns(
         adapter,
         app_session,
         workspace,
         issue,
         codex_update_recipient,
         opts,
         issue_state_fetcher,
         turn_number,
         max_turns,
         consecutive_empty_turns
       ) do
    turn_started_at_ms = System.monotonic_time(:millisecond)
    prompt = build_turn_prompt(issue, opts, turn_number, max_turns)

    with {:ok, turn_session} <-
           adapter.run_turn(
             app_session,
             prompt,
             issue,
             on_message: codex_message_handler(codex_update_recipient, issue)
           ) do
      turn_elapsed_ms = System.monotonic_time(:millisecond) - turn_started_at_ms
      empty_turn? = turn_elapsed_ms < @empty_turn_threshold_ms

      Logger.info("Completed agent run for #{issue_context(issue)} session_id=#{turn_session[:session_id]} workspace=#{workspace} turn=#{turn_number}/#{max_turns} elapsed_ms=#{turn_elapsed_ms}")

      case continue_with_issue?(issue, issue_state_fetcher) do
        {:continue, refreshed_issue} when turn_number < max_turns ->
          next_consecutive_empty_turns = if empty_turn?, do: consecutive_empty_turns + 1, else: 0

          if next_consecutive_empty_turns >= @max_consecutive_empty_turns do
            Logger.warning(
              "Empty turn circuit breaker tripped for #{issue_context(refreshed_issue)} consecutive_empty_turns=#{next_consecutive_empty_turns} threshold_ms=#{@empty_turn_threshold_ms}; returning control to orchestrator"
            )

            :ok
          else
            maybe_backoff_after_empty_turn(refreshed_issue, turn_number, max_turns, next_consecutive_empty_turns)

            Logger.info("Continuing agent run for #{issue_context(refreshed_issue)} after normal turn completion turn=#{turn_number}/#{max_turns}")

            do_run_codex_turns(
              adapter,
              app_session,
              workspace,
              refreshed_issue,
              codex_update_recipient,
              opts,
              issue_state_fetcher,
              turn_number + 1,
              max_turns,
              next_consecutive_empty_turns
            )
          end

        {:continue, refreshed_issue} ->
          Logger.info("Reached agent.max_turns for #{issue_context(refreshed_issue)} with issue still active; returning control to orchestrator")

          :ok

        {:done, _refreshed_issue} ->
          :ok

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp maybe_backoff_after_empty_turn(_issue, _turn_number, _max_turns, 0), do: :ok

  defp maybe_backoff_after_empty_turn(issue, turn_number, max_turns, consecutive_empty_turns) do
    backoff_ms = @empty_turn_backoff_base_ms * (1 <<< min(consecutive_empty_turns - 1, 4))

    Logger.info("Empty turn detected for #{issue_context(issue)} turn=#{turn_number}/#{max_turns} consecutive_empty_turns=#{consecutive_empty_turns}; backing off #{backoff_ms}ms")

    Process.sleep(backoff_ms)
  end

  defp build_turn_prompt(issue, opts, 1, _max_turns), do: PromptBuilder.build_prompt(issue, opts)

  defp build_turn_prompt(_issue, _opts, turn_number, max_turns) do
    """
    Continuation guidance:

    - The previous Codex turn completed normally, but the Linear issue is still in an active state.
    - This is continuation turn ##{turn_number} of #{max_turns} for the current agent run.
    - Resume from the current workspace and workpad state instead of restarting from scratch.
    - The original task instructions and prior turn context are already present in this thread, so do not restate them before acting.
    - Focus on the remaining ticket work and do not end the turn while the issue stays active unless you are truly blocked.
    """
  end

  defp continue_with_issue?(%Issue{id: issue_id} = issue, issue_state_fetcher) when is_binary(issue_id) do
    case issue_state_fetcher.([issue_id]) do
      {:ok, [%Issue{} = refreshed_issue | _]} ->
        if active_issue_state?(refreshed_issue.state) do
          {:continue, refreshed_issue}
        else
          {:done, refreshed_issue}
        end

      {:ok, []} ->
        {:done, issue}

      {:error, reason} ->
        {:error, {:issue_state_refresh_failed, reason}}
    end
  end

  defp continue_with_issue?(issue, _issue_state_fetcher), do: {:done, issue}

  defp active_issue_state?(state_name) when is_binary(state_name) do
    normalized_state = normalize_issue_state(state_name)

    Config.settings!().tracker.active_states
    |> Enum.any?(fn active_state -> normalize_issue_state(active_state) == normalized_state end)
  end

  defp active_issue_state?(_state_name), do: false

  defp normalize_issue_state(state_name) when is_binary(state_name) do
    state_name
    |> String.trim()
    |> String.downcase()
  end

  defp issue_context(%Issue{id: issue_id, identifier: identifier}) do
    "issue_id=#{issue_id} issue_identifier=#{identifier}"
  end
end
