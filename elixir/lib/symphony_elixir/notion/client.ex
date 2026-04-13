defmodule SymphonyElixir.Notion.Client do
  @moduledoc """
  Thin Notion REST client for polling candidate issues.
  """

  require Logger

  alias SymphonyElixir.{Config, Linear.Issue}

  @page_size 50
  @max_error_body_log_bytes 1_000
  @workpad_marker_begin "<!-- SYMPHONY:WORKPAD:BEGIN -->"
  @workpad_marker_end "<!-- SYMPHONY:WORKPAD:END -->"
  @allowed_methods ~w(get post patch put delete)a

  @spec fetch_candidate_issues() :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_candidate_issues do
    with :ok <- validate_tracker_config(),
         {:ok, assignee_filter} <- routing_assignee_filter() do
      Config.settings!().tracker.active_states
      |> do_fetch_by_states(assignee_filter, true)
    end
  end

  @spec fetch_issues_by_states([String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issues_by_states(state_names) when is_list(state_names) do
    normalized_states = Enum.map(state_names, &to_string/1) |> Enum.uniq()

    case normalized_states do
      [] ->
        {:ok, []}

      _ ->
        with :ok <- validate_tracker_config() do
          do_fetch_by_states(normalized_states, nil, true)
        end
    end
  end

  @spec fetch_issue_states_by_ids([String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issue_states_by_ids(issue_ids) when is_list(issue_ids) do
    ids = issue_ids |> Enum.map(&to_string/1) |> Enum.uniq()

    case ids do
      [] ->
        {:ok, []}

      _ ->
        with :ok <- validate_tracker_config(),
             {:ok, assignee_filter} <- routing_assignee_filter(),
             {:ok, issues} <- fetch_pages_by_ids(ids, assignee_filter, false) do
          # Hydrate blockers so revalidation can check if Todo issues
          # are still blocked or if their blockers have reached terminal state.
          hydrate_blocker_metadata(issues)
        end
    end
  end

  @spec request(String.t() | atom(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def request(method, path, opts \\ [])
      when (is_binary(method) or is_atom(method)) and is_binary(path) and is_list(opts) do
    request_fun = Keyword.get(opts, :request_fun, &Req.request/1)
    query = Keyword.get(opts, :query)
    body = Keyword.get(opts, :body)

    with {:ok, method} <- normalize_method(method),
         {:ok, headers} <- request_headers(),
         request_opts <- build_request_options(method, path, headers, query, body),
         {:ok, %{status: status, body: response_body} = response} <- request_fun.(request_opts) do
      if status in 200..299 do
        {:ok, response_body}
      else
        Logger.error("Notion API request failed status=#{status}" <> notion_error_context(method, path, response))
        {:error, {:notion_api_status, status, response_body}}
      end
    else
      {:error, :invalid_notion_method} ->
        {:error, :invalid_notion_method}

      {:error, :missing_notion_api_token} ->
        {:error, :missing_notion_api_token}

      {:error, reason} ->
        Logger.error("Notion API request failed: #{inspect(reason)}")
        {:error, {:notion_api_request, reason}}
    end
  end

  @spec create_comment(String.t(), String.t()) :: :ok | {:error, term()}
  def create_comment(page_id, body) when is_binary(page_id) and is_binary(body) do
    payload = %{
      "parent" => %{"page_id" => page_id},
      "rich_text" => [text_rich_text(body)]
    }

    with {:ok, response} <- request(:post, "/comments", body: payload),
         "comment" <- response["object"] do
      :ok
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :comment_create_failed}
    end
  end

  @spec update_issue_state(String.t(), String.t()) :: :ok | {:error, term()}
  def update_issue_state(page_id, state_name) when is_binary(page_id) and is_binary(state_name) do
    with {:ok, data_source} <- retrieve_data_source(),
         {:ok, property_name, property_type} <- state_property_details(data_source),
         notion_state when is_binary(notion_state) <- notion_state_name(state_name),
         {:ok, response} <-
           request(
             :patch,
             "/pages/#{page_id}",
             body: %{"properties" => %{property_name => build_property_update(property_type, notion_state)}}
           ),
         "page" <- response["object"] do
      :ok
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :issue_update_failed}
    end
  end

  @spec sync_workpad(String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def sync_workpad(page_id, body) when is_binary(page_id) and is_binary(body) do
    with {:ok, page} <- retrieve_page(page_id),
         {:ok, markdown} <- retrieve_page_markdown(page_id),
         heading <- workpad_heading(),
         existing_section <- extract_workpad_section(markdown, heading),
         new_section <- build_workpad_section(body, heading),
         {:ok, _response} <- apply_workpad_update(page_id, markdown, existing_section, new_section) do
      {:ok,
       %{
         "data" => %{
           "syncWorkpad" => %{
             "id" => page_id,
             "url" => page["url"],
             "heading" => heading
           }
         }
       }}
    end
  end

  @doc false
  @spec normalize_page_for_test(map(), keyword()) :: Issue.t() | nil
  def normalize_page_for_test(page, opts \\ []) when is_map(page) and is_list(opts) do
    normalize_page(page, Keyword.get(opts, :assignee_filter), Keyword.get(opts, :description))
  end

  @doc false
  @spec strip_workpad_for_test(String.t()) :: String.t() | nil
  def strip_workpad_for_test(markdown) when is_binary(markdown), do: strip_workpad(markdown)

  @doc false
  @spec build_workpad_section_for_test(String.t(), String.t()) :: String.t()
  def build_workpad_section_for_test(body, heading) when is_binary(body) and is_binary(heading) do
    build_workpad_section(body, heading)
  end

  @doc false
  @spec extract_workpad_section_for_test(String.t(), String.t()) :: String.t() | nil
  def extract_workpad_section_for_test(markdown, heading)
      when is_binary(markdown) and is_binary(heading) do
    extract_workpad_section(markdown, heading)
  end

  defp validate_tracker_config do
    tracker = Config.settings!().tracker

    cond do
      not is_binary(tracker.api_key) ->
        {:error, :missing_notion_api_token}

      not is_binary(tracker.data_source_id) ->
        {:error, :missing_notion_data_source_id}

      true ->
        :ok
    end
  end

  defp do_fetch_by_states(state_names, assignee_filter, include_markdown?) do
    with {:ok, data_source} <- retrieve_data_source() do
      notion_states =
        state_names
        |> Enum.map(&notion_state_name/1)
        |> Enum.filter(&is_binary/1)
        |> Enum.uniq()

      properties = query_filter_properties()
      filter = build_state_filter(data_source, notion_states)
      do_query_data_source_pages(filter, properties, assignee_filter, include_markdown?, nil, [])
    end
  end

  defp do_query_data_source_pages(filter, properties, assignee_filter, include_markdown?, start_cursor, acc) do
    payload =
      %{
        "page_size" => @page_size,
        "result_type" => "page"
      }
      |> maybe_put_filter(filter)
      |> maybe_put_start_cursor(start_cursor)

    with {:ok, response} <- query_data_source(payload, properties),
         {:ok, pages, next_cursor} <- decode_query_response(response),
         {:ok, issues} <- build_issues_from_pages(pages, assignee_filter, include_markdown?, true) do
      updated_acc = acc ++ issues

      case next_cursor do
        nil -> {:ok, updated_acc}
        cursor -> do_query_data_source_pages(filter, properties, assignee_filter, include_markdown?, cursor, updated_acc)
      end
    end
  end

  defp build_issues_from_pages(pages, assignee_filter, include_markdown?, hydrate_blockers?)
       when is_list(pages) do
    with {:ok, descriptions} <- maybe_fetch_descriptions(pages, include_markdown?) do
      issues =
        pages
        |> Enum.map(fn page ->
          normalize_page(page, assignee_filter, Map.get(descriptions, page["id"]))
        end)
        |> Enum.reject(&is_nil/1)

      if hydrate_blockers? do
        hydrate_blocker_metadata(issues)
      else
        {:ok, issues}
      end
    end
  end

  defp fetch_pages_by_ids(ids, assignee_filter, include_markdown?) when is_list(ids) do
    pages =
      ids
      |> Enum.reduce([], fn page_id, acc ->
        case retrieve_page(page_id) do
          {:ok, page} ->
            [page | acc]

          {:error, reason} ->
            Logger.debug("Skipping blocker page #{page_id}: #{inspect(reason)}")
            acc
        end
      end)
      |> Enum.reverse()

    build_issues_from_pages(pages, assignee_filter, include_markdown?, false)
  end

  defp hydrate_blocker_metadata(issues) when is_list(issues) do
    blocker_ids =
      issues
      |> Enum.flat_map(fn %Issue{blocked_by: blocked_by} -> blocked_by end)
      |> Enum.map(& &1.id)
      |> Enum.filter(&is_binary/1)
      |> Enum.uniq()

    case fetch_pages_by_ids(blocker_ids, nil, false) do
      {:ok, blocker_issues} ->
        blocker_index =
          Map.new(blocker_issues, fn %Issue{id: blocker_id, identifier: identifier, state: state} ->
            {blocker_id, %{identifier: identifier, state: state}}
          end)

        {:ok,
         Enum.map(issues, fn %Issue{blocked_by: blocked_by} = issue ->
           hydrated_blockers =
             Enum.map(blocked_by, fn blocker ->
               blocker
               |> Map.put(:identifier, get_in(blocker_index, [blocker.id, :identifier]) || blocker.identifier)
               |> Map.put(:state, get_in(blocker_index, [blocker.id, :state]) || blocker.state)
             end)

           %{issue | blocked_by: hydrated_blockers}
         end)}

      {:error, _reason} ->
        # Hydration failed; keep issues with unhydrated blockers.
        # The orchestrator treats nil-state blockers as blocking (conservative).
        Logger.warning("Blocker hydration failed; unhydrated blockers will be treated as blocking")
        {:ok, issues}
    end
  end

  defp maybe_fetch_descriptions(_pages, false), do: {:ok, %{}}

  defp maybe_fetch_descriptions(pages, true) when is_list(pages) do
    Enum.reduce_while(pages, {:ok, %{}}, fn page, {:ok, acc} ->
      case page["id"] do
        page_id when is_binary(page_id) ->
          case retrieve_page_markdown(page_id) do
            {:ok, markdown} ->
              {:cont, {:ok, Map.put(acc, page_id, markdown)}}

            {:error, reason} ->
              {:halt, {:error, reason}}
          end

        _ ->
          {:cont, {:ok, acc}}
      end
    end)
  end

  defp query_data_source(payload, filter_properties) do
    request(
      :post,
      "/data_sources/#{Config.settings!().tracker.data_source_id}/query",
      query: query_filter_properties_param(filter_properties),
      body: payload
    )
  end

  defp retrieve_data_source do
    request(:get, "/data_sources/#{Config.settings!().tracker.data_source_id}")
  end

  defp retrieve_page(page_id), do: request(:get, "/pages/#{page_id}")

  defp retrieve_page_markdown(page_id) do
    with {:ok, response} <- request(:get, "/pages/#{page_id}/markdown"),
         markdown when is_binary(markdown) <- response["markdown"] do
      {:ok, markdown}
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :notion_markdown_unavailable}
    end
  end

  defp apply_workpad_update(page_id, markdown, nil, new_section) do
    content =
      case String.trim(markdown) do
        "" -> new_section
        _ -> String.trim_trailing(markdown) <> "\n\n" <> new_section
      end

    request(
      :patch,
      "/pages/#{page_id}/markdown",
      body: %{
        "type" => "replace_content",
        "replace_content" => %{"new_str" => content}
      }
    )
  end

  defp apply_workpad_update(page_id, _markdown, existing_section, new_section) do
    if existing_section == new_section do
      {:ok, %{"object" => "page_markdown"}}
    else
      request(
        :patch,
        "/pages/#{page_id}/markdown",
        body: %{
          "type" => "update_content",
          "update_content" => %{
            "content_updates" => [
              %{
                "old_str" => existing_section,
                "new_str" => new_section
              }
            ]
          }
        }
      )
    end
  end

  defp request_headers do
    tracker = Config.settings!().tracker

    case tracker.api_key do
      token when is_binary(token) ->
        {:ok,
         [
           {"Authorization", "Bearer " <> token},
           {"Content-Type", "application/json"},
           {"Notion-Version", notion_version()}
         ]}

      _ ->
        {:error, :missing_notion_api_token}
    end
  end

  defp build_request_options(method, path, headers, query, body) do
    [
      method: method,
      url: notion_url(path),
      headers: headers,
      decode_json: [],
      params: normalize_optional_map(query),
      json: normalize_optional_map(body),
      connect_options: [timeout: 30_000],
      receive_timeout: 30_000
    ]
    |> Enum.reject(fn
      {_key, nil} -> true
      _ -> false
    end)
  end

  defp notion_url(path) do
    base = String.trim_trailing(Config.settings!().tracker.endpoint, "/")
    normalized_path = if String.starts_with?(path, "/"), do: path, else: "/" <> path
    base <> normalized_path
  end

  defp notion_error_context(method, path, response) do
    " method=#{method} path=#{path} body=" <> summarize_error_body(response.body)
  end

  defp summarize_error_body(body) when is_binary(body) do
    body
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
    |> truncate_error_body()
    |> inspect()
  end

  defp summarize_error_body(body) do
    body
    |> inspect(limit: 20, printable_limit: @max_error_body_log_bytes)
    |> truncate_error_body()
  end

  defp truncate_error_body(body) when is_binary(body) do
    if byte_size(body) > @max_error_body_log_bytes do
      binary_part(body, 0, @max_error_body_log_bytes) <> "...<truncated>"
    else
      body
    end
  end

  defp decode_query_response(%{"results" => results, "has_more" => has_more, "next_cursor" => next_cursor})
       when is_list(results) do
    {:ok, results, if(has_more == true, do: next_cursor, else: nil)}
  end

  defp decode_query_response(_response), do: {:error, :notion_unknown_payload}

  defp normalize_page(page, assignee_filter, description) when is_map(page) do
    properties = Map.get(page, "properties", %{})
    assignees = people_values(Map.get(properties, notion_property_name("assignee")))

    %Issue{
      id: page["id"],
      identifier: issue_identifier(properties, page["id"]),
      title: title_value(properties),
      description: strip_workpad(description),
      priority: priority_value(properties),
      state: state_value(properties),
      branch_name: nil,
      url: page["url"],
      assignee_id: first_assignee_id(assignees),
      blocked_by: relation_refs(Map.get(properties, notion_property_name("blocked_by"))),
      labels: labels_value(properties),
      assigned_to_worker: assigned_to_worker?(assignees, assignee_filter),
      created_at: parse_datetime(page["created_time"]),
      updated_at: parse_datetime(page["last_edited_time"])
    }
  end

  defp normalize_page(_page, _assignee_filter, _description), do: nil

  defp title_value(properties) when is_map(properties) do
    properties
    |> Map.get(notion_property_name("title"))
    |> plain_text_value()
  end

  defp state_value(properties) when is_map(properties) do
    properties
    |> Map.get(notion_property_name("state"))
    |> property_option_name()
    |> from_notion_state_name()
  end

  defp labels_value(properties) when is_map(properties) do
    case Map.get(properties, notion_property_name("labels")) do
      %{"type" => "multi_select", "multi_select" => values} when is_list(values) ->
        values
        |> Enum.map(&Map.get(&1, "name"))
        |> Enum.filter(&is_binary/1)
        |> Enum.map(&String.downcase/1)

      %{"type" => "select"} = property ->
        case property_option_name(property) do
          label when is_binary(label) -> [String.downcase(label)]
          _ -> []
        end

      _ ->
        []
    end
  end

  defp relation_refs(%{"type" => "relation", "relation" => values}) when is_list(values) do
    Enum.map(values, fn
      %{"id" => relation_id} ->
        %{id: relation_id, identifier: nil, state: nil}

      _ ->
        %{id: nil, identifier: nil, state: nil}
    end)
  end

  defp relation_refs(_value), do: []

  defp priority_value(properties) when is_map(properties) do
    property = Map.get(properties, notion_property_name("priority"))

    cond do
      is_nil(property) ->
        nil

      property["type"] == "number" ->
        parse_priority(property["number"])

      true ->
        case property_option_name(property) do
          label when is_binary(label) ->
            parse_priority(from_notion_priority_label(label))

          _ ->
            nil
        end
    end
  end

  defp parse_priority(value) when is_integer(value), do: value

  defp parse_priority(value) when is_binary(value) do
    case Integer.parse(value) do
      {number, ""} -> number
      _ -> parse_priority_digits(value)
    end
  end

  defp parse_priority(_value), do: nil

  defp parse_priority_digits(value) when is_binary(value) do
    case Regex.run(~r/(\d+)/, value) do
      [_, digits] ->
        case Integer.parse(digits) do
          {number, ""} -> number
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp issue_identifier(properties, fallback_id) when is_map(properties) do
    property = Map.get(properties, notion_property_name("id_number"))
    prefix = notion_identifier_prefix()

    case property do
      %{"type" => "unique_id", "unique_id" => %{"number" => number, "prefix" => property_prefix}}
      when is_integer(number) ->
        join_identifier(prefix || property_prefix, number)

      %{"type" => "number", "number" => number} when is_integer(number) ->
        join_identifier(prefix, number)

      %{"type" => "rich_text", "rich_text" => _values} = rich_text ->
        plain_text_value(rich_text) || fallback_id

      _ ->
        fallback_id
    end
  end

  defp join_identifier(prefix, number) when is_binary(prefix) and prefix != "" do
    normalized_prefix = String.trim_trailing(prefix, "-")
    normalized_prefix <> "-" <> to_string(number)
  end

  defp join_identifier(_prefix, number), do: to_string(number)

  defp people_values(%{"type" => "people", "people" => values}) when is_list(values), do: values
  defp people_values(_value), do: []

  defp first_assignee_id([%{"id" => user_id} | _]) when is_binary(user_id), do: user_id
  defp first_assignee_id(_users), do: nil

  defp assigned_to_worker?(_assignees, nil), do: true

  defp assigned_to_worker?(assignees, %{match_values: match_values}) when is_list(assignees) do
    assignees
    |> Enum.flat_map(fn user ->
      user_match_values(user)
      |> MapSet.to_list()
    end)
    |> MapSet.new()
    |> then(&MapSet.disjoint?(&1, match_values))
    |> Kernel.not()
  end

  defp assigned_to_worker?(_assignees, _assignee_filter), do: false

  defp routing_assignee_filter do
    case Config.settings!().tracker.assignee do
      nil ->
        {:ok, nil}

      assignee ->
        build_assignee_filter(assignee)
    end
  end

  defp build_assignee_filter(assignee) when is_binary(assignee) do
    case normalize_assignee_match_value(assignee) do
      nil ->
        {:ok, nil}

      "me" ->
        case request(:get, "/users/me") do
          {:ok, user} -> {:ok, %{configured_assignee: assignee, match_values: user_match_values(user)}}
          {:error, reason} -> {:error, reason}
        end

      normalized ->
        {:ok, %{configured_assignee: assignee, match_values: MapSet.new([normalized])}}
    end
  end

  defp normalize_assignee_match_value(value) when is_binary(value) do
    case value |> String.trim() |> String.downcase() do
      "" -> nil
      normalized -> normalized
    end
  end

  defp normalize_assignee_match_value(_value), do: nil

  defp user_match_values(%{} = user) do
    values =
      [
        user["id"],
        user["name"],
        get_in(user, ["person", "email"])
      ]
      |> Enum.map(&normalize_assignee_match_value/1)
      |> Enum.reject(&is_nil/1)

    MapSet.new(values)
  end

  defp build_state_filter(_data_source, []), do: nil

  defp build_state_filter(data_source, notion_states) do
    with {:ok, property_name, property_type} <- state_property_details(data_source) do
      conditions =
        Enum.map(notion_states, fn notion_state ->
          %{
            "property" => property_name,
            property_type => %{"equals" => notion_state}
          }
        end)

      case conditions do
        [single] -> single
        many -> %{"or" => many}
      end
    else
      _ -> nil
    end
  end

  defp state_property_details(%{"properties" => properties}) when is_map(properties) do
    property_name = notion_property_name("state")

    case Map.get(properties, property_name) do
      %{"type" => "select"} -> {:ok, property_name, "select"}
      %{"type" => "status"} -> {:ok, property_name, "status"}
      _ -> {:error, :notion_state_property_missing}
    end
  end

  defp state_property_details(_data_source), do: {:error, :notion_state_property_missing}

  defp maybe_put_filter(payload, nil), do: payload
  defp maybe_put_filter(payload, filter), do: Map.put(payload, "filter", filter)

  defp maybe_put_start_cursor(payload, nil), do: payload
  defp maybe_put_start_cursor(payload, cursor), do: Map.put(payload, "start_cursor", cursor)

  defp query_filter_properties do
    notion_properties()
    |> Map.values()
    |> Enum.filter(&is_binary/1)
    |> Enum.uniq()
  end

  defp query_filter_properties_param(values) when is_list(values) do
    case Enum.reject(values, &is_nil/1) do
      [] -> nil
      filtered -> Enum.map(filtered, &{"filter_properties[]", &1})
    end
  end

  defp notion_version do
    get_in(Config.settings!().tracker.notion, ["version"]) || "2026-03-11"
  end

  defp notion_properties do
    get_in(Config.settings!().tracker.notion, ["properties"]) || %{}
  end

  defp notion_property_name(key) do
    notion_properties()[key]
  end

  defp notion_identifier_prefix do
    get_in(Config.settings!().tracker.notion, ["identifier", "prefix"])
  end

  defp notion_state_name(state_name) when is_binary(state_name) do
    get_in(Config.settings!().tracker.notion, ["state_map", state_name]) || state_name
  end

  defp from_notion_state_name(nil), do: nil

  defp from_notion_state_name(notion_state_name) when is_binary(notion_state_name) do
    Config.settings!().tracker.notion
    |> get_in(["state_map"])
    |> case do
      %{} = state_map ->
        Enum.find_value(state_map, notion_state_name, fn {symphony_state, mapped_state} ->
          if mapped_state == notion_state_name, do: symphony_state
        end)

      _ ->
        notion_state_name
    end
  end

  defp from_notion_priority_label(label) when is_binary(label) do
    Config.settings!().tracker.notion
    |> get_in(["priority_map"])
    |> case do
      %{} = priority_map ->
        Enum.find_value(priority_map, label, fn {priority, mapped_label} ->
          if mapped_label == label, do: priority
        end)

      _ ->
        label
    end
  end

  defp build_property_update("select", value), do: %{"select" => %{"name" => value}}
  defp build_property_update(_type, value), do: %{"status" => %{"name" => value}}

  defp property_option_name(%{"type" => "status", "status" => %{"name" => name}}) when is_binary(name), do: name
  defp property_option_name(%{"type" => "select", "select" => %{"name" => name}}) when is_binary(name), do: name
  defp property_option_name(_property), do: nil

  defp plain_text_value(%{"type" => "title", "title" => values}) when is_list(values), do: join_rich_text(values)
  defp plain_text_value(%{"type" => "rich_text", "rich_text" => values}) when is_list(values), do: join_rich_text(values)
  defp plain_text_value(_value), do: nil

  defp join_rich_text(values) when is_list(values) do
    values
    |> Enum.map(fn
      %{"plain_text" => text} when is_binary(text) -> text
      %{"text" => %{"content" => text}} when is_binary(text) -> text
      _ -> nil
    end)
    |> Enum.reject(&is_nil/1)
    |> Enum.join()
    |> case do
      "" -> nil
      text -> text
    end
  end

  defp parse_datetime(nil), do: nil

  defp parse_datetime(raw) do
    case DateTime.from_iso8601(raw) do
      {:ok, dt, _offset} -> dt
      _ -> nil
    end
  end

  defp strip_workpad(nil), do: nil

  defp strip_workpad(markdown) when is_binary(markdown) do
    heading = workpad_heading()

    markdown
    |> then(&Regex.replace(workpad_section_regex(heading), &1, ""))
    |> String.trim()
    |> case do
      "" -> nil
      stripped -> stripped
    end
  end

  defp build_workpad_section(body, heading) when is_binary(body) and is_binary(heading) do
    normalized_body = String.trim(body)

    """
    ## #{heading}

    #{@workpad_marker_begin}
    #{normalized_body}
    #{@workpad_marker_end}
    """
    |> String.trim()
  end

  defp extract_workpad_section(markdown, heading) when is_binary(markdown) and is_binary(heading) do
    case Regex.run(workpad_section_regex(heading), markdown) do
      [section] -> section
      _ -> nil
    end
  end

  defp workpad_section_regex(heading) do
    # Notion's markdown API backslash-escapes angle brackets in HTML comments,
    # returning \<!-- ... --\> instead of <!-- ... -->. Match both forms so we
    # find the existing workpad section instead of appending a duplicate.
    esc_heading = Regex.escape(heading)
    begin_pat = marker_pattern(@workpad_marker_begin)
    end_pat = marker_pattern(@workpad_marker_end)

    Regex.compile!("## #{esc_heading}\n\n#{begin_pat}\n.*?\n#{end_pat}", "s")
  end

  defp marker_pattern(marker) do
    marker
    |> Regex.escape()
    |> String.replace("<", "\\\\?<")
    |> String.replace(">", "\\\\?>")
  end

  defp workpad_heading do
    get_in(Config.settings!().tracker.notion, ["workpad", "heading"]) || "Codex Workpad"
  end

  defp text_rich_text(body) when is_binary(body) do
    %{
      "type" => "text",
      "text" => %{"content" => body}
    }
  end

  defp normalize_method(method) when is_atom(method) do
    if method in @allowed_methods do
      {:ok, method}
    else
      {:error, :invalid_notion_method}
    end
  end

  defp normalize_method(method) when is_binary(method) do
    case method |> String.trim() |> String.downcase() do
      "" ->
        {:error, :invalid_notion_method}

      normalized ->
        try do
          normalized_atom = String.to_existing_atom(normalized)

          if normalized_atom in @allowed_methods do
            {:ok, normalized_atom}
          else
            {:error, :invalid_notion_method}
          end
        rescue
          ArgumentError -> {:error, :invalid_notion_method}
        end
    end
  end

  defp normalize_optional_map(nil), do: nil
  defp normalize_optional_map(value) when is_map(value), do: value
  defp normalize_optional_map(value) when is_list(value), do: value
end
