defmodule Anvil.Repo.Migrations.CreateSampleRefs do
  use Ecto.Migration

  def change do
    create table(:sample_refs, primary_key: false) do
      add(:id, :binary_id, primary_key: true)
      add(:sample_id, :binary_id, null: false)
      add(:metadata, :map, default: %{})

      timestamps(type: :utc_datetime)
    end

    create(unique_index(:sample_refs, [:sample_id]))
  end
end
