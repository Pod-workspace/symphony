defmodule SymphonyElixir.Agent.CodexAdapter do
  @moduledoc """
  Adapter that delegates to the existing Codex AppServer.
  """

  @behaviour SymphonyElixir.Agent.Behaviour

  alias SymphonyElixir.Codex.AppServer

  @impl true
  def start_session(workspace, _opts \\ []) do
    AppServer.start_session(workspace)
  end

  @impl true
  def run_turn(session, prompt, issue, opts \\ []) do
    AppServer.run_turn(session, prompt, issue, opts)
  end

  @impl true
  def stop_session(session) do
    AppServer.stop_session(session)
  end
end
