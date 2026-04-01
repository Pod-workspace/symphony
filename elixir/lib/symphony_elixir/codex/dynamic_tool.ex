defmodule SymphonyElixir.Codex.DynamicTool do
  @moduledoc """
  Executes client-side tool calls requested by Codex app-server turns.
  """

  alias SymphonyElixir.Config
  alias SymphonyElixir.Linear.Client
  alias SymphonyElixir.Notion.Client, as: NotionClient

  @linear_graphql_tool "linear_graphql"
  @linear_graphql_description """
  Execute a raw GraphQL query or mutation against Linear using Symphony's configured auth.
  """
  @linear_graphql_input_schema %{
    "type" => "object",
    "additionalProperties" => false,
    "required" => ["query"],
    "properties" => %{
      "query" => %{
        "type" => "string",
        "description" => "GraphQL query or mutation document to execute against Linear."
      },
      "variables" => %{
        "type" => ["object", "null"],
        "description" => "Optional GraphQL variables object.",
        "additionalProperties" => true
      }
    }
  }

  @notion_api_tool "notion_api"
  @notion_api_description """
  Execute a raw REST request against Notion using Symphony's configured auth.
  """
  @notion_api_input_schema %{
    "type" => "object",
    "additionalProperties" => false,
    "required" => ["method", "path"],
    "properties" => %{
      "method" => %{
        "type" => "string",
        "description" => "HTTP method to execute, e.g. GET, POST, PATCH, or DELETE."
      },
      "path" => %{
        "type" => "string",
        "description" => "Request path relative to the Notion API root, e.g. `/pages/<id>`."
      },
      "query" => %{
        "type" => ["object", "null"],
        "description" => "Optional query string parameters.",
        "additionalProperties" => true
      },
      "body" => %{
        "type" => ["object", "null"],
        "description" => "Optional JSON request body.",
        "additionalProperties" => true
      }
    }
  }

  @sync_workpad_tool "sync_workpad"
  @sync_workpad_description """
  Sync a local markdown workpad to the configured tracker issue while keeping the conversation context small.
  """
  @sync_workpad_create "mutation($issueId: String!, $body: String!) { commentCreate(input: { issueId: $issueId, body: $body }) { success comment { id url } } }"
  @sync_workpad_update "mutation($id: String!, $body: String!) { commentUpdate(id: $id, input: { body: $body }) { success comment { id url } } }"
  @sync_workpad_input_schema %{
    "type" => "object",
    "additionalProperties" => false,
    "required" => ["issue_id", "file_path"],
    "properties" => %{
      "issue_id" => %{
        "type" => "string",
        "description" => "Tracker issue identifier or internal UUID/page ID."
      },
      "file_path" => %{
        "type" => "string",
        "description" => "Path to a local markdown file whose contents become the tracker workpad body."
      },
      "comment_id" => %{
        "type" => "string",
        "description" => "Existing tracker-side workpad identifier to update when supported."
      }
    }
  }

  @spec execute(String.t() | nil, term(), keyword()) :: map()
  def execute(tool, arguments, opts \\ []) do
    case tool do
      @linear_graphql_tool ->
        execute_linear_graphql(arguments, opts)

      @notion_api_tool ->
        execute_notion_api(arguments, opts)

      @sync_workpad_tool ->
        execute_sync_workpad(arguments, opts)

      other ->
        failure_response(%{
          "error" => %{
            "message" => "Unsupported dynamic tool: #{inspect(other)}.",
            "supportedTools" => supported_tool_names()
          }
        })
    end
  end

  @spec tool_specs() :: [map()]
  def tool_specs do
    case Config.settings!().tracker.kind do
      "notion" ->
        [
          %{
            "name" => @notion_api_tool,
            "description" => @notion_api_description,
            "inputSchema" => @notion_api_input_schema
          },
          sync_workpad_tool_spec()
        ]

      _ ->
        [
          %{
            "name" => @linear_graphql_tool,
            "description" => @linear_graphql_description,
            "inputSchema" => @linear_graphql_input_schema
          },
          sync_workpad_tool_spec()
        ]
    end
  end

  defp sync_workpad_tool_spec do
    %{
      "name" => @sync_workpad_tool,
      "description" => @sync_workpad_description,
      "inputSchema" => @sync_workpad_input_schema
    }
  end

  defp execute_linear_graphql(arguments, opts) do
    linear_client = Keyword.get(opts, :linear_client, &Client.graphql/3)

    with {:ok, query, variables} <- normalize_linear_graphql_arguments(arguments),
         {:ok, response} <- linear_client.(query, variables, []) do
      graphql_response(response)
    else
      {:error, reason} ->
        failure_response(tool_error_payload(reason))
    end
  end

  defp execute_notion_api(arguments, opts) do
    notion_request = Keyword.get(opts, :notion_request, &NotionClient.request/3)

    with {:ok, method, path, query, body} <- normalize_notion_api_arguments(arguments),
         {:ok, response} <- notion_request.(method, path, query: query, body: body) do
      graphql_response(response)
    else
      {:error, reason} ->
        failure_response(tool_error_payload(reason))
    end
  end

  defp execute_sync_workpad(args, opts) do
    with {:ok, issue_id, file_path, comment_id} <- normalize_sync_workpad_args(args),
         {:ok, body} <- read_workpad_file(file_path) do
      execute_sync_workpad_for_tracker(issue_id, body, comment_id, opts)
    else
      {:error, reason} ->
        failure_response(tool_error_payload(reason))
    end
  end

  defp execute_sync_workpad_for_tracker(issue_id, body, comment_id, opts) do
    case Config.settings!().tracker.kind do
      "notion" ->
        notion_sync_workpad = Keyword.get(opts, :notion_sync_workpad, &NotionClient.sync_workpad/2)

        case notion_sync_workpad.(issue_id, body) do
          {:ok, response} -> graphql_response(response)
          {:error, reason} -> failure_response(tool_error_payload(reason))
        end

      _ ->
        execute_sync_workpad_linear(issue_id, body, comment_id, opts)
    end
  end

  defp execute_sync_workpad_linear(issue_id, body, comment_id, opts) do
    payload =
      if comment_id,
        do: %{"query" => @sync_workpad_update, "variables" => %{"id" => comment_id, "body" => body}},
        else: %{"query" => @sync_workpad_create, "variables" => %{"issueId" => issue_id, "body" => body}}

    execute_linear_graphql(payload, opts)
  end

  defp normalize_sync_workpad_args(%{} = args) do
    with {:ok, issue_id} <- required_sync_workpad_arg(args, "issue_id", :issue_id),
         {:ok, file_path} <- required_sync_workpad_arg(args, "file_path", :file_path) do
      {:ok, issue_id, file_path, optional_sync_workpad_arg(args, "comment_id", :comment_id)}
    end
  end

  defp normalize_sync_workpad_args(_args) do
    {:error, {:sync_workpad, "`issue_id` and `file_path` are required"}}
  end

  defp required_sync_workpad_arg(args, key, atom_key) do
    case Map.get(args, key) || Map.get(args, atom_key) do
      value when is_binary(value) and value != "" ->
        {:ok, value}

      _ ->
        {:error, {:sync_workpad, "`#{key}` is required"}}
    end
  end

  defp optional_sync_workpad_arg(args, key, atom_key) do
    case Map.get(args, key) || Map.get(args, atom_key) do
      value when is_binary(value) and value != "" -> value
      _ -> nil
    end
  end

  defp read_workpad_file(path) do
    case File.read(path) do
      {:ok, ""} -> {:error, {:sync_workpad, "file is empty: `#{path}`"}}
      {:ok, body} -> {:ok, body}
      {:error, reason} -> {:error, {:sync_workpad, "cannot read `#{path}`: #{:file.format_error(reason)}"}}
    end
  end

  defp normalize_linear_graphql_arguments(arguments) when is_binary(arguments) do
    case String.trim(arguments) do
      "" -> {:error, :missing_query}
      query -> {:ok, query, %{}}
    end
  end

  defp normalize_linear_graphql_arguments(arguments) when is_map(arguments) do
    case normalize_query(arguments) do
      {:ok, query} ->
        case normalize_variables(arguments) do
          {:ok, variables} -> {:ok, query, variables}
          {:error, reason} -> {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp normalize_linear_graphql_arguments(_arguments), do: {:error, :invalid_arguments}

  defp normalize_query(arguments) do
    case Map.get(arguments, "query") || Map.get(arguments, :query) do
      query when is_binary(query) ->
        case String.trim(query) do
          "" -> {:error, :missing_query}
          trimmed -> {:ok, trimmed}
        end

      _ ->
        {:error, :missing_query}
    end
  end

  defp normalize_variables(arguments) do
    case Map.get(arguments, "variables") || Map.get(arguments, :variables) || %{} do
      variables when is_map(variables) -> {:ok, variables}
      _ -> {:error, :invalid_variables}
    end
  end

  defp normalize_notion_api_arguments(arguments) when is_map(arguments) do
    method = Map.get(arguments, "method") || Map.get(arguments, :method)
    path = Map.get(arguments, "path") || Map.get(arguments, :path)
    query = optional_map_argument(arguments, "query", :query)
    body = optional_map_argument(arguments, "body", :body)

    cond do
      not is_binary(method) or String.trim(method) == "" ->
        {:error, :missing_notion_method}

      not is_binary(path) or String.trim(path) == "" ->
        {:error, :missing_notion_path}

      not is_nil(query) and not is_map(query) ->
        {:error, :invalid_notion_query}

      not is_nil(body) and not is_map(body) ->
        {:error, :invalid_notion_body}

      true ->
        {:ok, method, String.trim(path), query, body}
    end
  end

  defp normalize_notion_api_arguments(_arguments), do: {:error, :invalid_notion_arguments}

  defp graphql_response(response) do
    success =
      case response do
        %{"errors" => errors} when is_list(errors) and errors != [] -> false
        %{errors: errors} when is_list(errors) and errors != [] -> false
        _ -> true
      end

    %{
      "success" => success,
      "contentItems" => [
        %{
          "type" => "inputText",
          "text" => encode_payload(response)
        }
      ]
    }
  end

  defp failure_response(payload) do
    %{
      "success" => false,
      "contentItems" => [
        %{
          "type" => "inputText",
          "text" => encode_payload(payload)
        }
      ]
    }
  end

  defp encode_payload(payload) when is_map(payload) or is_list(payload) do
    Jason.encode!(payload, pretty: true)
  end

  defp encode_payload(payload), do: inspect(payload)

  defp tool_error_payload({:sync_workpad, message}) do
    %{"error" => %{"message" => "sync_workpad: #{message}"}}
  end

  defp tool_error_payload(:missing_query) do
    %{"error" => %{"message" => "`linear_graphql` requires a non-empty `query` string."}}
  end

  defp tool_error_payload(:invalid_arguments) do
    %{
      "error" => %{
        "message" => "`linear_graphql` expects either a GraphQL query string or an object with `query` and optional `variables`."
      }
    }
  end

  defp tool_error_payload(:invalid_variables) do
    %{"error" => %{"message" => "`linear_graphql.variables` must be a JSON object when provided."}}
  end

  defp tool_error_payload(:missing_notion_method) do
    %{"error" => %{"message" => "`notion_api` requires a non-empty `method` string."}}
  end

  defp tool_error_payload(:missing_notion_path) do
    %{"error" => %{"message" => "`notion_api` requires a non-empty `path` string."}}
  end

  defp tool_error_payload(:invalid_notion_method) do
    %{
      "error" => %{
        "message" => "`notion_api.method` must be one of GET, POST, PATCH, PUT, or DELETE."
      }
    }
  end

  defp tool_error_payload(:invalid_notion_arguments) do
    %{
      "error" => %{
        "message" => "`notion_api` expects an object with `method`, `path`, and optional `query`/`body` maps."
      }
    }
  end

  defp tool_error_payload(:invalid_notion_query) do
    %{"error" => %{"message" => "`notion_api.query` must be a JSON object when provided."}}
  end

  defp tool_error_payload(:invalid_notion_body) do
    %{"error" => %{"message" => "`notion_api.body` must be a JSON object when provided."}}
  end

  defp tool_error_payload(:missing_linear_api_token) do
    %{
      "error" => %{
        "message" => "Symphony is missing Linear auth. Set `linear.api_key` in `WORKFLOW.md` or export `LINEAR_API_KEY`."
      }
    }
  end

  defp tool_error_payload(:missing_notion_api_token) do
    %{
      "error" => %{
        "message" => "Symphony is missing Notion auth. Set `tracker.api_key` in `WORKFLOW.md` or export `NOTION_API_KEY`."
      }
    }
  end

  defp tool_error_payload({:linear_api_status, status}) do
    %{"error" => %{"message" => "Linear GraphQL request failed with HTTP #{status}.", "status" => status}}
  end

  defp tool_error_payload({:linear_api_request, reason}) do
    %{
      "error" => %{
        "message" => "Linear GraphQL request failed before receiving a successful response.",
        "reason" => inspect(reason)
      }
    }
  end

  defp tool_error_payload({:notion_api_status, status, body}) do
    %{
      "error" => %{
        "message" => "Notion API request failed with HTTP #{status}.",
        "status" => status,
        "body" => body
      }
    }
  end

  defp tool_error_payload({:notion_api_request, reason}) do
    %{
      "error" => %{
        "message" => "Notion API request failed before receiving a successful response.",
        "reason" => inspect(reason)
      }
    }
  end

  defp tool_error_payload(reason) do
    case Config.settings!().tracker.kind do
      "notion" ->
        %{"error" => %{"message" => "Notion dynamic tool execution failed.", "reason" => inspect(reason)}}

      _ ->
        %{"error" => %{"message" => "Linear GraphQL tool execution failed.", "reason" => inspect(reason)}}
    end
  end

  defp supported_tool_names do
    Enum.map(tool_specs(), & &1["name"])
  end

  defp optional_map_argument(arguments, string_key, atom_key) do
    cond do
      Map.has_key?(arguments, string_key) -> Map.get(arguments, string_key)
      Map.has_key?(arguments, atom_key) -> Map.get(arguments, atom_key)
      true -> nil
    end
  end
end
