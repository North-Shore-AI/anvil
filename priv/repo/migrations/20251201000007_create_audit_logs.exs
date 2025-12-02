defmodule Anvil.Repo.Migrations.CreateAuditLogs do
  use Ecto.Migration

  def change do
    create table(:audit_logs, primary_key: false) do
      add(:id, :binary_id, primary_key: true)
      add(:tenant_id, :binary_id)
      add(:entity_type, :string, null: false)
      add(:entity_id, :binary_id, null: false)
      add(:action, :string, null: false)
      add(:actor_id, :binary_id)
      add(:metadata, :map, default: %{})
      add(:occurred_at, :utc_datetime, null: false)

      timestamps(type: :utc_datetime, updated_at: false)
    end

    create(index(:audit_logs, [:entity_type, :entity_id]))
    create(index(:audit_logs, [:occurred_at]))
    create(index(:audit_logs, [:tenant_id]))
  end
end
