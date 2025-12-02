defmodule Anvil.Schema.Queue do
  @moduledoc """
  Ecto schema for labeling queues.

  Stores queue configuration including policy settings and schema version.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{
          id: Ecto.UUID.t() | nil,
          tenant_id: Ecto.UUID.t() | nil,
          name: String.t() | nil,
          policy: map() | nil,
          status: :active | :paused | :archived,
          schema_version_id: Ecto.UUID.t() | nil,
          schema_version: Anvil.Schema.SchemaVersion.t() | Ecto.Association.NotLoaded.t() | nil,
          assignments: [Anvil.Schema.Assignment.t()] | Ecto.Association.NotLoaded.t(),
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "queues" do
    field(:tenant_id, :binary_id)
    field(:name, :string)
    field(:policy, :map)
    field(:status, Ecto.Enum, values: [:active, :paused, :archived], default: :active)

    belongs_to(:schema_version, Anvil.Schema.SchemaVersion)
    has_many(:assignments, Anvil.Schema.Assignment)

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(queue, attrs) do
    queue
    |> cast(attrs, [:tenant_id, :name, :schema_version_id, :policy, :status])
    |> validate_required([:name, :schema_version_id, :policy])
    |> unique_constraint([:tenant_id, :name])
  end
end
