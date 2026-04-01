defmodule SymphonyElixir.NotionClientTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Notion.Client

  test "request builds authenticated notion requests without default GET bodies" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "notion",
      tracker_endpoint: nil,
      tracker_project_slug: nil,
      tracker_api_token: "notion-token",
      tracker_data_source_id: "data-source"
    )

    test_pid = self()

    assert {:ok, %{"object" => "page"}} =
             Client.request("GET", "/pages/page-1",
               request_fun: fn opts ->
                 send(test_pid, {:request_opts, opts})
                 {:ok, %{status: 200, body: %{"object" => "page"}}}
               end
             )

    assert_received {:request_opts, opts}
    assert opts[:method] == :get
    assert opts[:url] == "https://api.notion.com/v1/pages/page-1"
    assert opts[:decode_json] == []
    assert opts[:params] == nil
    refute Keyword.has_key?(opts, :json)
    assert {"Authorization", "Bearer notion-token"} in opts[:headers]
    assert {"Notion-Version", "2026-03-11"} in opts[:headers]
  end

  test "request rejects invalid notion methods and surfaces missing auth directly" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "notion",
      tracker_endpoint: nil,
      tracker_project_slug: nil,
      tracker_api_token: nil,
      tracker_data_source_id: "data-source"
    )

    assert {:error, :invalid_notion_method} =
             Client.request("TRACE", "/pages/page-1", request_fun: fn _opts -> flunk("request should not be executed for invalid methods") end)

    assert {:error, :missing_notion_api_token} =
             Client.request("GET", "/pages/page-1", request_fun: fn _opts -> flunk("request should not be executed without auth") end)
  end

  test "request preserves repeated query params for notion filter_properties encoding" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "notion",
      tracker_endpoint: nil,
      tracker_project_slug: nil,
      tracker_api_token: "notion-token",
      tracker_data_source_id: "data-source"
    )

    test_pid = self()

    assert {:ok, %{"object" => "list"}} =
             Client.request("POST", "/data_sources/data-source/query",
               query: [{"filter_properties[]", "Title"}, {"filter_properties[]", "Symphony Status"}],
               body: %{"page_size" => 1},
               request_fun: fn opts ->
                 send(test_pid, {:request_opts, opts})
                 {:ok, %{status: 200, body: %{"object" => "list"}}}
               end
             )

    assert_received {:request_opts, opts}
    assert opts[:params] == [{"filter_properties[]", "Title"}, {"filter_properties[]", "Symphony Status"}]
    assert opts[:json] == %{"page_size" => 1}
  end

  test "normalize_page applies notion property mappings and strips managed workpad content" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "notion",
      tracker_endpoint: nil,
      tracker_project_slug: nil,
      tracker_data_source_id: "data-source",
      tracker_notion: %{
        properties: %{
          title: "Task",
          state: "Workflow State",
          id_number: "Sequence",
          assignee: "Assignee",
          priority: "Priority",
          labels: "Labels",
          blocked_by: "Blocked By"
        },
        identifier: %{
          prefix: "GEN"
        },
        state_map: %{
          "In Progress" => "Doing"
        },
        priority_map: %{
          "5" => "P5"
        }
      }
    )

    markdown = """
    Ticket details.

    ## Codex Workpad

    <!-- SYMPHONY:WORKPAD:BEGIN -->
    Internal notes.
    <!-- SYMPHONY:WORKPAD:END -->
    """

    page = %{
      "id" => "page-1",
      "url" => "https://notion.so/page-1",
      "created_time" => "2026-01-01T00:00:00.000Z",
      "last_edited_time" => "2026-01-02T00:00:00.000Z",
      "properties" => %{
        "Task" => %{
          "type" => "title",
          "title" => [%{"plain_text" => "Investigate sync gap"}]
        },
        "Workflow State" => %{
          "type" => "status",
          "status" => %{"name" => "Doing"}
        },
        "Sequence" => %{
          "type" => "number",
          "number" => 42
        },
        "Assignee" => %{
          "type" => "people",
          "people" => [
            %{"id" => "user-1", "name" => "Dev User", "person" => %{"email" => "dev@example.com"}}
          ]
        },
        "Priority" => %{
          "type" => "select",
          "select" => %{"name" => "P5"}
        },
        "Labels" => %{
          "type" => "multi_select",
          "multi_select" => [%{"name" => "Bug"}, %{"name" => "Backend"}]
        },
        "Blocked By" => %{
          "type" => "relation",
          "relation" => [%{"id" => "page-2"}]
        }
      }
    }

    issue =
      Client.normalize_page_for_test(page,
        description: markdown,
        assignee_filter: %{match_values: MapSet.new(["dev@example.com"])}
      )

    assert issue.id == "page-1"
    assert issue.identifier == "GEN-42"
    assert issue.title == "Investigate sync gap"
    assert issue.description == "Ticket details."
    assert issue.state == "In Progress"
    assert issue.priority == 5
    assert issue.assignee_id == "user-1"
    assert issue.assigned_to_worker == true
    assert issue.labels == ["bug", "backend"]
    assert issue.blocked_by == [%{id: "page-2", identifier: nil, state: nil}]
    assert issue.created_at == ~U[2026-01-01 00:00:00.000Z]
    assert issue.updated_at == ~U[2026-01-02 00:00:00.000Z]
  end

  test "workpad helpers round-trip the managed markdown section" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "notion",
      tracker_endpoint: nil,
      tracker_project_slug: nil
    )

    section = Client.build_workpad_section_for_test("Progress update.", "Codex Workpad")

    assert section =~ "## Codex Workpad"
    assert section =~ "Progress update."

    markdown = """
    Body text.

    #{section}
    """

    assert Client.extract_workpad_section_for_test(markdown, "Codex Workpad") == section
    assert Client.strip_workpad_for_test(markdown) == "Body text."
  end
end
