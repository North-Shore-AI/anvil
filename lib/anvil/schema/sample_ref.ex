defmodule Anvil.Schema.SampleRef do
  @moduledoc """
  Ecto schema for sample references.

  Stores references to samples managed by Forge, supporting either
  foreign key constraints (Option A) or logical references (Option B).
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "sample_refs" do
    field(:sample_id, :binary_id)
    field(:metadata, :map, default: %{})

    has_many(:assignments, Anvil.Schema.Assignment, foreign_key: :sample_id)

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(sample_ref, attrs) do
    sample_ref
    |> cast(attrs, [:sample_id, :metadata])
    |> validate_required([:sample_id])
    |> unique_constraint(:sample_id)
  end
end
