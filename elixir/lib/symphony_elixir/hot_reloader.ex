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

  @default_poll_interval_ms 1_000
  @reloadable_patterns ["lib/**/*.ex", "lib/**/*.exs"]
  @cold_restart_patterns ["config/**/*.exs", "mix.exs", "mix.lock"]

  defmodule State do
    @moduledoc false

    defstruct [:root, :poll_interval_ms, :reload_fun, :snapshot]
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
    snapshot = snapshot(root)

    Logger.info("Hot reloader watching #{root} every #{poll_interval_ms}ms for reloadable source changes")

    schedule_poll(poll_interval_ms)
    {:ok, %State{root: root, poll_interval_ms: poll_interval_ms, reload_fun: reload_fun, snapshot: snapshot}}
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

  defp run_poll(%State{root: root, reload_fun: reload_fun, snapshot: previous_snapshot} = state) do
    current_snapshot = snapshot(root)

    %{reloadable: reloadable_paths, cold_restart: cold_restart_paths} =
      classify_changes(previous_snapshot, current_snapshot)

    maybe_reload(reloadable_paths, reload_fun)
    maybe_warn_cold_restart(cold_restart_paths)

    %{state | snapshot: current_snapshot}
  end

  defp maybe_reload([], _reload_fun), do: :ok

  defp maybe_reload(paths, reload_fun) when is_function(reload_fun, 1) do
    Logger.info("Hot reloader recompiling #{length(paths)} changed file(s): #{Enum.join(paths, ", ")}")

    try do
      case reload_fun.(paths) do
        :error ->
          Logger.error("Hot reloader failed to recompile changed source files")

        {:error, reason} ->
          Logger.error("Hot reloader failed to recompile changed source files: #{inspect(reason)}")

        _other ->
          Logger.info("Hot reloader applied updated code without restarting the node")
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
