defmodule SymphonyElixir.Codex.Account do
  @moduledoc """
  Reads and caches the Codex account summary used by observability surfaces.
  """

  require Logger

  alias SymphonyElixir.{Config, Workflow}

  @initialize_id 1
  @account_read_id 2
  @port_line_bytes 1_048_576
  @max_stream_log_bytes 1_000
  @cache_key {__MODULE__, :summary}
  @cache_ttl_ms 30_000

  @type summary :: %{
          status: String.t(),
          type: String.t() | nil,
          auth_mode: String.t() | nil,
          email: String.t() | nil,
          plan_type: String.t() | nil,
          requires_openai_auth: boolean()
        }

  @spec summary() :: summary() | nil
  def summary do
    case Application.fetch_env(:symphony_elixir, :codex_account_summary_override) do
      {:ok, account_summary} ->
        account_summary

      :error ->
        cached_summary()
    end
  rescue
    error in [ArgumentError, RuntimeError] ->
      Logger.debug("Failed reading Codex account summary: #{Exception.message(error)}")
      nil
  end

  @doc false
  @spec clear_cache_for_test() :: :ok
  def clear_cache_for_test do
    :persistent_term.erase(@cache_key)
    :ok
  rescue
    ArgumentError -> :ok
  end

  defp cached_summary do
    now_ms = System.monotonic_time(:millisecond)
    context = cache_context()

    case :persistent_term.get(@cache_key, nil) do
      %{context: ^context, fetched_at_ms: fetched_at_ms, summary: account_summary}
      when is_integer(fetched_at_ms) and now_ms - fetched_at_ms < @cache_ttl_ms ->
        account_summary

      _ ->
        refresh_summary(context, now_ms)
    end
  end

  defp refresh_summary(context, now_ms) do
    account_summary =
      case fetch_summary(context.cwd) do
        {:ok, summary} ->
          summary

        {:error, reason} ->
          Logger.debug("Codex account summary unavailable: #{inspect(reason)}")
          nil
      end

    :persistent_term.put(@cache_key, %{context: context, fetched_at_ms: now_ms, summary: account_summary})
    account_summary
  end

  defp cache_context do
    %{command: Config.settings!().codex.command, cwd: account_read_cwd()}
  end

  defp account_read_cwd do
    workflow_dir =
      Workflow.workflow_file_path()
      |> Path.dirname()
      |> Path.expand()

    if File.dir?(workflow_dir), do: workflow_dir, else: File.cwd!()
  end

  defp fetch_summary(cwd) when is_binary(cwd) do
    case start_port(cwd) do
      {:ok, port} ->
        try do
          with :ok <- send_initialize(port),
               {:ok, response} <- account_read(port),
               %{} = account_summary <- normalize_account_response(response) do
            {:ok, account_summary}
          else
            nil -> {:error, :invalid_account_response}
            {:error, reason} -> {:error, reason}
          end
        after
          stop_port(port)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp start_port(cwd) do
    executable = System.find_executable("bash")

    cond do
      is_nil(executable) ->
        {:error, :bash_not_found}

      !File.dir?(cwd) ->
        {:error, {:invalid_cwd, cwd}}

      true ->
        port =
          Port.open(
            {:spawn_executable, String.to_charlist(executable)},
            [
              :binary,
              :exit_status,
              :stderr_to_stdout,
              args: [~c"-lc", String.to_charlist(Config.settings!().codex.command)],
              cd: String.to_charlist(cwd),
              line: @port_line_bytes
            ]
          )

        {:ok, port}
    end
  end

  defp send_initialize(port) do
    send_message(port, %{
      "method" => "initialize",
      "id" => @initialize_id,
      "params" => %{
        "capabilities" => %{"experimentalApi" => true},
        "clientInfo" => %{
          "name" => "symphony-observability",
          "title" => "Symphony Observability",
          "version" => "0.1.0"
        }
      }
    })

    with {:ok, _result} <- await_response(port, @initialize_id) do
      send_message(port, %{"method" => "initialized", "params" => %{}})
      :ok
    end
  end

  defp account_read(port) do
    send_message(port, %{
      "method" => "account/read",
      "id" => @account_read_id,
      "params" => %{"refreshToken" => false}
    })

    await_response(port, @account_read_id)
  end

  defp await_response(port, request_id) do
    with_timeout_response(port, request_id, Config.settings!().codex.read_timeout_ms, "")
  end

  defp with_timeout_response(port, request_id, timeout_ms, pending_line) do
    receive do
      {^port, {:data, {:eol, chunk}}} ->
        complete_line = pending_line <> to_string(chunk)
        handle_response(port, request_id, complete_line, timeout_ms)

      {^port, {:data, {:noeol, chunk}}} ->
        with_timeout_response(port, request_id, timeout_ms, pending_line <> to_string(chunk))

      {^port, {:exit_status, status}} ->
        {:error, {:port_exit, status}}
    after
      timeout_ms ->
        {:error, :response_timeout}
    end
  end

  defp handle_response(port, request_id, data, timeout_ms) do
    payload = to_string(data)

    case Jason.decode(payload) do
      {:ok, %{"id" => ^request_id, "error" => error}} ->
        {:error, {:response_error, error}}

      {:ok, %{"id" => ^request_id, "result" => result}} ->
        {:ok, result}

      {:ok, %{"id" => ^request_id} = response_payload} ->
        {:error, {:response_error, response_payload}}

      {:ok, %{} = _other} ->
        with_timeout_response(port, request_id, timeout_ms, "")

      {:error, _reason} ->
        log_non_json_stream_line(payload)
        with_timeout_response(port, request_id, timeout_ms, "")
    end
  end

  defp log_non_json_stream_line(data) do
    text =
      data
      |> to_string()
      |> String.trim()
      |> String.slice(0, @max_stream_log_bytes)

    if text != "" do
      Logger.debug("Codex account/read stream output: #{text}")
    end
  end

  defp normalize_account_response(response) when is_map(response) do
    requires_openai_auth =
      Map.get(response, "requiresOpenaiAuth") ||
        Map.get(response, :requiresOpenaiAuth) ||
        false

    normalize_account(Map.get(response, "account") || Map.get(response, :account), requires_openai_auth)
  end

  defp normalize_account_response(_response), do: nil

  defp normalize_account(nil, requires_openai_auth) when is_boolean(requires_openai_auth) do
    %{
      status: if(requires_openai_auth, do: "signed_out", else: "not_required"),
      type: nil,
      auth_mode: nil,
      email: nil,
      plan_type: nil,
      requires_openai_auth: requires_openai_auth
    }
  end

  defp normalize_account(account, requires_openai_auth) when is_map(account) do
    type = payload_string(account, ["type", :type])
    email = payload_string(account, ["email", :email])

    plan_type =
      payload_string(account, [
        "planType",
        :planType,
        "plan_type",
        :plan_type
      ])

    %{
      status: "ready",
      type: type,
      auth_mode: auth_mode_for_type(type),
      email: email,
      plan_type: plan_type,
      requires_openai_auth: requires_openai_auth == true
    }
  end

  defp normalize_account(_account, _requires_openai_auth), do: nil

  defp auth_mode_for_type("apiKey"), do: "apikey"
  defp auth_mode_for_type("chatgpt"), do: "chatgpt"
  defp auth_mode_for_type(type), do: type

  defp payload_string(payload, keys) when is_map(payload) and is_list(keys) do
    keys
    |> Enum.find_value(fn key -> Map.get(payload, key) end)
    |> case do
      value when is_binary(value) ->
        trimmed = String.trim(value)
        if trimmed == "", do: nil, else: trimmed

      _ ->
        nil
    end
  end

  defp send_message(port, message) do
    line = Jason.encode!(message) <> "\n"
    Port.command(port, line)
  end

  defp stop_port(port) when is_port(port) do
    case :erlang.port_info(port) do
      :undefined ->
        :ok

      _ ->
        try do
          Port.close(port)
          :ok
        rescue
          ArgumentError ->
            :ok
        end
    end
  end
end
