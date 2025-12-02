defmodule Anvil.Repo.Migrations.CreateQueues do
  use Ecto.Migration

  def change do
    create table(:queues, primary_key: false) do
      add(:id, :binary_id, primary_key: true)
      add(:tenant_id, :binary_id)
      add(:name, :string, null: false)

      add(
        :schema_version_id,
        references(:schema_versions, type: :binary_id, on_delete: :restrict),
        null: false
      )

      add(:policy, :map, null: false)
      add(:status, :string, default: "active", null: false)

      timestamps(type: :utc_datetime)
    end

    create(unique_index(:queues, [:tenant_id, :name]))
    create(index(:queues, [:name]))
    create(index(:queues, [:status]))
    create(index(:queues, [:schema_version_id]))
  end
end
