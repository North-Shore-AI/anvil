defmodule Anvil.API.QueueRecord do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :string, autogenerate: false}

  schema "labeling_queues" do
    field(:tenant_id, :string)
    field(:schema_id, :string)
    field(:namespace, :string)
    field(:component_module, :string)
    field(:metadata, :map, default: %{})

    timestamps(type: :utc_datetime)
  end

  def changeset(queue, attrs) do
    queue
    |> cast(attrs, [:id, :tenant_id, :schema_id, :namespace, :component_module, :metadata])
    |> validate_required([:id, :tenant_id, :schema_id, :component_module])
  end
end
