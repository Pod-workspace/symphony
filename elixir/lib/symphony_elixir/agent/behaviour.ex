defmodule SymphonyElixir.Agent.Behaviour do
  @moduledoc """
  Common contract for coding-agent adapters (Codex, Claude Code, etc.).
  """

  @type session :: map()

  @callback start_session(workspace :: Path.t(), opts :: keyword()) ::
              {:ok, session()} | {:error, term()}

  @callback run_turn(
              session :: session(),
              prompt :: String.t(),
              issue :: map(),
              opts :: keyword()
            ) :: {:ok, map()} | {:error, term()}

  @callback stop_session(session :: session()) :: :ok
end
