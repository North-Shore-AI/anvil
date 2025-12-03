defmodule Anvil.Repo.Migrations.CreateLabelingIrTables do
  use Ecto.Migration

  def change do
    create table(:labeling_schemas, primary_key: false) do
      add(:id, :string, primary_key: true)
      add(:tenant_id, :string, null: false)
      add(:namespace, :string)
      add(:fields, {:array, :map}, null: false, default: [])
      add(:layout, :map)
      add(:component_module, :string)
      add(:metadata, :map, null: false, default: %{})

      timestamps(type: :utc_datetime)
    end

    create(index(:labeling_schemas, [:tenant_id]))

    create table(:labeling_queues, primary_key: false) do
      add(:id, :string, primary_key: true)
      add(:tenant_id, :string, null: false)

      add(
        :schema_id,
        references(:labeling_schemas, column: :id, type: :string, on_delete: :delete_all),
        null: false
      )

      add(:namespace, :string)
      add(:component_module, :string)
      add(:metadata, :map, null: false, default: %{})

      timestamps(type: :utc_datetime)
    end

    create(index(:labeling_queues, [:tenant_id]))
    create(index(:labeling_queues, [:schema_id]))

    create table(:labeling_samples, primary_key: false) do
      add(:id, :string, primary_key: true)
      add(:tenant_id, :string, null: false)
      add(:namespace, :string)
      add(:pipeline_id, :string)
      add(:payload, :map, null: false, default: %{})
      add(:artifacts, {:array, :map}, null: false, default: [])
      add(:metadata, :map, null: false, default: %{})
      add(:lineage_ref, :map)
      add(:created_at, :utc_datetime, null: false)

      timestamps(type: :utc_datetime)
    end

    create(index(:labeling_samples, [:tenant_id]))
    create(index(:labeling_samples, [:pipeline_id]))

    create table(:labeling_assignments, primary_key: false) do
      add(:id, :string, primary_key: true)

      add(
        :queue_id,
        references(:labeling_queues, column: :id, type: :string, on_delete: :delete_all),
        null: false
      )

      add(
        :schema_id,
        references(:labeling_schemas, column: :id, type: :string, on_delete: :delete_all),
        null: false
      )

      add(
        :sample_id,
        references(:labeling_samples, column: :id, type: :string, on_delete: :delete_all),
        null: false
      )

      add(:tenant_id, :string, null: false)
      add(:namespace, :string)
      add(:expires_at, :utc_datetime)
      add(:metadata, :map, null: false, default: %{})

      timestamps(type: :utc_datetime)
    end

    create(index(:labeling_assignments, [:queue_id]))
    create(index(:labeling_assignments, [:sample_id]))
    create(index(:labeling_assignments, [:tenant_id]))

    create table(:labeling_labels, primary_key: false) do
      add(:id, :string, primary_key: true)

      add(
        :assignment_id,
        references(:labeling_assignments, column: :id, type: :string, on_delete: :delete_all),
        null: false
      )

      add(
        :queue_id,
        references(:labeling_queues, column: :id, type: :string, on_delete: :delete_all),
        null: false
      )

      add(
        :sample_id,
        references(:labeling_samples, column: :id, type: :string, on_delete: :delete_all),
        null: false
      )

      add(:tenant_id, :string, null: false)
      add(:namespace, :string)
      add(:user_id, :string, null: false)
      add(:values, :map, null: false)
      add(:notes, :text)
      add(:time_spent_ms, :integer)
      add(:lineage_ref, :map)
      add(:metadata, :map, null: false, default: %{})
      add(:created_at, :utc_datetime, null: false)

      timestamps(type: :utc_datetime)
    end

    create(index(:labeling_labels, [:assignment_id]))
    create(index(:labeling_labels, [:queue_id]))
    create(index(:labeling_labels, [:sample_id]))
    create(index(:labeling_labels, [:tenant_id]))

    create table(:labeling_datasets, primary_key: false) do
      add(:id, :string, primary_key: true)
      add(:tenant_id, :string, null: false)
      add(:namespace, :string)
      add(:version, :string, null: false)
      add(:slices, {:array, :map}, null: false, default: [])
      add(:source_refs, {:array, :map}, null: false, default: [])
      add(:metadata, :map, null: false, default: %{})
      add(:lineage_ref, :map)
      add(:created_at, :utc_datetime, null: false)

      timestamps(type: :utc_datetime)
    end

    create(index(:labeling_datasets, [:tenant_id]))
    create(index(:labeling_datasets, [:version]))
  end
end
