defmodule Anvil.API.SchemaRecord do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :string, autogenerate: false}

  schema "labeling_schemas" do
    field(:tenant_id, :string)
    field(:namespace, :string)
    field(:fields, {:array, :map}, default: [])
    field(:layout, :map)
    field(:component_module, :string)
    field(:metadata, :map, default: %{})

    timestamps(type: :utc_datetime)
  end

  def changeset(schema, attrs) do
    schema
    |> cast(attrs, [:id, :tenant_id, :namespace, :fields, :layout, :component_module, :metadata])
    |> validate_required([:id, :tenant_id, :fields])
  end
end
