defmodule Anvil.Repo.Migrations.CreateLabelers do
  use Ecto.Migration

  def change do
    create table(:labelers, primary_key: false) do
      add(:id, :binary_id, primary_key: true)
      add(:tenant_id, :binary_id)
      add(:external_id, :string, null: false)
      add(:pseudonym, :string)
      add(:expertise_weights, :map)
      add(:blocklisted_queues, {:array, :binary_id}, default: [])
      add(:max_concurrent_assignments, :integer, default: 5, null: false)

      timestamps(type: :utc_datetime)
    end

    create(unique_index(:labelers, [:tenant_id, :external_id]))
    create(index(:labelers, [:external_id]))
  end
end
