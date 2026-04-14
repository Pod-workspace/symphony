defmodule Mix.Tasks.Symphony.Hot do
  use Mix.Task

  alias SymphonyElixir.{HotReloader, LogFile, Workflow}

  @shortdoc "Run Symphony with polling hot reload enabled"

  @moduledoc """
  Starts Symphony in the current Mix node and polls for hot-reloadable source
  changes.

  This command is intended for long-running production-like runs in
  `MIX_ENV=prod`:

  - `lib/**/*.ex` changes are hot recompiled in place
  - `WORKFLOW.md` continues to hot reload through `SymphonyElixir.WorkflowStore`
  - `config/*.exs`, `mix.exs`, and `mix.lock` changes are detected but require
    a cold restart

  Usage:

      mix symphony.hot [--workflow PATH] [--logs-root PATH] [--port PORT] [--host HOST]
                       [--reload-interval-ms MS]

  Environment fallbacks:

      SYMPHONY_WORKFLOW
      SYMPHONY_LOGS_ROOT
      SYMPHONY_SERVER_PORT
      SYMPHONY_SERVER_HOST
      SYMPHONY_RELOAD_INTERVAL_MS
  """

  @switches [
    workflow: :string,
    logs_root: :string,
    port: :integer,
    host: :string,
    reload_interval_ms: :integer,
    help: :boolean
  ]

  @type ensure_started_result :: {:ok, [atom()]} | {:error, term()}

  @type deps :: %{
          file_regular?: (String.t() -> boolean()),
          get_env: (String.t() -> String.t() | nil),
          set_workflow_file_path: (String.t() -> :ok | {:error, term()}),
          set_logs_root: (String.t() -> :ok | {:error, term()}),
          set_server_port_override: (non_neg_integer() -> :ok | {:error, term()}),
          set_server_host_override: (String.t() -> :ok | {:error, term()}),
          ensure_all_started: (-> ensure_started_result()),
          start_reloader: (keyword() -> {:ok, pid()} | {:error, term()}),
          keep_alive: (-> term()),
          project_root: (-> String.t())
        }

  @impl Mix.Task
  def run(args) do
    case evaluate(args) do
      :ok ->
        :ok

      {:help, text} ->
        Mix.shell().info(text)

      {:error, message} ->
        Mix.raise(message)
    end
  end

  @spec evaluate([String.t()], deps()) :: :ok | {:help, String.t()} | {:error, String.t()}
  def evaluate(args, deps \\ runtime_deps()) do
    {opts, _argv, invalid} = OptionParser.parse(args, strict: @switches, aliases: [h: :help])

    cond do
      opts[:help] ->
        {:help, @moduledoc}

      invalid != [] ->
        {:error, "Invalid option(s): #{inspect(invalid)}"}

      true ->
        resolved = resolve_options(opts, deps)

        with :ok <- ensure_workflow_exists(resolved.workflow, deps),
             :ok <- deps.set_workflow_file_path.(resolved.workflow),
             :ok <- maybe_set_logs_root(resolved.logs_root, deps),
             :ok <- maybe_set_server_port(resolved.port, deps),
             :ok <- maybe_set_server_host(resolved.host, deps),
             {:ok, _started_apps} <- deps.ensure_all_started.(),
             :ok <- start_reloader(resolved, deps) do
          announce_startup(resolved)
          deps.keep_alive.()
          :ok
        else
          {:error, reason} ->
            {:error, format_error(reason, resolved)}
        end
    end
  end

  defp runtime_deps do
    %{
      file_regular?: &File.regular?/1,
      get_env: &System.get_env/1,
      set_workflow_file_path: &Workflow.set_workflow_file_path/1,
      set_logs_root: &set_logs_root/1,
      set_server_port_override: &set_server_port_override/1,
      set_server_host_override: &set_server_host_override/1,
      ensure_all_started: fn -> Application.ensure_all_started(:symphony_elixir) end,
      start_reloader: fn reloader_opts ->
        case HotReloader.start_link([name: HotReloader] ++ reloader_opts) do
          {:ok, pid} -> {:ok, pid}
          {:error, {:already_started, _pid}} -> {:ok, :already_started}
          {:error, reason} -> {:error, reason}
        end
      end,
      keep_alive: fn -> Process.sleep(:infinity) end,
      project_root: &File.cwd!/0
    }
  end

  defp resolve_options(opts, deps) do
    project_root = deps.project_root.()

    %{
      workflow: path_option(opts[:workflow] || deps.get_env.("SYMPHONY_WORKFLOW"), "WORKFLOW.md", project_root),
      logs_root: optional_path_option(opts[:logs_root] || deps.get_env.("SYMPHONY_LOGS_ROOT"), project_root),
      port:
        integer_option(
          opts[:port],
          deps.get_env.("SYMPHONY_SERVER_PORT")
        ),
      host: string_option(opts[:host] || deps.get_env.("SYMPHONY_SERVER_HOST")),
      reload_interval_ms:
        integer_option(
          opts[:reload_interval_ms],
          deps.get_env.("SYMPHONY_RELOAD_INTERVAL_MS"),
          HotReloader.default_poll_interval_ms()
        ),
      project_root: project_root
    }
  end

  defp ensure_workflow_exists(workflow_path, deps) do
    if deps.file_regular?.(workflow_path) do
      :ok
    else
      {:error, {:missing_workflow_file, workflow_path}}
    end
  end

  defp maybe_set_logs_root(nil, _deps), do: :ok

  defp maybe_set_logs_root(logs_root, deps) do
    deps.set_logs_root.(logs_root)
  end

  defp maybe_set_server_port(nil, _deps), do: :ok

  defp maybe_set_server_port(port, deps) do
    deps.set_server_port_override.(port)
  end

  defp maybe_set_server_host(nil, _deps), do: :ok

  defp maybe_set_server_host(host, deps) do
    deps.set_server_host_override.(host)
  end

  defp start_reloader(resolved, deps) do
    try do
      case deps.start_reloader.(
             root: resolved.project_root,
             poll_interval_ms: resolved.reload_interval_ms
           ) do
        {:ok, _pid} -> :ok
        {:error, reason} -> {:error, {:start_reloader_failed, reason}}
      end
    rescue
      exception ->
        {:error, {:start_reloader_failed, Exception.message(exception)}}
    end
  end

  defp announce_startup(resolved) do
    Mix.shell().info("Starting Symphony hot reload in #{Mix.env()} with workflow #{resolved.workflow}")

    Mix.shell().info("Hot reloader polls #{resolved.project_root} every #{resolved.reload_interval_ms}ms")

    if resolved.logs_root do
      Mix.shell().info("Writing logs under #{resolved.logs_root}")
    end

    if resolved.port do
      host = resolved.host || "127.0.0.1"
      Mix.shell().info("Observability service enabled on #{host}:#{resolved.port}")
    end
  end

  defp set_logs_root(logs_root) do
    Application.put_env(:symphony_elixir, :log_file, LogFile.default_log_file(logs_root))
    :ok
  end

  defp set_server_port_override(port) when is_integer(port) and port >= 0 do
    Application.put_env(:symphony_elixir, :server_port_override, port)
    :ok
  end

  defp set_server_host_override(host) when is_binary(host) do
    Application.put_env(:symphony_elixir, :server_host_override, host)
    :ok
  end

  defp path_option(nil, default, project_root), do: Path.expand(default, project_root)

  defp path_option(value, default, project_root) do
    case String.trim(value) do
      "" -> Path.expand(default, project_root)
      trimmed -> Path.expand(trimmed, project_root)
    end
  end

  defp optional_path_option(nil, _project_root), do: nil

  defp optional_path_option(value, project_root) do
    case String.trim(value) do
      "" -> nil
      trimmed -> Path.expand(trimmed, project_root)
    end
  end

  defp string_option(nil), do: nil

  defp string_option(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp integer_option(nil, nil), do: nil
  defp integer_option(value, _env_value) when is_integer(value) and value >= 0, do: value

  defp integer_option(nil, env_value) when is_binary(env_value) do
    env_value
    |> String.trim()
    |> Integer.parse()
    |> case do
      {parsed, ""} when parsed >= 0 -> parsed
      _ -> nil
    end
  end

  defp integer_option(_value, _env_value), do: nil

  defp integer_option(nil, nil, default), do: default

  defp integer_option(value, env_value, default) do
    case integer_option(value, env_value) do
      nil -> default
      resolved -> resolved
    end
  end

  defp format_error({:missing_workflow_file, workflow_path}, _resolved) do
    "Workflow file not found: #{workflow_path}"
  end

  defp format_error({:start_reloader_failed, message}, _resolved) do
    "Failed to start hot reloader: #{inspect(message)}"
  end

  defp format_error(reason, resolved) do
    "Failed to start Symphony hot reload with workflow #{resolved.workflow}: #{inspect(reason)}"
  end
end
