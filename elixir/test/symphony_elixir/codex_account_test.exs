defmodule SymphonyElixir.CodexAccountTest do
  use SymphonyElixir.TestSupport

  test "summary reads and caches ChatGPT account details from codex app-server" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-codex-account-#{System.unique_integer([:positive])}"
      )

    try do
      codex_binary = Path.join(test_root, "fake-codex")
      invocation_file = Path.join(test_root, "invocations.log")
      File.mkdir_p!(test_root)

      File.write!(codex_binary, """
      #!/bin/sh
      invocation_file="#{invocation_file}"
      printf 'run\\n' >> "$invocation_file"
      count=0

      while IFS= read -r _line; do
        count=$((count + 1))

        case "$count" in
          1)
            printf '%s\\n' '{"id":1,"result":{}}'
            ;;
          3)
            printf '%s\\n' '{"id":2,"result":{"account":{"type":"chatgpt","email":"agent@example.com","planType":"pro"},"requiresOpenaiAuth":true}}'
            exit 0
            ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        codex_command: "#{codex_binary} app-server"
      )

      Application.delete_env(:symphony_elixir, :codex_account_summary_override)
      CodexAccount.clear_cache_for_test()

      assert CodexAccount.summary() == %{
               status: "ready",
               type: "chatgpt",
               auth_mode: "chatgpt",
               email: "agent@example.com",
               plan_type: "pro",
               requires_openai_auth: true
             }

      File.rm!(codex_binary)

      assert CodexAccount.summary() == %{
               status: "ready",
               type: "chatgpt",
               auth_mode: "chatgpt",
               email: "agent@example.com",
               plan_type: "pro",
               requires_openai_auth: true
             }

      assert File.read!(invocation_file) == "run\n"
    after
      CodexAccount.clear_cache_for_test()
      Application.put_env(:symphony_elixir, :codex_account_summary_override, nil)
      File.rm_rf(test_root)
    end
  end

  test "summary reports a signed-out account when Codex requires auth but has no active login" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-codex-account-signed-out-#{System.unique_integer([:positive])}"
      )

    try do
      codex_binary = Path.join(test_root, "fake-codex")
      File.mkdir_p!(test_root)

      File.write!(codex_binary, """
      #!/bin/sh
      count=0

      while IFS= read -r _line; do
        count=$((count + 1))

        case "$count" in
          1)
            printf '%s\\n' '{"id":1,"result":{}}'
            ;;
          3)
            printf '%s\\n' '{"id":2,"result":{"account":null,"requiresOpenaiAuth":true}}'
            exit 0
            ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        codex_command: "#{codex_binary} app-server"
      )

      Application.delete_env(:symphony_elixir, :codex_account_summary_override)
      CodexAccount.clear_cache_for_test()

      assert CodexAccount.summary() == %{
               status: "signed_out",
               type: nil,
               auth_mode: nil,
               email: nil,
               plan_type: nil,
               requires_openai_auth: true
             }
    after
      CodexAccount.clear_cache_for_test()
      Application.put_env(:symphony_elixir, :codex_account_summary_override, nil)
      File.rm_rf(test_root)
    end
  end
end
