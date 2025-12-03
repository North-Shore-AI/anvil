defmodule Anvil.API.DatasetRecord do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :string, autogenerate: false}

  schema "labeling_datasets" do
    field(:tenant_id, :string)
    field(:namespace, :string)
    field(:version, :string)
    field(:slices, {:array, :map}, default: [])
    field(:source_refs, {:array, :map}, default: [])
    field(:metadata, :map, default: %{})
    field(:lineage_ref, :map)
    field(:created_at, :utc_datetime)

    timestamps(type: :utc_datetime)
  end

  def changeset(dataset, attrs) do
    dataset
    |> cast(attrs, [
      :id,
      :tenant_id,
      :namespace,
      :version,
      :slices,
      :source_refs,
      :metadata,
      :lineage_ref,
      :created_at
    ])
    |> validate_required([:id, :tenant_id, :version, :created_at])
  end
end
