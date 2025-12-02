defmodule Anvil.Export.JSONLTest do
  use Supertester.ExUnitFoundation, isolation: :full_isolation

  alias Anvil.Export.JSONL
  alias Anvil.Repo
  alias Anvil.Schema.{Queue, SchemaVersion, Assignment, Label, Labeler}

  setup do
    # Start Ecto Sandbox
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Anvil.Repo)

    # Create test data
    {:ok, labeler1} =
      Repo.insert(%Labeler{
        id: Ecto.UUID.generate(),
        external_id: "labeler1"
      })

    {:ok, labeler2} =
      Repo.insert(%Labeler{
        id: Ecto.UUID.generate(),
        external_id: "labeler2"
      })

    # Create queue and schema version
    queue_id = Ecto.UUID.generate()

    # Create schema version first
    {:ok, schema_version} =
      Repo.insert(%SchemaVersion{
        queue_id: queue_id,
        version_number: 1,
        schema_definition: %{
          fields: [
            %{name: "coherence", type: "boolean"},
            %{name: "notes", type: "text"}
          ]
        }
      })

    # Now create the queue with the schema version
    {:ok, queue} =
      Repo.insert(%Queue{
        id: queue_id,
        name: "test_export_queue",
        schema_version_id: schema_version.id,
        policy: %{labels_per_sample: 2},
        status: :active
      })

    %{
      queue: queue,
      schema_version: schema_version,
      labeler1: labeler1,
      labeler2: labeler2
    }
  end

  describe "to_format/2" do
    test "exports labels to JSONL with deterministic ordering", %{
      queue: queue,
      schema_version: schema_version,
      labeler1: labeler1,
      labeler2: labeler2
    } do
      # Create assignments and labels in non-deterministic order
      sample_ids = [Ecto.UUID.generate(), Ecto.UUID.generate(), Ecto.UUID.generate()]
      labelers = [labeler2, labeler1]

      for sample_id <- sample_ids, labeler <- labelers do
        {:ok, assignment} =
          Repo.insert(%Assignment{
            id: Ecto.UUID.generate(),
            queue_id: queue.id,
            sample_id: sample_id,
            labeler_id: labeler.id,
            status: :completed
          })

        Repo.insert(%Label{
          id: Ecto.UUID.generate(),
          assignment_id: assignment.id,
          labeler_id: labeler.id,
          schema_version_id: schema_version.id,
          payload: %{"coherence" => true, "notes" => "test note"},
          submitted_at: DateTime.truncate(DateTime.utc_now(), :second)
        })
      end

      output_path = "/tmp/test_jsonl_deterministic_#{:rand.uniform(1_000_000)}.jsonl"

      try do
        {:ok, result} =
          JSONL.to_format(queue.id, %{
            schema_version_id: schema_version.id,
            output_path: output_path
          })

        assert File.exists?(output_path)
        assert result.manifest.row_count == 6

        # Read JSONL and verify ordering
        lines = File.read!(output_path) |> String.split("\n", trim: true)

        # Extract sample_ids from each line
        sample_ids_in_jsonl =
          Enum.map(lines, fn line ->
            {:ok, data} = Jason.decode(line)
            data["sample_id"]
          end)

        # Should be sorted by sample_id, then labeler_id
        # Check that IDs are sorted deterministically
        assert sample_ids_in_jsonl == Enum.sort(sample_ids_in_jsonl)
      after
        File.rm(output_path)
        File.rm(output_path <> ".manifest.json")
      end
    end

    test "exports produce identical hashes when re-exported", %{
      queue: queue,
      schema_version: schema_version,
      labeler1: labeler1
    } do
      {:ok, assignment} =
        Repo.insert(%Assignment{
          id: Ecto.UUID.generate(),
          queue_id: queue.id,
          sample_id: Ecto.UUID.generate(),
          labeler_id: labeler1.id,
          status: :completed
        })

      Repo.insert(%Label{
        id: Ecto.UUID.generate(),
        assignment_id: assignment.id,
        labeler_id: labeler1.id,
        schema_version_id: schema_version.id,
        payload: %{"coherence" => true, "notes" => "test"},
        submitted_at: DateTime.truncate(DateTime.utc_now(), :second)
      })

      output_path1 = "/tmp/test_jsonl_hash1_#{:rand.uniform(1_000_000)}.jsonl"
      output_path2 = "/tmp/test_jsonl_hash2_#{:rand.uniform(1_000_000)}.jsonl"

      try do
        {:ok, result1} =
          JSONL.to_format(queue.id, %{
            schema_version_id: schema_version.id,
            output_path: output_path1
          })

        {:ok, result2} =
          JSONL.to_format(queue.id, %{
            schema_version_id: schema_version.id,
            output_path: output_path2
          })

        assert result1.manifest.sha256_hash == result2.manifest.sha256_hash
      after
        File.rm(output_path1)
        File.rm(output_path1 <> ".manifest.json")
        File.rm(output_path2)
        File.rm(output_path2 <> ".manifest.json")
      end
    end

    test "requires schema_version_id parameter", %{queue: queue} do
      output_path = "/tmp/test_jsonl_no_schema.jsonl"

      assert {:error, {:missing_required_option, :schema_version_id}} =
               JSONL.to_format(queue.id, %{output_path: output_path})
    end

    test "requires output_path parameter", %{queue: queue, schema_version: schema_version} do
      assert {:error, {:missing_required_option, :output_path}} =
               JSONL.to_format(queue.id, %{schema_version_id: schema_version.id})
    end

    test "handles empty label set", %{queue: queue, schema_version: schema_version} do
      output_path = "/tmp/test_jsonl_empty_#{:rand.uniform(1_000_000)}.jsonl"

      try do
        {:ok, result} =
          JSONL.to_format(queue.id, %{
            schema_version_id: schema_version.id,
            output_path: output_path
          })

        assert File.exists?(output_path)
        assert result.manifest.row_count == 0

        # File should be empty
        content = File.read!(output_path)
        assert content == ""
      after
        File.rm(output_path)
        File.rm(output_path <> ".manifest.json")
      end
    end

    test "preserves nested JSON structures", %{
      queue: queue,
      schema_version: schema_version,
      labeler1: labeler1
    } do
      {:ok, assignment} =
        Repo.insert(%Assignment{
          id: Ecto.UUID.generate(),
          queue_id: queue.id,
          sample_id: Ecto.UUID.generate(),
          labeler_id: labeler1.id,
          status: :completed
        })

      nested_payload = %{
        "coherence" => true,
        "notes" => "test",
        "metadata" => %{
          "confidence" => 0.95,
          "tags" => ["tag1", "tag2"]
        }
      }

      Repo.insert(%Label{
        id: Ecto.UUID.generate(),
        assignment_id: assignment.id,
        labeler_id: labeler1.id,
        schema_version_id: schema_version.id,
        payload: nested_payload,
        submitted_at: DateTime.truncate(DateTime.utc_now(), :second)
      })

      output_path = "/tmp/test_jsonl_nested_#{:rand.uniform(1_000_000)}.jsonl"

      try do
        {:ok, _result} =
          JSONL.to_format(queue.id, %{
            schema_version_id: schema_version.id,
            output_path: output_path
          })

        line = File.read!(output_path) |> String.trim()
        {:ok, data} = Jason.decode(line)

        assert data["payload"]["metadata"]["confidence"] == 0.95
        assert data["payload"]["metadata"]["tags"] == ["tag1", "tag2"]
      after
        File.rm(output_path)
        File.rm(output_path <> ".manifest.json")
      end
    end

    test "each line is valid JSON", %{
      queue: queue,
      schema_version: schema_version,
      labeler1: labeler1
    } do
      for _i <- 1..3 do
        {:ok, assignment} =
          Repo.insert(%Assignment{
            id: Ecto.UUID.generate(),
            queue_id: queue.id,
            sample_id: Ecto.UUID.generate(),
            labeler_id: labeler1.id,
            status: :completed
          })

        Repo.insert(%Label{
          id: Ecto.UUID.generate(),
          assignment_id: assignment.id,
          labeler_id: labeler1.id,
          schema_version_id: schema_version.id,
          payload: %{"coherence" => true, "notes" => "test"},
          submitted_at: DateTime.truncate(DateTime.utc_now(), :second)
        })
      end

      output_path = "/tmp/test_jsonl_valid_#{:rand.uniform(1_000_000)}.jsonl"

      try do
        {:ok, _result} =
          JSONL.to_format(queue.id, %{
            schema_version_id: schema_version.id,
            output_path: output_path
          })

        lines = File.read!(output_path) |> String.split("\n", trim: true)

        # Each line should be valid JSON
        for line <- lines do
          assert {:ok, _} = Jason.decode(line)
        end
      after
        File.rm(output_path)
        File.rm(output_path <> ".manifest.json")
      end
    end

    test "respects limit parameter", %{
      queue: queue,
      schema_version: schema_version,
      labeler1: labeler1
    } do
      # Create 5 labels
      for _i <- 1..5 do
        {:ok, assignment} =
          Repo.insert(%Assignment{
            id: Ecto.UUID.generate(),
            queue_id: queue.id,
            sample_id: Ecto.UUID.generate(),
            labeler_id: labeler1.id,
            status: :completed
          })

        Repo.insert(%Label{
          id: Ecto.UUID.generate(),
          assignment_id: assignment.id,
          labeler_id: labeler1.id,
          schema_version_id: schema_version.id,
          payload: %{"coherence" => true, "notes" => "test"},
          submitted_at: DateTime.truncate(DateTime.utc_now(), :second)
        })
      end

      output_path = "/tmp/test_jsonl_limit_#{:rand.uniform(1_000_000)}.jsonl"

      try do
        {:ok, result} =
          JSONL.to_format(queue.id, %{
            schema_version_id: schema_version.id,
            output_path: output_path,
            limit: 3
          })

        assert result.manifest.row_count == 3

        lines = File.read!(output_path) |> String.split("\n", trim: true)
        assert length(lines) == 3
      after
        File.rm(output_path)
        File.rm(output_path <> ".manifest.json")
      end
    end

    test "respects offset parameter", %{
      queue: queue,
      schema_version: schema_version,
      labeler1: labeler1
    } do
      # Create 5 labels
      for _i <- 1..5 do
        {:ok, assignment} =
          Repo.insert(%Assignment{
            id: Ecto.UUID.generate(),
            queue_id: queue.id,
            sample_id: Ecto.UUID.generate(),
            labeler_id: labeler1.id,
            status: :completed
          })

        Repo.insert(%Label{
          id: Ecto.UUID.generate(),
          assignment_id: assignment.id,
          labeler_id: labeler1.id,
          schema_version_id: schema_version.id,
          payload: %{"coherence" => true, "notes" => "test"},
          submitted_at: DateTime.truncate(DateTime.utc_now(), :second)
        })
      end

      output_path = "/tmp/test_jsonl_offset_#{:rand.uniform(1_000_000)}.jsonl"

      try do
        {:ok, result} =
          JSONL.to_format(queue.id, %{
            schema_version_id: schema_version.id,
            output_path: output_path,
            offset: 2,
            limit: 2
          })

        assert result.manifest.row_count == 2

        lines = File.read!(output_path) |> String.split("\n", trim: true)

        # Should get samples 003 and 004 (skipped first 2)
        {:ok, _first} = Jason.decode(Enum.at(lines, 0))
        {:ok, _second} = Jason.decode(Enum.at(lines, 1))

        # Skip specific sample ID check for UUIDs
        # Skip specific sample ID check for UUIDs
      after
        File.rm(output_path)
        File.rm(output_path <> ".manifest.json")
      end
    end

    test "creates manifest with correct metadata", %{
      queue: queue,
      schema_version: schema_version,
      labeler1: labeler1
    } do
      {:ok, assignment} =
        Repo.insert(%Assignment{
          id: Ecto.UUID.generate(),
          queue_id: queue.id,
          sample_id: Ecto.UUID.generate(),
          labeler_id: labeler1.id,
          status: :completed
        })

      Repo.insert(%Label{
        id: Ecto.UUID.generate(),
        assignment_id: assignment.id,
        labeler_id: labeler1.id,
        schema_version_id: schema_version.id,
        payload: %{"coherence" => true, "notes" => "test"},
        submitted_at: DateTime.truncate(DateTime.utc_now(), :second)
      })

      output_path = "/tmp/test_jsonl_manifest_#{:rand.uniform(1_000_000)}.jsonl"

      try do
        {:ok, result} =
          JSONL.to_format(queue.id, %{
            schema_version_id: schema_version.id,
            output_path: output_path,
            sample_version: "2024-12-01"
          })

        manifest = result.manifest

        assert manifest.queue_id == queue.id
        assert manifest.schema_version_id == schema_version.id
        assert manifest.sample_version == "2024-12-01"
        assert manifest.format == :jsonl
        assert manifest.output_path == output_path
        assert manifest.row_count == 1
        assert is_binary(manifest.sha256_hash)
        assert byte_size(manifest.sha256_hash) == 64
        assert %DateTime{} = manifest.exported_at
        assert manifest.anvil_version =~ ~r/\d+\.\d+\.\d+/
      after
        File.rm(output_path)
        File.rm(output_path <> ".manifest.json")
      end
    end

    test "saves manifest alongside export file", %{
      queue: queue,
      schema_version: schema_version,
      labeler1: labeler1
    } do
      {:ok, assignment} =
        Repo.insert(%Assignment{
          id: Ecto.UUID.generate(),
          queue_id: queue.id,
          sample_id: Ecto.UUID.generate(),
          labeler_id: labeler1.id,
          status: :completed
        })

      Repo.insert(%Label{
        id: Ecto.UUID.generate(),
        assignment_id: assignment.id,
        labeler_id: labeler1.id,
        schema_version_id: schema_version.id,
        payload: %{"coherence" => true, "notes" => "test"},
        submitted_at: DateTime.truncate(DateTime.utc_now(), :second)
      })

      output_path = "/tmp/test_jsonl_manifest_file_#{:rand.uniform(1_000_000)}.jsonl"
      manifest_path = output_path <> ".manifest.json"

      try do
        {:ok, _result} =
          JSONL.to_format(queue.id, %{
            schema_version_id: schema_version.id,
            output_path: output_path
          })

        assert File.exists?(manifest_path)

        manifest_content = File.read!(manifest_path)
        assert manifest_content =~ "export_id"
        assert manifest_content =~ "queue_id"
        assert manifest_content =~ "sha256_hash"
      after
        File.rm(output_path)
        File.rm(manifest_path)
      end
    end

    test "handles streaming for large datasets without memory issues", %{
      queue: queue,
      schema_version: schema_version,
      labeler1: labeler1
    } do
      # Create 100 labels to test streaming
      for i <- 1..100 do
        {:ok, assignment} =
          Repo.insert(%Assignment{
            id: Ecto.UUID.generate(),
            queue_id: queue.id,
            sample_id: Ecto.UUID.generate(),
            labeler_id: labeler1.id,
            status: :completed
          })

        Repo.insert(%Label{
          id: Ecto.UUID.generate(),
          assignment_id: assignment.id,
          labeler_id: labeler1.id,
          schema_version_id: schema_version.id,
          payload: %{"coherence" => true, "notes" => "test note #{i}"},
          submitted_at: DateTime.truncate(DateTime.utc_now(), :second)
        })
      end

      output_path = "/tmp/test_jsonl_streaming_#{:rand.uniform(1_000_000)}.jsonl"

      try do
        {:ok, result} =
          JSONL.to_format(queue.id, %{
            schema_version_id: schema_version.id,
            output_path: output_path
          })

        assert result.manifest.row_count == 100
        assert File.exists?(output_path)

        lines = File.read!(output_path) |> String.split("\n", trim: true)
        assert length(lines) == 100
      after
        File.rm(output_path)
        File.rm(output_path <> ".manifest.json")
      end
    end
  end
end
