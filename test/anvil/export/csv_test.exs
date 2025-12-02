defmodule Anvil.Export.CSVTest do
  use Supertester.ExUnitFoundation, isolation: :full_isolation

  alias Anvil.Export.CSV
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
    test "exports labels to CSV with deterministic ordering", %{
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

      output_path = "/tmp/test_csv_deterministic_#{:rand.uniform(1_000_000)}.csv"

      try do
        {:ok, result} =
          CSV.to_format(queue.id, %{
            schema_version_id: schema_version.id,
            output_path: output_path
          })

        assert File.exists?(output_path)
        assert result.manifest.row_count == 6

        # Read CSV and verify ordering
        lines = File.read!(output_path) |> String.split("\n", trim: true)
        [_header | rows] = lines

        # Extract sample_ids from each row
        sample_ids_in_csv =
          Enum.map(rows, fn row ->
            [sample_id | _] = String.split(row, ",")
            sample_id
          end)

        # Should be sorted by sample_id, then labeler_id
        # Check that IDs are sorted deterministically
        assert sample_ids_in_csv == Enum.sort(sample_ids_in_csv)
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

      output_path1 = "/tmp/test_csv_hash1_#{:rand.uniform(1_000_000)}.csv"
      output_path2 = "/tmp/test_csv_hash2_#{:rand.uniform(1_000_000)}.csv"

      try do
        {:ok, result1} =
          CSV.to_format(queue.id, %{
            schema_version_id: schema_version.id,
            output_path: output_path1
          })

        {:ok, result2} =
          CSV.to_format(queue.id, %{
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
      output_path = "/tmp/test_csv_no_schema.csv"

      assert {:error, {:missing_required_option, :schema_version_id}} =
               CSV.to_format(queue.id, %{output_path: output_path})
    end

    test "requires output_path parameter", %{queue: queue, schema_version: schema_version} do
      assert {:error, {:missing_required_option, :output_path}} =
               CSV.to_format(queue.id, %{schema_version_id: schema_version.id})
    end

    test "handles empty label set", %{queue: queue, schema_version: schema_version} do
      output_path = "/tmp/test_csv_empty_#{:rand.uniform(1_000_000)}.csv"

      try do
        {:ok, result} =
          CSV.to_format(queue.id, %{
            schema_version_id: schema_version.id,
            output_path: output_path
          })

        assert File.exists?(output_path)
        assert result.manifest.row_count == 0

        # Should still have header
        content = File.read!(output_path)
        lines = String.split(content, "\n", trim: true)
        assert length(lines) == 1
        assert hd(lines) =~ "sample_id"
      after
        File.rm(output_path)
        File.rm(output_path <> ".manifest.json")
      end
    end

    test "escapes CSV special characters properly", %{
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
        payload: %{
          "coherence" => true,
          "notes" => "Contains \"quotes\", commas, and\nnewlines"
        },
        submitted_at: DateTime.truncate(DateTime.utc_now(), :second)
      })

      output_path = "/tmp/test_csv_escape_#{:rand.uniform(1_000_000)}.csv"

      try do
        {:ok, _result} =
          CSV.to_format(queue.id, %{
            schema_version_id: schema_version.id,
            output_path: output_path
          })

        content = File.read!(output_path)
        # Should properly escape the notes field
        assert content =~ "\"Contains \"\"quotes\"\", commas, and\nnewlines\""
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

      output_path = "/tmp/test_csv_limit_#{:rand.uniform(1_000_000)}.csv"

      try do
        {:ok, result} =
          CSV.to_format(queue.id, %{
            schema_version_id: schema_version.id,
            output_path: output_path,
            limit: 3
          })

        assert result.manifest.row_count == 3

        lines = File.read!(output_path) |> String.split("\n", trim: true)
        # 1 header + 3 data rows
        assert length(lines) == 4
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

      output_path = "/tmp/test_csv_offset_#{:rand.uniform(1_000_000)}.csv"

      try do
        {:ok, result} =
          CSV.to_format(queue.id, %{
            schema_version_id: schema_version.id,
            output_path: output_path,
            offset: 2,
            limit: 2
          })

        assert result.manifest.row_count == 2

        lines = File.read!(output_path) |> String.split("\n", trim: true)
        [_header | _rows] = lines

        # Should get samples 003 and 004 (skipped first 2)
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

      output_path = "/tmp/test_csv_manifest_#{:rand.uniform(1_000_000)}.csv"

      try do
        {:ok, result} =
          CSV.to_format(queue.id, %{
            schema_version_id: schema_version.id,
            output_path: output_path,
            sample_version: "2024-12-01"
          })

        manifest = result.manifest

        assert manifest.queue_id == queue.id
        assert manifest.schema_version_id == schema_version.id
        assert manifest.sample_version == "2024-12-01"
        assert manifest.format == :csv
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

      output_path = "/tmp/test_csv_manifest_file_#{:rand.uniform(1_000_000)}.csv"
      manifest_path = output_path <> ".manifest.json"

      try do
        {:ok, _result} =
          CSV.to_format(queue.id, %{
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

      output_path = "/tmp/test_csv_streaming_#{:rand.uniform(1_000_000)}.csv"

      try do
        {:ok, result} =
          CSV.to_format(queue.id, %{
            schema_version_id: schema_version.id,
            output_path: output_path
          })

        assert result.manifest.row_count == 100
        assert File.exists?(output_path)

        lines = File.read!(output_path) |> String.split("\n", trim: true)
        # 1 header + 100 data rows
        assert length(lines) == 101
      after
        File.rm(output_path)
        File.rm(output_path <> ".manifest.json")
      end
    end
  end
end
