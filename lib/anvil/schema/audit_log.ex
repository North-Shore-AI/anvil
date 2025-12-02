defmodule Anvil.Schema.AuditLog do
  @moduledoc """
  Ecto schema for audit trail.

  Provides immutable record of all operations for compliance and debugging.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "audit_logs" do
    field(:tenant_id, :binary_id)

    field(:entity_type, Ecto.Enum,
      values: [:queue, :assignment, :label, :labeler, :schema_version]
    )

    field(:entity_id, :binary_id)
    field(:action, Ecto.Enum, values: [:created, :updated, :deleted, :accessed])

    field(:actor_id, :binary_id)
    field(:metadata, :map, default: %{})
    field(:occurred_at, :utc_datetime)

    timestamps(type: :utc_datetime, updated_at: false)
  end

  @doc false
  def changeset(audit_log, attrs) do
    audit_log
    |> cast(attrs, [
      :tenant_id,
      :entity_type,
      :entity_id,
      :action,
      :actor_id,
      :metadata,
      :occurred_at
    ])
    |> validate_required([:entity_type, :entity_id, :action])
    |> put_change(:occurred_at, DateTime.utc_now())
  end
end
