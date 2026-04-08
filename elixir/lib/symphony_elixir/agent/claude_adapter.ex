defmodule SymphonyElixir.Agent.ClaudeAdapter do
  @moduledoc """
  Adapter that runs Claude Code CLI in `--print --output-format stream-json` mode.

  Each `run_turn/4` spawns a fresh `claude` process. The session holds workspace
  configuration between turns.
  """

  @behaviour SymphonyElixir.Agent.Behaviour

  require Logger
  alias SymphonyElixir.{Config, PathSafety}

  @port_line_bytes 1_048_576
  @max_stream_log_bytes 1_000

  # ── Behaviour callbacks ──────────────────────────────────────────────

  @impl true
  def start_session(workspace, _opts \\ []) do
    with {:ok, expanded} <- validate_workspace(workspace) do
      {:ok,
       %{
         workspace: expanded,
         claude_config: Config.settings!().claude
       }}
    end
  end

  @impl true
  def run_turn(
        %{workspace: workspace, claude_config: claude_config} = _session,
        prompt,
        issue,
        opts \\ []
      ) do
    on_message = Keyword.get(opts, :on_message, &default_on_message/1)
    session_id = generate_session_id()

    case run_claude(workspace, prompt, issue, claude_config, session_id, on_message) do
      {:ok, result} ->
        {:ok, Map.put(result, :session_id, session_id)}

      {:error, reason} ->
        Logger.warning(
          "Claude session ended with error for #{issue_context(issue)} session_id=#{session_id}: #{inspect(reason)}"
        )

        emit_message(on_message, :turn_ended_with_error, %{session_id: session_id, reason: reason})
        {:error, reason}
    end
  end

  @impl true
  def stop_session(_session), do: :ok

  # ── Port lifecycle ───────────────────────────────────────────────────

  defp run_claude(workspace, prompt, issue, claude_config, session_id, on_message) do
    prompt_file = write_prompt_file(prompt)
    mcp_config_file = write_mcp_config()

    try do
      command = build_command(claude_config, prompt_file, mcp_config_file)
      env = build_env(claude_config)

      Logger.info(
        "Starting Claude session for #{issue_context(issue)} session_id=#{session_id} workspace=#{workspace}"
      )

      emit_message(on_message, :session_started, %{session_id: session_id})

      case start_port(command, workspace, env) do
        {:ok, port} ->
          os_pid = port_os_pid(port)

          emit_message(on_message, :session_started, %{
            session_id: session_id,
            codex_app_server_pid: os_pid
          })

          result =
            receive_loop(
              port,
              on_message,
              claude_config.turn_timeout_ms,
              claude_config.stall_timeout_ms,
              "",
              session_id,
              System.monotonic_time(:millisecond)
            )

          case result do
            {:ok, result_data} ->
              log_session_result(issue, session_id, result_data)
              {:ok, result_data}

            {:error, reason} = error ->
              Logger.error(
                "Claude session failed for #{issue_context(issue)} session_id=#{session_id}: #{inspect(reason)}"
              )

              safe_close_port(port)
              error
          end

        {:error, _} = error ->
          emit_message(on_message, :startup_failed, %{reason: error})
          error
      end
    after
      File.rm(prompt_file)
      File.rm(mcp_config_file)
    end
  end

  defp build_command(claude_config, prompt_file, mcp_config_file) do
    base = claude_config.command || "claude"

    parts = [
      base,
      "--print",
      "--output-format", "stream-json",
      "--verbose"
    ]

    parts =
      parts
      |> maybe_append("--max-turns", to_string(Config.settings!().agent.max_turns))
      |> maybe_append("--model", claude_config.model)
      |> maybe_append("--effort", claude_config.effort)
      |> maybe_append("--permission-mode", claude_config.permission_mode)
      |> maybe_append("--mcp-config", mcp_config_file)
      |> maybe_append_list("--allowedTools", claude_config.allowed_tools)
      |> maybe_append_list("--disallowedTools", claude_config.disallowed_tools)

    parts =
      if is_binary(claude_config.system_prompt) and claude_config.system_prompt != "" do
        parts ++ ["--system-prompt", shell_escape(claude_config.system_prompt)]
      else
        parts
      end

    command_str = Enum.join(parts, " ")
    "cat #{shell_escape(prompt_file)} | #{command_str}"
  end

  defp build_env(claude_config) do
    env =
      System.get_env()
      |> Map.to_list()
      |> Enum.map(fn {k, v} -> {String.to_charlist(k), String.to_charlist(v)} end)

    env =
      if is_binary(claude_config.api_key) and claude_config.api_key != "" do
        env ++ [{~c"ANTHROPIC_API_KEY", String.to_charlist(claude_config.api_key)}]
      else
        env
      end

    # Prevent nested Claude Code detection
    env ++ [{~c"CLAUDE_CODE_ENTRYPOINT", ~c"cli"}]
  end

  defp start_port(command, workspace, env) do
    executable = System.find_executable("bash")

    if is_nil(executable) do
      {:error, :bash_not_found}
    else
      port =
        Port.open(
          {:spawn_executable, String.to_charlist(executable)},
          [
            :binary,
            :exit_status,
            :stderr_to_stdout,
            args: [~c"-lc", String.to_charlist(command)],
            cd: String.to_charlist(workspace),
            env: env,
            line: @port_line_bytes
          ]
        )

      {:ok, port}
    end
  end

  # ── Stream parsing ───────────────────────────────────────────────────

  defp receive_loop(port, on_message, turn_timeout_ms, stall_timeout_ms, pending, session_id, last_activity_ms) do
    effective_timeout = min(turn_timeout_ms, max(stall_timeout_ms, 1_000))

    receive do
      {^port, {:data, {:eol, chunk}}} ->
        line = pending <> to_string(chunk)
        now_ms = System.monotonic_time(:millisecond)

        case handle_line(line, port, on_message, session_id) do
          {:continue, _} ->
            receive_loop(port, on_message, turn_timeout_ms, stall_timeout_ms, "", session_id, now_ms)

          {:done, result} ->
            result
        end

      {^port, {:data, {:noeol, chunk}}} ->
        receive_loop(
          port,
          on_message,
          turn_timeout_ms,
          stall_timeout_ms,
          pending <> to_string(chunk),
          session_id,
          last_activity_ms
        )

      {^port, {:exit_status, 0}} ->
        {:ok, %{result: :process_exited_cleanly}}

      {^port, {:exit_status, status}} ->
        Logger.warning("Claude process exited with status=#{status} session_id=#{session_id}")
        {:error, {:port_exit, status}}
    after
      effective_timeout ->
        elapsed_since_activity = System.monotonic_time(:millisecond) - last_activity_ms

        cond do
          elapsed_since_activity > turn_timeout_ms ->
            safe_close_port(port)
            {:error, :turn_timeout}

          stall_timeout_ms > 0 and elapsed_since_activity > stall_timeout_ms ->
            safe_close_port(port)
            {:error, :stall_timeout}

          true ->
            receive_loop(port, on_message, turn_timeout_ms, stall_timeout_ms, pending, session_id, last_activity_ms)
        end
    end
  end

  defp handle_line(line, _port, on_message, session_id) do
    case Jason.decode(line) do
      {:ok, %{"type" => "result"} = payload} ->
        handle_result_event(payload, on_message, session_id)

      {:ok, %{"type" => "assistant"} = payload} ->
        handle_assistant_event(payload, on_message, session_id)

      {:ok, %{"type" => "user"} = payload} ->
        handle_user_event(payload, on_message, session_id)

      {:ok, %{"type" => "system"} = payload} ->
        handle_system_event(payload, on_message, session_id)

      {:ok, payload} ->
        emit_message(on_message, :notification, %{
          payload: payload,
          raw: line,
          session_id: session_id
        })

        {:continue, nil}

      {:error, _} ->
        log_non_json_line(line)
        {:continue, nil}
    end
  end

  defp handle_result_event(payload, on_message, session_id) do
    usage = Map.get(payload, "usage", %{})
    result_text = Map.get(payload, "result", "")
    is_error = Map.get(payload, "is_error", false)
    duration_ms = Map.get(payload, "duration_ms")
    cost = Map.get(payload, "cost")
    usage = ensure_total_tokens(usage)

    event = if is_error, do: :turn_failed, else: :turn_completed

    emit_message(on_message, event, %{
      payload: payload,
      raw: Jason.encode!(payload),
      details: payload,
      session_id: session_id,
      usage: usage
    })

    {:done,
     {:ok,
      %{
        result: event,
        result_text: result_text,
        usage: usage,
        duration_ms: duration_ms,
        cost: cost,
        payload: payload
      }}}
  end

  defp handle_assistant_event(payload, on_message, session_id) do
    content = get_in(payload, ["message", "content"]) || []
    summary = summarize_assistant_content(content)

    # Embed summary into payload so it survives summarize_codex_update.
    # Don't forward per-message usage here — it's non-cumulative and
    # confuses the orchestrator's delta tracker. The result event
    # carries the accurate session total.
    enriched_payload =
      if is_binary(summary),
        do: Map.put(payload, "_symphony_summary", summary),
        else: payload

    emit_message(on_message, :notification, %{
      payload: enriched_payload,
      raw: Jason.encode!(payload),
      session_id: session_id
    })

    {:continue, nil}
  end

  defp handle_user_event(payload, on_message, session_id) do
    # User events are tool results flowing back
    emit_message(on_message, :notification, %{
      payload: payload,
      raw: Jason.encode!(payload),
      session_id: session_id
    })

    {:continue, nil}
  end

  defp handle_system_event(%{"subtype" => "api_retry"} = payload, on_message, session_id) do
    Logger.warning(
      "Claude API retry: attempt=#{payload["attempt"]} error=#{payload["error"]} session_id=#{session_id}"
    )

    emit_message(on_message, :notification, %{
      payload: payload,
      raw: Jason.encode!(payload),
      session_id: session_id
    })

    {:continue, nil}
  end

  defp handle_system_event(payload, on_message, session_id) do
    emit_message(on_message, :notification, %{
      payload: payload,
      raw: Jason.encode!(payload),
      session_id: session_id
    })

    {:continue, nil}
  end

  defp summarize_assistant_content(content) when is_list(content) do
    Enum.find_value(content, fn
      %{"type" => "tool_use", "name" => name} -> "using tool: #{name}"
      %{"type" => "text", "text" => text} when is_binary(text) ->
        trimmed = text |> String.replace(~r/\s+/, " ") |> String.trim() |> String.slice(0, 120)
        if trimmed != "", do: "writing: #{trimmed}"
      %{"type" => "thinking"} -> "thinking..."
      _ -> nil
    end)
  end

  defp summarize_assistant_content(_content), do: nil

  defp ensure_total_tokens(usage) when is_map(usage) do
    if is_nil(Map.get(usage, "total_tokens")) do
      input = Map.get(usage, "input_tokens", 0)
      output = Map.get(usage, "output_tokens", 0)
      Map.put(usage, "total_tokens", input + output)
    else
      usage
    end
  end

  defp ensure_total_tokens(usage), do: usage

  # ── Helpers ──────────────────────────────────────────────────────────

  defp log_session_result(issue, session_id, result_data) do
    usage = Map.get(result_data, :usage, %{})
    input = Map.get(usage, "input_tokens", 0)
    output = Map.get(usage, "output_tokens", 0)
    total = Map.get(usage, "total_tokens", input + output)
    duration = Map.get(result_data, :duration_ms)
    cost = Map.get(result_data, :cost)
    result_event = Map.get(result_data, :result, :unknown)

    cost_str = if is_map(cost), do: " cost=$#{Map.get(cost, "total", "?")}", else: ""
    duration_str = if is_integer(duration), do: " duration=#{div(duration, 1000)}s", else: ""

    Logger.info(
      "Claude session completed for #{issue_context(issue)} session_id=#{session_id} " <>
        "result=#{result_event} tokens=#{total} (in=#{input} out=#{output})#{duration_str}#{cost_str}"
    )

    # Log a summary of what Claude produced
    result_text = Map.get(result_data, :result_text, "")

    if is_binary(result_text) and result_text != "" do
      summary = result_text |> String.trim() |> String.slice(0, 500)
      Logger.info("Claude result summary for session_id=#{session_id}: #{summary}")
    end
  end

  defp validate_workspace(workspace) when is_binary(workspace) do
    expanded = Path.expand(workspace)
    root = Path.expand(Config.settings!().workspace.root)
    root_prefix = root <> "/"

    with {:ok, canonical} <- PathSafety.canonicalize(expanded),
         {:ok, canonical_root} <- PathSafety.canonicalize(root) do
      canonical_root_prefix = canonical_root <> "/"

      cond do
        canonical == canonical_root ->
          {:error, {:invalid_workspace_cwd, :workspace_root, canonical}}

        String.starts_with?(canonical <> "/", canonical_root_prefix) ->
          {:ok, canonical}

        String.starts_with?(expanded <> "/", root_prefix) ->
          {:error, {:invalid_workspace_cwd, :symlink_escape, expanded, canonical_root}}

        true ->
          {:error, {:invalid_workspace_cwd, :outside_workspace_root, canonical, canonical_root}}
      end
    else
      {:error, {:path_canonicalize_failed, path, reason}} ->
        {:error, {:invalid_workspace_cwd, :path_unreadable, path, reason}}
    end
  end

  defp write_prompt_file(prompt) do
    path = Path.join(System.tmp_dir!(), "symphony_claude_prompt_#{System.unique_integer([:positive])}.md")
    File.write!(path, prompt)
    path
  end

  defp write_mcp_config do
    workflow_path = SymphonyElixir.Workflow.workflow_file_path()
    symphony_bin = resolve_symphony_bin()
    settings = Config.settings!()

    # Pass through env vars the MCP server needs to function:
    # PATH (for Erlang runtime), tracker API keys, HOME
    mcp_env =
      %{}
      |> put_env("PATH", System.get_env("PATH"))
      |> put_env("HOME", System.get_env("HOME"))
      |> put_env("NOTION_API_KEY", settings.tracker.api_key)
      |> put_env("LINEAR_API_KEY", settings.tracker.api_key)

    config = %{
      "mcpServers" => %{
        "symphony" => %{
          "command" => symphony_bin,
          "args" => ["mcp-server", workflow_path],
          "env" => mcp_env
        }
      }
    }

    path = Path.join(System.tmp_dir!(), "symphony_mcp_config_#{System.unique_integer([:positive])}.json")
    File.write!(path, Jason.encode!(config))
    path
  end

  defp put_env(map, _key, nil), do: map
  defp put_env(map, key, value), do: Map.put(map, key, value)

  defp resolve_symphony_bin do
    # The escript that's currently running
    case :escript.script_name() do
      name when is_list(name) ->
        path = List.to_string(name)
        if File.regular?(path), do: Path.expand(path), else: find_symphony_in_path()

      _ ->
        find_symphony_in_path()
    end
  end

  defp find_symphony_in_path do
    System.find_executable("symphony") || "symphony"
  end

  defp generate_session_id do
    "claude-#{:crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)}"
  end

  defp emit_message(on_message, event, details) when is_function(on_message, 1) do
    message = Map.merge(details, %{event: event, timestamp: DateTime.utc_now()})
    on_message.(message)
  end

  defp port_os_pid(port) when is_port(port) do
    case :erlang.port_info(port, :os_pid) do
      {:os_pid, pid} -> to_string(pid)
      _ -> nil
    end
  end

  defp safe_close_port(port) when is_port(port) do
    case :erlang.port_info(port) do
      :undefined -> :ok
      _ ->
        try do
          Port.close(port)
          :ok
        rescue
          ArgumentError -> :ok
        end
    end
  end

  defp shell_escape(value) when is_binary(value) do
    "'" <> String.replace(value, "'", "'\\''") <> "'"
  end

  defp maybe_append(parts, _flag, nil), do: parts
  defp maybe_append(parts, _flag, ""), do: parts
  defp maybe_append(parts, flag, value), do: parts ++ [flag, value]

  defp maybe_append_list(parts, _flag, nil), do: parts
  defp maybe_append_list(parts, _flag, []), do: parts

  defp maybe_append_list(parts, flag, tools) when is_list(tools) do
    parts ++ [flag, Enum.join(tools, ",")]
  end

  defp issue_context(%{id: issue_id, identifier: identifier}) do
    "issue_id=#{issue_id} issue_identifier=#{identifier}"
  end

  defp issue_context(_issue), do: "unknown"

  defp default_on_message(_message), do: :ok

  defp log_non_json_line(data) do
    text =
      data
      |> to_string()
      |> String.trim()
      |> String.slice(0, @max_stream_log_bytes)

    if text != "" do
      if String.match?(text, ~r/\b(error|warn|warning|failed|fatal|panic|exception)\b/i) do
        Logger.warning("Claude stream output: #{text}")
      else
        Logger.debug("Claude stream output: #{text}")
      end
    end
  end
end
