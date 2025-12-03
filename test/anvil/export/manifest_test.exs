defmodule Anvil.Export.ManifestTest do
  use Supertester.ExUnitFoundation, isolation: :full_isolation

  alias Anvil.Export.Manifest

  describe "new/1" do
    test "creates a manifest with all required fields" do
      params = %{
        queue_id: "queue_123",
        schema_version_id: "schema_v1",
        format: :csv,
        output_path: "/tmp/test.csv",
        row_count: 100,
        sha256_hash: "abc123def456",
        exported_at: ~U[2025-12-01 10:00:00Z],
        parameters: %{filter: %{}, limit: nil, offset: nil}
      }

      manifest = Manifest.new(params)

      assert manifest.queue_id == "queue_123"
      assert manifest.schema_version_id == "schema_v1"
      assert manifest.format == :csv
      assert manifest.output_path == "/tmp/test.csv"
      assert manifest.row_count == 100
      assert manifest.sha256_hash == "abc123def456"
      assert manifest.exported_at == ~U[2025-12-01 10:00:00Z]
      assert manifest.parameters == %{filter: %{}, limit: nil, offset: nil}
    end

    test "generates export_id automatically" do
      params = %{
        queue_id: "queue_123",
        schema_version_id: "schema_v1",
        format: :csv,
        output_path: "/tmp/test.csv",
        row_count: 100,
        sha256_hash: "abc123",
        exported_at: ~U[2025-12-01 10:00:00Z],
        parameters: %{}
      }

      manifest = Manifest.new(params)

      assert is_binary(manifest.export_id)
      assert String.starts_with?(manifest.export_id, "exp_")
    end

    test "allows custom export_id" do
      params = %{
        export_id: "exp_custom_123",
        queue_id: "queue_123",
        schema_version_id: "schema_v1",
        format: :csv,
        output_path: "/tmp/test.csv",
        row_count: 100,
        sha256_hash: "abc123",
        exported_at: ~U[2025-12-01 10:00:00Z],
        parameters: %{}
      }

      manifest = Manifest.new(params)

      assert manifest.export_id == "exp_custom_123"
    end

    test "includes sample_version when provided" do
      params = %{
        queue_id: "queue_123",
        schema_version_id: "schema_v1",
        sample_version: "2024-12-01",
        format: :csv,
        output_path: "/tmp/test.csv",
        row_count: 100,
        sha256_hash: "abc123",
        exported_at: ~U[2025-12-01 10:00:00Z],
        parameters: %{}
      }

      manifest = Manifest.new(params)

      assert manifest.sample_version == "2024-12-01"
    end
  end

  describe "to_json/1" do
    test "converts manifest to JSON string" do
      manifest = %Manifest{
        export_id: "exp_123",
        queue_id: "queue_123",
        schema_version_id: "schema_v1",
        sample_version: nil,
        format: :csv,
        output_path: "/tmp/test.csv",
        row_count: 100,
        sha256_hash: "abc123",
        exported_at: ~U[2025-12-01 10:00:00Z],
        parameters: %{filter: %{}},
        anvil_version: "test_version",
        schema_definition_hash: nil
      }

      json = Manifest.to_json(manifest)

      assert is_binary(json)
      assert json =~ "exp_123"
      assert json =~ "queue_123"
      assert json =~ "schema_v1"
    end

    test "pretty prints JSON by default" do
      manifest = %Manifest{
        export_id: "exp_123",
        queue_id: "queue_123",
        schema_version_id: "schema_v1",
        sample_version: nil,
        format: :csv,
        output_path: "/tmp/test.csv",
        row_count: 100,
        sha256_hash: "abc123",
        exported_at: ~U[2025-12-01 10:00:00Z],
        parameters: %{},
        anvil_version: "test_version",
        schema_definition_hash: nil
      }

      json = Manifest.to_json(manifest)

      assert json =~ "\n"
      assert json =~ "  "
    end
  end

  describe "from_json/1" do
    test "parses JSON string back to manifest struct" do
      json = """
      {
        "export_id": "exp_123",
        "queue_id": "queue_123",
        "schema_version_id": "schema_v1",
        "format": "csv",
        "output_path": "/tmp/test.csv",
        "row_count": 100,
        "sha256_hash": "abc123",
        "exported_at": "2025-12-01T10:00:00Z",
        "parameters": {},
        "anvil_version": "test_version"
      }
      """

      {:ok, manifest} = Manifest.from_json(json)

      assert manifest.export_id == "exp_123"
      assert manifest.queue_id == "queue_123"
      assert manifest.schema_version_id == "schema_v1"
      assert manifest.format == :csv
      assert manifest.output_path == "/tmp/test.csv"
      assert manifest.row_count == 100
      assert manifest.sha256_hash == "abc123"
      assert manifest.exported_at == ~U[2025-12-01 10:00:00Z]
    end

    test "returns error for invalid JSON" do
      assert {:error, _} = Manifest.from_json("not valid json")
    end
  end

  describe "save/2" do
    test "saves manifest to file with .manifest.json suffix" do
      manifest = %Manifest{
        export_id: "exp_123",
        queue_id: "queue_123",
        schema_version_id: "schema_v1",
        sample_version: nil,
        format: :csv,
        output_path: "/tmp/test_manifest_save.csv",
        row_count: 100,
        sha256_hash: "abc123",
        exported_at: ~U[2025-12-01 10:00:00Z],
        parameters: %{},
        anvil_version: "test_version",
        schema_definition_hash: nil
      }

      manifest_path = "/tmp/test_manifest_save.csv.manifest.json"

      try do
        assert :ok = Manifest.save(manifest)
        assert File.exists?(manifest_path)

        content = File.read!(manifest_path)
        assert content =~ "exp_123"
      after
        File.rm(manifest_path)
      end
    end

    test "allows custom manifest path" do
      manifest = %Manifest{
        export_id: "exp_123",
        queue_id: "queue_123",
        schema_version_id: "schema_v1",
        sample_version: nil,
        format: :csv,
        output_path: "/tmp/test_manifest_custom.csv",
        row_count: 100,
        sha256_hash: "abc123",
        exported_at: ~U[2025-12-01 10:00:00Z],
        parameters: %{},
        anvil_version: "test_version",
        schema_definition_hash: nil
      }

      custom_path = "/tmp/custom_manifest.json"

      try do
        assert :ok = Manifest.save(manifest, custom_path)
        assert File.exists?(custom_path)
      after
        File.rm(custom_path)
      end
    end
  end

  describe "load/1" do
    test "loads manifest from file" do
      manifest = %Manifest{
        export_id: "exp_load_test",
        queue_id: "queue_123",
        schema_version_id: "schema_v1",
        sample_version: nil,
        format: :csv,
        output_path: "/tmp/test_manifest_load.csv",
        row_count: 100,
        sha256_hash: "abc123",
        exported_at: ~U[2025-12-01 10:00:00Z],
        parameters: %{},
        anvil_version: "test_version",
        schema_definition_hash: nil
      }

      manifest_path = "/tmp/test_manifest_load.csv.manifest.json"

      try do
        Manifest.save(manifest)

        {:ok, loaded} = Manifest.load(manifest_path)

        assert loaded.export_id == "exp_load_test"
        assert loaded.queue_id == "queue_123"
        assert loaded.format == :csv
      after
        File.rm(manifest_path)
      end
    end

    test "returns error when file doesn't exist" do
      assert {:error, _} = Manifest.load("/nonexistent/path.json")
    end
  end

  describe "compute_file_hash/1" do
    test "computes SHA256 hash of file" do
      test_file = "/tmp/test_hash_#{:rand.uniform(1_000_000)}.txt"
      File.write!(test_file, "Hello, World!")

      try do
        {:ok, hash} = Manifest.compute_file_hash(test_file)

        assert is_binary(hash)
        assert byte_size(hash) == 64
        # SHA256 of "Hello, World!" is deterministic
        assert hash == "dffd6021bb2bd5b0af676290809ec3a53191dd81c7f70a4b28688a362182986f"
      after
        File.rm(test_file)
      end
    end

    test "computes same hash for same content" do
      test_file1 = "/tmp/test_hash_1_#{:rand.uniform(1_000_000)}.txt"
      test_file2 = "/tmp/test_hash_2_#{:rand.uniform(1_000_000)}.txt"
      content = "Deterministic content for testing"

      File.write!(test_file1, content)
      File.write!(test_file2, content)

      try do
        {:ok, hash1} = Manifest.compute_file_hash(test_file1)
        {:ok, hash2} = Manifest.compute_file_hash(test_file2)

        assert hash1 == hash2
      after
        File.rm(test_file1)
        File.rm(test_file2)
      end
    end

    test "handles large files without loading into memory" do
      test_file = "/tmp/test_hash_large_#{:rand.uniform(1_000_000)}.txt"
      # Create a 1MB file
      File.write!(test_file, String.duplicate("x", 1_000_000))

      try do
        {:ok, hash} = Manifest.compute_file_hash(test_file)

        assert is_binary(hash)
        assert byte_size(hash) == 64
      after
        File.rm(test_file)
      end
    end

    test "returns error for nonexistent file" do
      assert {:error, _} = Manifest.compute_file_hash("/nonexistent/file.txt")
    end
  end
end
