defmodule Mix.Tasks.Symphony.HotTest do
  use ExUnit.Case, async: true

  alias Mix.Tasks.Symphony.Hot

  test "explicit options configure the runtime and start the reloader" do
    parent = self()
    project_root = Path.join(System.tmp_dir!(), "symphony-hot-task-explicit")
    workflow_path = Path.expand("tmp/custom/WORKFLOW.md", project_root)
    logs_root = Path.expand("tmp/logs", project_root)

    deps = %{
      file_regular?: fn path ->
        send(parent, {:workflow_checked, path})
        path == workflow_path
      end,
      get_env: fn _key -> nil end,
      set_workflow_file_path: fn path ->
        send(parent, {:workflow_set, path})
        :ok
      end,
      set_logs_root: fn path ->
        send(parent, {:logs_root, path})
        :ok
      end,
      set_server_port_override: fn port ->
        send(parent, {:port, port})
        :ok
      end,
      set_server_host_override: fn host ->
        send(parent, {:host, host})
        :ok
      end,
      ensure_all_started: fn ->
        send(parent, :started)
        {:ok, [:symphony_elixir]}
      end,
      start_reloader: fn opts ->
        send(parent, {:start_reloader, opts})
        {:ok, self()}
      end,
      keep_alive: fn ->
        send(parent, :keep_alive)
        :ok
      end,
      project_root: fn -> project_root end
    }

    assert :ok =
             Hot.evaluate(
               [
                 "--workflow",
                 "tmp/custom/WORKFLOW.md",
                 "--logs-root",
                 "tmp/logs",
                 "--port",
                 "4003",
                 "--host",
                 " 0.0.0.0 ",
                 "--reload-interval-ms",
                 "2500"
               ],
               deps
             )

    assert_received {:workflow_checked, ^workflow_path}
    assert_received {:workflow_set, ^workflow_path}
    assert_received {:logs_root, ^logs_root}
    assert_received {:port, 4003}
    assert_received {:host, "0.0.0.0"}
    assert_received :started
    assert_received {:start_reloader, [root: ^project_root, poll_interval_ms: 2500]}
    assert_received :keep_alive
  end

  test "environment fallbacks provide workflow, port, host, logs root, and reload interval" do
    parent = self()
    project_root = Path.join(System.tmp_dir!(), "symphony-hot-task-env")
    workflow_path = Path.expand("env/WORKFLOW.md", project_root)
    logs_root = Path.expand("env/logs", project_root)

    env = %{
      "SYMPHONY_WORKFLOW" => "env/WORKFLOW.md",
      "SYMPHONY_LOGS_ROOT" => "env/logs",
      "SYMPHONY_SERVER_PORT" => "4100",
      "SYMPHONY_SERVER_HOST" => "127.0.0.2",
      "SYMPHONY_RELOAD_INTERVAL_MS" => "1500"
    }

    deps = %{
      file_regular?: fn path ->
        send(parent, {:workflow_checked, path})
        path == workflow_path
      end,
      get_env: fn key -> Map.get(env, key) end,
      set_workflow_file_path: fn path ->
        send(parent, {:workflow_set, path})
        :ok
      end,
      set_logs_root: fn path ->
        send(parent, {:logs_root, path})
        :ok
      end,
      set_server_port_override: fn port ->
        send(parent, {:port, port})
        :ok
      end,
      set_server_host_override: fn host ->
        send(parent, {:host, host})
        :ok
      end,
      ensure_all_started: fn ->
        send(parent, :started)
        {:ok, [:symphony_elixir]}
      end,
      start_reloader: fn opts ->
        send(parent, {:start_reloader, opts})
        {:ok, self()}
      end,
      keep_alive: fn ->
        send(parent, :keep_alive)
        :ok
      end,
      project_root: fn -> project_root end
    }

    assert :ok = Hot.evaluate([], deps)

    assert_received {:workflow_checked, ^workflow_path}
    assert_received {:workflow_set, ^workflow_path}
    assert_received {:logs_root, ^logs_root}
    assert_received {:port, 4100}
    assert_received {:host, "127.0.0.2"}
    assert_received :started
    assert_received {:start_reloader, [root: ^project_root, poll_interval_ms: 1500]}
    assert_received :keep_alive
  end

  test "returns an error when the workflow file does not exist" do
    deps = %{
      file_regular?: fn _path -> false end,
      get_env: fn _key -> nil end,
      set_workflow_file_path: fn _path -> :ok end,
      set_logs_root: fn _path -> :ok end,
      set_server_port_override: fn _port -> :ok end,
      set_server_host_override: fn _host -> :ok end,
      ensure_all_started: fn -> {:ok, [:symphony_elixir]} end,
      start_reloader: fn _opts -> {:ok, self()} end,
      keep_alive: fn -> :ok end,
      project_root: fn -> "/project" end
    }

    assert {:error, message} = Hot.evaluate(["--workflow", "missing/WORKFLOW.md"], deps)
    assert message =~ "Workflow file not found:"
  end
end
