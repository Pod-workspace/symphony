defmodule SymphonyElixir.TokenUsageLog do
  @moduledoc """
  Writes Codex token usage deltas to a separate JSONL file for reporting.
  """

  require Logger

  @default_file_name "token_usage.jsonl"

  @spec record(map(), map(), map(), map(), map()) :: :ok
  def record(update, running_entry, updated_running_entry, token_delta, runtime_totals)
      when is_map(update) and is_map(running_entry) and is_map(updated_running_entry) and
             is_map(token_delta) and is_map(runtime_totals) do
    if token_delta?(token_delta) do
      payload =
        update
        |> log_entry(running_entry, updated_running_entry, token_delta, runtime_totals)
        |> Jason.encode!()

      path = token_usage_log_file()
      :ok = File.mkdir_p(Path.dirname(path))
      File.write(path, payload <> "\n", [:append])
      :ok
    else
      :ok
    end
  rescue
    error in [ArgumentError, RuntimeError, File.Error, Jason.EncodeError] ->
      Logger.debug("Failed writing token usage log: #{Exception.message(error)}")
      :ok
  end

  def record(_update, _running_entry, _updated_running_entry, _token_delta, _runtime_totals), do: :ok

  @spec token_usage_log_file() :: Path.t()
  def token_usage_log_file do
    Application.get_env(:symphony_elixir, :token_usage_log_file) ||
      default_token_usage_log_file()
  end

  defp default_token_usage_log_file do
    log_file = Application.get_env(:symphony_elixir, :log_file, SymphonyElixir.LogFile.default_log_file())

    log_file
    |> Path.dirname()
    |> Path.join(@default_file_name)
    |> Path.expand()
  end

  defp log_entry(update, running_entry, updated_running_entry, token_delta, runtime_totals) do
    %{
      timestamp: timestamp(update),
      issue_id: Map.get(running_entry, :issue_id) || get_in(running_entry, [:issue, Access.key(:id)]),
      issue_identifier: Map.get(running_entry, :identifier),
      session_id: Map.get(updated_running_entry, :session_id),
      event: event_name(update),
      message: Map.get(updated_running_entry, :last_codex_message),
      delta: %{
        input_tokens: Map.get(token_delta, :input_tokens, 0),
        output_tokens: Map.get(token_delta, :output_tokens, 0),
        total_tokens: Map.get(token_delta, :total_tokens, 0)
      },
      issue_totals: %{
        input_tokens: Map.get(updated_running_entry, :codex_input_tokens, 0),
        output_tokens: Map.get(updated_running_entry, :codex_output_tokens, 0),
        total_tokens: Map.get(updated_running_entry, :codex_total_tokens, 0)
      },
      runtime_totals: %{
        input_tokens: Map.get(runtime_totals, :input_tokens, 0),
        output_tokens: Map.get(runtime_totals, :output_tokens, 0),
        total_tokens: Map.get(runtime_totals, :total_tokens, 0)
      }
    }
  end

  defp token_delta?(%{input_tokens: input, output_tokens: output, total_tokens: total}) do
    Enum.any?([input, output, total], &(is_integer(&1) and &1 > 0))
  end

  defp token_delta?(_token_delta), do: false

  defp timestamp(%{timestamp: %DateTime{} = timestamp}), do: DateTime.to_iso8601(timestamp)
  defp timestamp(_update), do: DateTime.utc_now() |> DateTime.to_iso8601()

  defp event_name(%{event: event}) when is_atom(event), do: Atom.to_string(event)
  defp event_name(%{event: event}) when is_binary(event), do: event
  defp event_name(_update), do: nil
end
