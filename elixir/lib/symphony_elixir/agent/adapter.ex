defmodule SymphonyElixir.Agent.Adapter do
  @moduledoc """
  Factory that maps agent-type strings from WORKFLOW.md to adapter modules.
  """

  @adapters %{
    "codex" => SymphonyElixir.Agent.CodexAdapter,
    "claude" => SymphonyElixir.Agent.ClaudeAdapter
  }

  @spec create(String.t()) :: module()
  def create(agent_type) when is_binary(agent_type) do
    case Map.fetch(@adapters, agent_type) do
      {:ok, adapter} ->
        adapter

      :error ->
        raise ArgumentError,
              "Unknown agent type: #{inspect(agent_type)}. Supported: #{inspect(Map.keys(@adapters))}"
    end
  end

  @spec supported_types() :: [String.t()]
  def supported_types, do: Map.keys(@adapters)
end
