defmodule Anvil.ForgeBridge.SampleDTOTest do
  use ExUnit.Case, async: true

  alias Anvil.ForgeBridge.SampleDTO

  describe "validate/1" do
    test "validates a complete DTO" do
      dto = %SampleDTO{
        id: "test-id-123",
        content: %{"text" => "sample content"},
        version: "v1.0",
        metadata: %{"key" => "value"},
        asset_urls: ["https://example.com/asset1"],
        source: "test_source",
        created_at: DateTime.utc_now()
      }

      assert {:ok, ^dto} = SampleDTO.validate(dto)
    end

    test "validates a minimal DTO" do
      dto = %SampleDTO{
        id: "test-id-123",
        content: "text content",
        version: "v1.0"
      }

      assert {:ok, ^dto} = SampleDTO.validate(dto)
    end

    test "returns error for missing id" do
      dto = %SampleDTO{
        id: nil,
        content: "content",
        version: "v1.0"
      }

      assert {:error, :missing_id} = SampleDTO.validate(dto)
    end

    test "returns error for empty id" do
      dto = %SampleDTO{
        id: "",
        content: "content",
        version: "v1.0"
      }

      assert {:error, :missing_id} = SampleDTO.validate(dto)
    end

    test "returns error for missing content" do
      dto = %SampleDTO{
        id: "test-id",
        content: nil,
        version: "v1.0"
      }

      assert {:error, :missing_content} = SampleDTO.validate(dto)
    end

    test "returns error for missing version" do
      dto = %SampleDTO{
        id: "test-id",
        content: "content",
        version: nil
      }

      assert {:error, :missing_version} = SampleDTO.validate(dto)
    end

    test "returns error for empty version" do
      dto = %SampleDTO{
        id: "test-id",
        content: "content",
        version: ""
      }

      assert {:error, :missing_version} = SampleDTO.validate(dto)
    end
  end

  describe "from_map/1" do
    test "creates DTO from map with atom keys" do
      map = %{
        id: "test-id",
        content: %{"text" => "content"},
        version: "v1.0",
        metadata: %{"key" => "value"}
      }

      assert {:ok, dto} = SampleDTO.from_map(map)
      assert dto.id == "test-id"
      assert dto.content == %{"text" => "content"}
      assert dto.version == "v1.0"
      assert dto.metadata == %{"key" => "value"}
    end

    test "creates DTO from map with string keys" do
      map = %{
        "id" => "test-id",
        "content" => "text content",
        "version" => "v1.0"
      }

      assert {:ok, dto} = SampleDTO.from_map(map)
      assert dto.id == "test-id"
      assert dto.content == "text content"
      assert dto.version == "v1.0"
    end

    test "handles version_tag key" do
      map = %{
        "id" => "test-id",
        "content" => "content",
        "version_tag" => "v2.0"
      }

      assert {:ok, dto} = SampleDTO.from_map(map)
      assert dto.version == "v2.0"
    end

    test "prefers version over version_tag" do
      map = %{
        "id" => "test-id",
        "content" => "content",
        "version" => "v1.0",
        "version_tag" => "v2.0"
      }

      assert {:ok, dto} = SampleDTO.from_map(map)
      assert dto.version == "v1.0"
    end

    test "sets default empty list for asset_urls" do
      map = %{
        "id" => "test-id",
        "content" => "content",
        "version" => "v1.0"
      }

      assert {:ok, dto} = SampleDTO.from_map(map)
      assert dto.asset_urls == []
    end

    test "returns error for invalid map" do
      map = %{
        "id" => "test-id"
        # Missing required fields
      }

      assert {:error, _} = SampleDTO.from_map(map)
    end
  end
end
