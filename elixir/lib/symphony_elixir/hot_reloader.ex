defmodule SymphonyElixir.HotReloader do
  @moduledoc """
  Polls Mix project source files and hot-reloads runtime-safe changes.

  `WORKFLOW.md` already reloads through `SymphonyElixir.WorkflowStore`, so this
  reloader focuses on Elixir source changes under `lib/`. Changes to
  `config/*.exs`, `mix.exs`, or `mix.lock` are detected and logged as requiring
  a cold restart instead of being recompiled in place.
  """

  use GenServer
  require Logger

  alias SymphonyElixir.{Config, HttpServer}

  @default_poll_interval_ms 1_000
  @reloadable_patterns ["lib/**/*.ex", "lib/**/*.exs"]
  @cold_restart_patterns ["config/**/*.exs", "mix.exs", "mix.lock"]

  defmodule State do
    @moduledoc false

    defstruct [:root, :poll_interval_ms, :reload_fun, :after_reload_fun, :snapshot]
  end

  @type category :: :reloadable | :cold_restart
  @type snapshot_entry :: %{category: category(), signature: {integer(), integer(), integer()}}

  @spec default_poll_interval_ms() :: pos_integer()
  def default_poll_interval_ms, do: @default_poll_interval_ms

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name))
  end

  @spec poll(GenServer.server()) :: :ok
  def poll(server \\ __MODULE__) do
    GenServer.call(server, :poll, :infinity)
  end

  @impl true
  def init(opts) do
    root = Path.expand(Keyword.get(opts, :root, File.cwd!()))
    poll_interval_ms = normalize_poll_interval_ms(Keyword.get(opts, :poll_interval_ms))
    reload_fun = Keyword.get(opts, :reload_fun, &default_reload/1)
    after_reload_fun = Keyword.get(opts, :after_reload_fun, &ensure_observability_server/0)
    snapshot = snapshot(root)

    Logger.info("Hot reloader watching #{root} every #{poll_interval_ms}ms for reloadable source changes")

    schedule_poll(poll_interval_ms)

    {:ok,
     %State{
       root: root,
       poll_interval_ms: poll_interval_ms,
       reload_fun: reload_fun,
       after_reload_fun: after_reload_fun,
       snapshot: snapshot
     }}
  end

  @impl true
  def handle_call(:poll, _from, %State{} = state) do
    {:reply, :ok, run_poll(state)}
  end

  @impl true
  def handle_info(:poll, %State{} = state) do
    schedule_poll(state.poll_interval_ms)
    {:noreply, run_poll(state)}
  end

  defp run_poll(%{__struct__: State, root: root, reload_fun: reload_fun, snapshot: previous_snapshot} = state) do
    after_reload_fun = Map.get(state, :after_reload_fun, &ensure_observability_server/0)
    current_snapshot = snapshot(root)

    %{reloadable: reloadable_paths, cold_restart: cold_restart_paths} =
      classify_changes(previous_snapshot, current_snapshot)

    maybe_reload(reloadable_paths, reload_fun, after_reload_fun)
    maybe_warn_cold_restart(cold_restart_paths)

    %{state | snapshot: current_snapshot}
  end

  defp maybe_reload([], _reload_fun, _after_reload_fun), do: :ok

  defp maybe_reload(paths, reload_fun, after_reload_fun)
       when is_function(reload_fun, 1) and is_function(after_reload_fun, 0) do
    Logger.info("Hot reloader recompiling #{length(paths)} changed file(s): #{Enum.join(paths, ", ")}")

    try do
      case reload_fun.(paths) do
        :error ->
          Logger.error("Hot reloader failed to recompile changed source files")

        {:error, reason} ->
          Logger.error("Hot reloader failed to recompile changed source files: #{inspect(reason)}")

        _other ->
          Logger.info("Hot reloader applied updated code without restarting the node")
          run_after_reload(after_reload_fun)
      end
    rescue
      exception ->
        Logger.error("Hot reloader crashed during recompilation: #{Exception.format(:error, exception, __STACKTRACE__)}")
    catch
      kind, reason ->
        Logger.error("Hot reloader crashed during recompilation: #{kind}: #{inspect(reason)}")
    end
  end

  defp maybe_warn_cold_restart([]), do: :ok

  defp maybe_warn_cold_restart(paths) do
    Logger.warning("Hot reloader detected changes that require a cold restart: #{Enum.join(paths, ", ")}")
  end

  defp default_reload(_paths) do
    IEx.Helpers.recompile()
  end

  defp run_after_reload(after_reload_fun) do
    case after_reload_fun.() do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("Hot reloader post-reload health check failed: #{inspect(reason)}")

      other ->
        Logger.warning("Hot reloader post-reload health check returned unexpected value: #{inspect(other)}")
    end
  rescue
    exception ->
      Logger.warning("Hot reloader post-reload health check crashed: #{Exception.message(exception)}")
  catch
    kind, reason ->
      Logger.warning("Hot reloader post-reload health check crashed: #{kind}: #{inspect(reason)}")
  end

  defp ensure_observability_server do
    cond do
      is_nil(Config.server_port()) ->
        :ok

      is_integer(HttpServer.bound_port()) ->
        :ok

      true ->
        restart_observability_child()
    end
  end

  defp restart_observability_child do
    case Process.whereis(SymphonyElixir.Supervisor) do
      nil ->
        {:error, :supervisor_unavailable}

      _pid ->
        with :ok <- terminate_observability_child(),
             {:ok, _pid} <- Supervisor.restart_child(SymphonyElixir.Supervisor, HttpServer) do
          Logger.info("Hot reloader restarted observability HTTP server after reload")
          :ok
        else
          {:ok, _pid, _info} ->
            Logger.info("Hot reloader restarted observability HTTP server after reload")
            :ok

          {:error, {:already_started, _pid}} ->
            :ok

          {:error, reason} ->
            {:error, {:restart_observability_child_failed, reason}}
        end
    end
  end

  defp terminate_observability_child do
    case Supervisor.terminate_child(SymphonyElixir.Supervisor, HttpServer) do
      :ok -> :ok
      {:error, :not_started} -> :ok
      {:error, reason} -> {:error, {:terminate_observability_child_failed, reason}}
    end
  end

  defp schedule_poll(poll_interval_ms) do
    Process.send_after(self(), :poll, poll_interval_ms)
  end

  defp snapshot(root) do
    root
    |> watched_files()
    |> Enum.reduce(%{}, fn {category, absolute_path}, acc ->
      relative_path = Path.relative_to(absolute_path, root)

      case file_signature(absolute_path) do
        {:ok, signature} ->
          Map.put(acc, relative_path, %{category: category, signature: signature})

        {:error, _reason} ->
          acc
      end
    end)
  end

  defp watched_files(root) do
    watched_paths_for_category(root, :reloadable, @reloadable_patterns) ++
      watched_paths_for_category(root, :cold_restart, @cold_restart_patterns)
  end

  defp watched_paths_for_category(root, category, patterns) do
    patterns
    |> Enum.flat_map(fn pattern ->
      root
      |> Path.join(pattern)
      |> Path.wildcard(match_dot: true)
      |> Enum.map(&{category, &1})
    end)
    |> Enum.uniq_by(fn {_category, path} -> path end)
  end

  defp classify_changes(previous_snapshot, current_snapshot) do
    previous_snapshot
    |> Map.keys()
    |> Kernel.++(Map.keys(current_snapshot))
    |> Enum.uniq()
    |> Enum.reduce(%{reloadable: [], cold_restart: []}, fn path, acc ->
      previous_entry = Map.get(previous_snapshot, path)
      current_entry = Map.get(current_snapshot, path)

      if previous_entry == current_entry do
        acc
      else
        category = entry_category(current_entry || previous_entry)
        Map.update!(acc, category, &[path | &1])
      end
    end)
    |> Map.new(fn {category, paths} -> {category, Enum.sort(paths)} end)
  end

  defp entry_category(%{category: category}) when category in [:reloadable, :cold_restart],
    do: category

  defp normalize_poll_interval_ms(value) when is_integer(value) and value > 0, do: value
  defp normalize_poll_interval_ms(_value), do: @default_poll_interval_ms

  defp file_signature(path) do
    with {:ok, stat} <- File.stat(path, time: :posix),
         {:ok, contents} <- File.read(path) do
      {:ok, {stat.mtime, stat.size, :erlang.phash2(contents)}}
    end
  end
end
