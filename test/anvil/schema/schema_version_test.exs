defmodule Anvil.Schema.SchemaVersionTest do
  use Supertester.ExUnitFoundation, isolation: :full_isolation

  alias Anvil.Schema.SchemaVersion
  alias Anvil.Repo

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})

    queue_id = Ecto.UUID.generate()

    {:ok, queue_id: queue_id}
  end

  describe "mutable?/1" do
    test "returns true for unfrozen schema with no labels" do
      schema_version = %SchemaVersion{
        frozen_at: nil,
        label_count: 0
      }

      assert SchemaVersion.mutable?(schema_version)
    end

    test "returns false for frozen schema" do
      schema_version = %SchemaVersion{
        frozen_at: DateTime.utc_now() |> DateTime.truncate(:second),
        label_count: 0
      }

      refute SchemaVersion.mutable?(schema_version)
    end

    test "returns false for schema with labels" do
      schema_version = %SchemaVersion{
        frozen_at: nil,
        label_count: 1
      }

      refute SchemaVersion.mutable?(schema_version)
    end

    test "returns false for frozen schema with labels" do
      schema_version = %SchemaVersion{
        frozen_at: DateTime.utc_now() |> DateTime.truncate(:second),
        label_count: 5
      }

      refute SchemaVersion.mutable?(schema_version)
    end
  end

  describe "freeze/1" do
    test "freezes an unfrozen schema version", %{queue_id: queue_id} do
      {:ok, schema_version} =
        Repo.insert(%SchemaVersion{
          queue_id: queue_id,
          version_number: 1,
          schema_definition: %{"type" => "object"}
        })

      assert schema_version.frozen_at == nil

      changeset = SchemaVersion.freeze(schema_version)
      assert changeset.valid?

      {:ok, frozen_schema} = Repo.update(changeset)
      assert frozen_schema.frozen_at != nil
    end

    test "returns error when trying to freeze already frozen schema", %{queue_id: queue_id} do
      {:ok, schema_version} =
        Repo.insert(%SchemaVersion{
          queue_id: queue_id,
          version_number: 1,
          schema_definition: %{"type" => "object"},
          frozen_at: DateTime.utc_now() |> DateTime.truncate(:second)
        })

      changeset = SchemaVersion.freeze(schema_version)
      refute changeset.valid?
      assert changeset.errors[:frozen_at]
    end
  end

  describe "changeset/2" do
    test "validates required fields" do
      changeset = SchemaVersion.changeset(%SchemaVersion{}, %{})

      refute changeset.valid?
      assert changeset.errors[:queue_id]
      assert changeset.errors[:version_number]
      assert changeset.errors[:schema_definition]
    end

    test "validates version_number is greater than 0" do
      changeset =
        SchemaVersion.changeset(%SchemaVersion{}, %{
          queue_id: Ecto.UUID.generate(),
          version_number: 0,
          schema_definition: %{}
        })

      refute changeset.valid?
      assert changeset.errors[:version_number]
    end

    test "accepts valid attributes", %{queue_id: queue_id} do
      changeset =
        SchemaVersion.changeset(%SchemaVersion{}, %{
          queue_id: queue_id,
          version_number: 1,
          schema_definition: %{
            "type" => "object",
            "properties" => %{
              "coherence" => %{"type" => "boolean"}
            }
          }
        })

      assert changeset.valid?
    end
  end
end
