defmodule Anvil.Schema.Labeler do
  @moduledoc """
  Ecto schema for labelers (annotators).

  Stores labeler profiles, expertise weights, and access control.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "labelers" do
    field(:tenant_id, :binary_id)
    field(:external_id, :string)
    field(:pseudonym, :string)
    field(:expertise_weights, :map)
    field(:blocklisted_queues, {:array, :binary_id}, default: [])
    field(:max_concurrent_assignments, :integer, default: 5)

    has_many(:assignments, Anvil.Schema.Assignment)

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(labeler, attrs) do
    labeler
    |> cast(attrs, [
      :tenant_id,
      :external_id,
      :pseudonym,
      :expertise_weights,
      :blocklisted_queues,
      :max_concurrent_assignments
    ])
    |> validate_required([:external_id])
    |> unique_constraint([:tenant_id, :external_id])
    |> validate_number(:max_concurrent_assignments, greater_than: 0)
  end
end
