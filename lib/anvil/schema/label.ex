defmodule Anvil.Schema.Label do
  @moduledoc """
  Ecto schema for submitted labels.

  Stores label data validated against schema versions with optional
  blob storage for large attachments.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "labels" do
    field(:payload, :map)
    field(:blob_pointer, :string)
    field(:submitted_at, :utc_datetime)

    belongs_to(:assignment, Anvil.Schema.Assignment)
    belongs_to(:labeler, Anvil.Schema.Labeler)
    belongs_to(:schema_version, Anvil.Schema.SchemaVersion)

    timestamps(type: :utc_datetime, updated_at: false)
  end

  @type t :: %__MODULE__{
          id: Ecto.UUID.t() | nil,
          payload: map(),
          blob_pointer: String.t() | nil,
          submitted_at: DateTime.t() | nil,
          assignment_id: Ecto.UUID.t() | nil,
          labeler_id: Ecto.UUID.t() | nil,
          schema_version_id: Ecto.UUID.t() | nil,
          assignment: %Anvil.Schema.Assignment{} | Ecto.Association.NotLoaded.t() | nil,
          labeler: %Anvil.Schema.Labeler{} | Ecto.Association.NotLoaded.t() | nil,
          schema_version: %Anvil.Schema.SchemaVersion{} | Ecto.Association.NotLoaded.t() | nil,
          inserted_at: DateTime.t() | nil
        }

  @doc false
  def changeset(label, attrs) do
    label
    |> cast(attrs, [
      :id,
      :assignment_id,
      :labeler_id,
      :schema_version_id,
      :payload,
      :blob_pointer,
      :submitted_at
    ])
    |> validate_required([:assignment_id, :labeler_id, :schema_version_id, :payload])
    |> foreign_key_constraint(:assignment_id)
    |> foreign_key_constraint(:labeler_id)
    |> foreign_key_constraint(:schema_version_id)
    |> unique_constraint([:assignment_id, :labeler_id])
  end
end
