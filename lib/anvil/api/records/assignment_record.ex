defmodule Anvil.API.AssignmentRecord do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :string, autogenerate: false}

  schema "labeling_assignments" do
    field(:queue_id, :string)
    field(:schema_id, :string)
    field(:sample_id, :string)
    field(:tenant_id, :string)
    field(:namespace, :string)
    field(:expires_at, :utc_datetime)
    field(:metadata, :map, default: %{})

    timestamps(type: :utc_datetime)
  end

  def changeset(assignment, attrs) do
    assignment
    |> cast(attrs, [
      :id,
      :queue_id,
      :schema_id,
      :sample_id,
      :tenant_id,
      :namespace,
      :expires_at,
      :metadata
    ])
    |> validate_required([:id, :queue_id, :schema_id, :sample_id, :tenant_id])
  end
end
