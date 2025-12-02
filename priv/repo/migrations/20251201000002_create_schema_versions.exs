defmodule Anvil.Repo.Migrations.CreateSchemaVersions do
  use Ecto.Migration

  def change do
    create table(:schema_versions, primary_key: false) do
      add(:id, :binary_id, primary_key: true)
      add(:queue_id, :binary_id, null: false)
      add(:version_number, :integer, null: false)
      add(:schema_definition, :map, null: false)
      add(:transform_from_previous, :string)
      add(:frozen_at, :utc_datetime)

      timestamps(type: :utc_datetime, updated_at: false)
    end

    create(unique_index(:schema_versions, [:queue_id, :version_number]))
    create(index(:schema_versions, [:queue_id]))
  end
end
