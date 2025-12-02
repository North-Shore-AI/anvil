defmodule Anvil.Schema.SchemaVersion do
  @moduledoc """
  Ecto schema for label schema versions.

  Tracks evolution of label schemas with immutability guarantees.
  Once a schema version is frozen (first label written), it becomes read-only.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @type t :: %__MODULE__{
          id: Ecto.UUID.t(),
          queue_id: Ecto.UUID.t(),
          version_number: integer(),
          schema_definition: map(),
          transform_from_previous: String.t() | nil,
          frozen_at: DateTime.t() | nil,
          label_count: integer(),
          inserted_at: DateTime.t()
        }

  schema "schema_versions" do
    field(:queue_id, :binary_id)
    field(:version_number, :integer)
    field(:schema_definition, :map)
    field(:transform_from_previous, :string)
    field(:frozen_at, :utc_datetime)
    field(:label_count, :integer, default: 0, virtual: true)

    timestamps(type: :utc_datetime, updated_at: false)
  end

  @doc false
  def changeset(schema_version, attrs) do
    schema_version
    |> cast(attrs, [:queue_id, :version_number, :schema_definition, :transform_from_previous])
    |> validate_required([:queue_id, :version_number, :schema_definition])
    |> unique_constraint([:queue_id, :version_number])
    |> validate_number(:version_number, greater_than: 0)
  end

  @doc """
  Checks if schema version can be modified.

  A schema version is mutable if:
  - It has not been frozen (frozen_at is nil)
  - It has no labels (label_count is 0)
  """
  @spec mutable?(t()) :: boolean()
  def mutable?(%__MODULE__{frozen_at: nil, label_count: 0}), do: true
  def mutable?(_), do: false

  @doc """
  Freezes a schema version, making it immutable.
  """
  def freeze(schema_version) do
    if schema_version.frozen_at do
      schema_version
      |> change()
      |> add_error(:frozen_at, "schema is already frozen")
    else
      schema_version
      |> change(%{frozen_at: DateTime.utc_now() |> DateTime.truncate(:second)})
    end
  end
end
