defmodule Anvil.Schema.MigrationTest do
  # Use async: false to avoid sandbox ownership conflicts
  use ExUnit.Case, async: false

  alias Anvil.Schema.{Migration, SchemaVersion}
  alias Anvil.Repo

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)

    queue_id = Ecto.UUID.generate()

    {:ok, queue_id: queue_id}
  end

  describe "validate_against_schema/2" do
    test "accepts valid payload with all required fields", %{queue_id: queue_id} do
      {:ok, schema_version} =
        Repo.insert(%SchemaVersion{
          queue_id: queue_id,
          version_number: 1,
          schema_definition: %{
            "type" => "object",
            "required" => ["coherence", "grounded"]
          }
        })

      label_values = %{
        "coherence" => true,
        "grounded" => false,
        "notes" => "test"
      }

      assert {:ok, ^label_values} =
               Migration.validate_against_schema(label_values, schema_version)
    end

    test "rejects payload missing required fields", %{queue_id: queue_id} do
      {:ok, schema_version} =
        Repo.insert(%SchemaVersion{
          queue_id: queue_id,
          version_number: 1,
          schema_definition: %{
            "type" => "object",
            "required" => ["coherence", "grounded"]
          }
        })

      label_values = %{
        "coherence" => true
        # missing "grounded"
      }

      assert {:error, errors} = Migration.validate_against_schema(label_values, schema_version)
      assert {:required_fields_missing, ["grounded"]} in errors
    end

    test "accepts payload when no required fields specified", %{queue_id: queue_id} do
      {:ok, schema_version} =
        Repo.insert(%SchemaVersion{
          queue_id: queue_id,
          version_number: 1,
          schema_definition: %{
            "type" => "object",
            "properties" => %{
              "optional_field" => %{"type" => "string"}
            }
          }
        })

      label_values = %{"optional_field" => "value"}

      assert {:ok, ^label_values} =
               Migration.validate_against_schema(label_values, schema_version)
    end
  end

  describe "freeze_schema_version/1" do
    test "freezes unfrozen schema version", %{queue_id: queue_id} do
      {:ok, schema_version} =
        Repo.insert(%SchemaVersion{
          queue_id: queue_id,
          version_number: 1,
          schema_definition: %{}
        })

      assert schema_version.frozen_at == nil

      {:ok, frozen_schema} = Migration.freeze_schema_version(schema_version.id)
      assert frozen_schema.frozen_at != nil
    end

    test "returns ok for already frozen schema version", %{queue_id: queue_id} do
      {:ok, schema_version} =
        Repo.insert(%SchemaVersion{
          queue_id: queue_id,
          version_number: 1,
          schema_definition: %{},
          frozen_at: DateTime.utc_now() |> DateTime.truncate(:second)
        })

      {:ok, frozen_schema} = Migration.freeze_schema_version(schema_version.id)
      assert frozen_schema.frozen_at != nil
    end

    test "returns error for non-existent schema version" do
      non_existent_id = Ecto.UUID.generate()
      assert {:error, :not_found} = Migration.freeze_schema_version(non_existent_id)
    end
  end
end
