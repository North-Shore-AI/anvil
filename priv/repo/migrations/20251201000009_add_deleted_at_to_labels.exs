defmodule Anvil.Repo.Migrations.AddDeletedAtToLabels do
  use Ecto.Migration

  def change do
    alter table(:labels) do
      add(:deleted_at, :utc_datetime)
    end

    create(index(:labels, [:deleted_at]))
  end
end
