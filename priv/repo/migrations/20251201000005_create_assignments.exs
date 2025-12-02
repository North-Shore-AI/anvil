defmodule Anvil.Repo.Migrations.CreateAssignments do
  use Ecto.Migration

  def change do
    create table(:assignments, primary_key: false) do
      add(:id, :binary_id, primary_key: true)
      add(:queue_id, references(:queues, type: :binary_id, on_delete: :delete_all), null: false)
      add(:sample_id, :binary_id, null: false)
      add(:labeler_id, references(:labelers, type: :binary_id, on_delete: :restrict), null: false)
      add(:status, :string, default: "pending", null: false)
      add(:reserved_at, :utc_datetime)
      add(:deadline, :utc_datetime)
      add(:timeout_seconds, :integer)
      add(:version, :integer, default: 1, null: false)
      add(:requeue_attempts, :integer, default: 0, null: false)
      add(:requeue_delay_until, :utc_datetime)
      add(:skip_reason, :string)

      timestamps(type: :utc_datetime)
    end

    create(index(:assignments, [:queue_id, :status]))
    create(index(:assignments, [:labeler_id, :status]))
    create(index(:assignments, [:deadline]))
    create(index(:assignments, [:inserted_at]))
    create(index(:assignments, [:sample_id]))
    create(index(:assignments, [:status]))
  end
end
