defmodule Anvil.API.LabelRecord do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :string, autogenerate: false}

  schema "labeling_labels" do
    field(:assignment_id, :string)
    field(:queue_id, :string)
    field(:sample_id, :string)
    field(:tenant_id, :string)
    field(:namespace, :string)
    field(:user_id, :string)
    field(:values, :map, default: %{})
    field(:notes, :string)
    field(:time_spent_ms, :integer)
    field(:lineage_ref, :map)
    field(:metadata, :map, default: %{})
    field(:created_at, :utc_datetime)

    timestamps(type: :utc_datetime)
  end

  def changeset(label, attrs) do
    label
    |> cast(attrs, [
      :id,
      :assignment_id,
      :queue_id,
      :sample_id,
      :tenant_id,
      :namespace,
      :user_id,
      :values,
      :notes,
      :time_spent_ms,
      :lineage_ref,
      :metadata,
      :created_at
    ])
    |> validate_required([
      :id,
      :assignment_id,
      :queue_id,
      :sample_id,
      :tenant_id,
      :user_id,
      :values,
      :time_spent_ms,
      :created_at
    ])
  end
end
