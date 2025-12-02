defmodule Anvil.Repo.Migrations.CreateLabels do
  use Ecto.Migration

  def change do
    create table(:labels, primary_key: false) do
      add(:id, :binary_id, primary_key: true)

      add(:assignment_id, references(:assignments, type: :binary_id, on_delete: :delete_all),
        null: false
      )

      add(:labeler_id, references(:labelers, type: :binary_id, on_delete: :restrict), null: false)

      add(
        :schema_version_id,
        references(:schema_versions, type: :binary_id, on_delete: :restrict),
        null: false
      )

      add(:payload, :map, null: false)
      add(:blob_pointer, :string)
      add(:submitted_at, :utc_datetime)

      timestamps(type: :utc_datetime, updated_at: false)
    end

    create(index(:labels, [:assignment_id]))
    create(index(:labels, [:labeler_id]))
    create(index(:labels, [:schema_version_id]))
    create(unique_index(:labels, [:assignment_id, :labeler_id]))
  end
end
