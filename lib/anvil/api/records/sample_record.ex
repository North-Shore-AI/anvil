defmodule Anvil.API.SampleRecord do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :string, autogenerate: false}

  schema "labeling_samples" do
    field(:tenant_id, :string)
    field(:namespace, :string)
    field(:pipeline_id, :string)
    field(:payload, :map, default: %{})
    field(:artifacts, {:array, :map}, default: [])
    field(:metadata, :map, default: %{})
    field(:lineage_ref, :map)
    field(:created_at, :utc_datetime)

    timestamps(type: :utc_datetime)
  end

  def changeset(sample, attrs) do
    sample
    |> cast(attrs, [
      :id,
      :tenant_id,
      :namespace,
      :pipeline_id,
      :payload,
      :artifacts,
      :metadata,
      :lineage_ref,
      :created_at
    ])
    |> validate_required([:id, :tenant_id, :pipeline_id, :payload, :created_at])
  end
end
