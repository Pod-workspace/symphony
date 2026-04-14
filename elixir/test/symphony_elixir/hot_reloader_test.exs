defmodule SymphonyElixir.HotReloaderTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias SymphonyElixir.HotReloader

  test "reloadable source changes trigger the reload callback" do
    root = temp_project_root!("reloadable")
    parent = self()
    source_path = Path.join(root, "lib/demo.ex")

    File.mkdir_p!(Path.dirname(source_path))
    File.write!(source_path, "defmodule Demo do\nend\n")

    {:ok, pid} =
      HotReloader.start_link(
        root: root,
        poll_interval_ms: 60_000,
        reload_fun: fn paths ->
          send(parent, {:reloaded, paths})
          :ok
        end
      )

    on_exit(fn -> Process.exit(pid, :normal) end)

    File.write!(source_path, "defmodule Demo do\n  def value, do: 1\nend\n")

    assert :ok = HotReloader.poll(pid)
    assert_receive {:reloaded, ["lib/demo.ex"]}, 1_000
  end

  test "config changes log a cold restart warning instead of recompiling" do
    root = temp_project_root!("cold-restart")
    parent = self()
    config_path = Path.join(root, "config/runtime.exs")

    File.mkdir_p!(Path.dirname(config_path))
    File.write!(config_path, "import Config\n")

    {:ok, pid} =
      HotReloader.start_link(
        root: root,
        poll_interval_ms: 60_000,
        reload_fun: fn paths ->
          send(parent, {:reloaded, paths})
          :ok
        end
      )

    on_exit(fn -> Process.exit(pid, :normal) end)

    File.write!(config_path, "import Config\nconfig :symphony_elixir, :flag, true\n")

    log =
      capture_log([level: :warning], fn ->
        assert :ok = HotReloader.poll(pid)
        Process.sleep(25)
      end)

    refute_received {:reloaded, _paths}
    assert log =~ "require a cold restart"
    assert log =~ "config/runtime.exs"
  end

  defp temp_project_root!(suffix) do
    root =
      Path.join(
        System.tmp_dir!(),
        "symphony-hot-reloader-#{suffix}-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(root)
    root
  end
end
