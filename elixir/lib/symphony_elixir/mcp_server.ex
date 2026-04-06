defmodule SymphonyElixir.McpServer do
  @moduledoc """
  Minimal MCP (Model Context Protocol) server over stdio.

  Exposes Symphony's dynamic tools (notion_api, sync_workpad, linear_graphql)
  so that Claude Code can call them the same way Codex does via JSON-RPC.

  Launched as `symphony mcp-server <workflow-path>`.
  """

  require Logger

  alias SymphonyElixir.Codex.DynamicTool

  @protocol_version "2024-11-05"

  @spec run() :: no_return()
  def run do
    # Redirect Logger to stderr so it doesn't corrupt the stdio JSON-RPC stream
    :ok = configure_stderr_logging()
    stdio_loop()
  end

  defp stdio_loop do
    case IO.read(:stdio, :line) do
      :eof ->
        :ok

      {:error, _reason} ->
        :ok

      line when is_binary(line) ->
        line
        |> String.trim()
        |> handle_raw_line()

        stdio_loop()
    end
  end

  defp handle_raw_line(""), do: :ok

  defp handle_raw_line(line) do
    case Jason.decode(line) do
      {:ok, message} ->
        handle_message(message)

      {:error, _reason} ->
        Logger.warning("MCP server: ignoring non-JSON input")
    end
  end

  # ── JSON-RPC dispatch ────────────────────────────────────────────────

  defp handle_message(%{"method" => "initialize", "id" => id}) do
    respond(id, %{
      "protocolVersion" => @protocol_version,
      "capabilities" => %{"tools" => %{}},
      "serverInfo" => %{
        "name" => "symphony",
        "version" => "0.1.0"
      }
    })
  end

  defp handle_message(%{"method" => "notifications/initialized"}), do: :ok

  defp handle_message(%{"method" => "tools/list", "id" => id}) do
    tools =
      DynamicTool.tool_specs()
      |> Enum.map(fn spec ->
        %{
          "name" => spec["name"],
          "description" => String.trim(spec["description"]),
          "inputSchema" => spec["inputSchema"]
        }
      end)

    respond(id, %{"tools" => tools})
  end

  defp handle_message(%{"method" => "tools/call", "id" => id, "params" => params}) do
    name = Map.get(params, "name", "")
    arguments = Map.get(params, "arguments", %{})

    result = DynamicTool.execute(name, arguments)

    content =
      case result do
        %{"success" => true, "contentItems" => items} ->
          Enum.map(items, fn item ->
            %{"type" => "text", "text" => item["text"] || inspect(item)}
          end)

        %{"success" => false, "contentItems" => items} ->
          Enum.map(items, fn item ->
            %{"type" => "text", "text" => item["text"] || inspect(item)}
          end)

        other ->
          [%{"type" => "text", "text" => inspect(other)}]
      end

    is_error = result["success"] != true

    respond(id, %{"content" => content, "isError" => is_error})
  end

  defp handle_message(%{"method" => "ping", "id" => id}) do
    respond(id, %{})
  end

  defp handle_message(%{"method" => method, "id" => id}) do
    respond_error(id, -32601, "Method not found: #{method}")
  end

  # Notifications (no id) — ignore silently
  defp handle_message(%{"method" => _method}), do: :ok

  defp handle_message(_message), do: :ok

  # ── Response helpers ─────────────────────────────────────────────────

  defp respond(id, result) do
    msg = %{"jsonrpc" => "2.0", "id" => id, "result" => result}
    write_message(msg)
  end

  defp respond_error(id, code, message) do
    msg = %{
      "jsonrpc" => "2.0",
      "id" => id,
      "error" => %{"code" => code, "message" => message}
    }

    write_message(msg)
  end

  defp write_message(msg) do
    line = Jason.encode!(msg)
    IO.write(:stdio, line <> "\n")
  end

  defp configure_stderr_logging do
    Logger.configure_backend(:console, device: :standard_error)
    :ok
  rescue
    _ -> :ok
  end
end
