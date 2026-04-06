defmodule SymphonyElixir.Config.ClaudeConfig do
  @moduledoc """
  Ecto embedded schema for Claude Code adapter settings in WORKFLOW.md.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key false
  embedded_schema do
    field(:command, :string, default: "claude")
    field(:model, :string)
    field(:permission_mode, :string, default: "bypassPermissions")
    field(:allowed_tools, {:array, :string}, default: [])
    field(:disallowed_tools, {:array, :string}, default: [])
    field(:effort, :string, default: "max")
    field(:api_key, :string)
    field(:system_prompt, :string)
    field(:turn_timeout_ms, :integer, default: 3_600_000)
    field(:stall_timeout_ms, :integer, default: 300_000)
  end

  @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
  def changeset(schema, attrs) do
    schema
    |> cast(
      attrs,
      [
        :command,
        :model,
        :permission_mode,
        :allowed_tools,
        :disallowed_tools,
        :effort,
        :api_key,
        :system_prompt,
        :turn_timeout_ms,
        :stall_timeout_ms
      ],
      empty_values: []
    )
    |> validate_inclusion(:effort, ["low", "medium", "high", "max"])
    |> validate_number(:turn_timeout_ms, greater_than: 0)
    |> validate_number(:stall_timeout_ms, greater_than_or_equal_to: 0)
  end
end
