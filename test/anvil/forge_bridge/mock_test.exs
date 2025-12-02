defmodule Anvil.ForgeBridge.MockTest do
  use ExUnit.Case, async: true

  alias Anvil.ForgeBridge.Mock
  alias Anvil.ForgeBridge.SampleDTO

  describe "fetch_sample/2" do
    test "returns mock sample for valid ID" do
      assert {:ok, sample} = Mock.fetch_sample("test-id-123")
      assert %SampleDTO{} = sample
      assert sample.id == "test-id-123"
      assert sample.version == "mock_v1"
      assert sample.content["text"] =~ "test-id-123"
      assert sample.source == "mock_dataset"
    end

    test "returns error for non-existent ID" do
      assert {:error, :not_found} = Mock.fetch_sample("non-existent-id")
    end

    test "respects version option" do
      assert {:ok, sample} = Mock.fetch_sample("test-id", version: "custom_v2")
      assert sample.version == "custom_v2"
    end

    test "returns deterministic content based on ID" do
      {:ok, sample1} = Mock.fetch_sample("id-1")
      {:ok, sample2} = Mock.fetch_sample("id-1")
      {:ok, sample3} = Mock.fetch_sample("id-2")

      # Same ID returns same content
      assert sample1.content == sample2.content

      # Different ID returns different content
      assert sample1.content != sample3.content
    end
  end

  describe "fetch_samples/2" do
    test "returns multiple mock samples" do
      ids = ["id-1", "id-2", "id-3"]
      assert {:ok, samples} = Mock.fetch_samples(ids)

      assert length(samples) == 3
      assert Enum.all?(samples, &match?(%SampleDTO{}, &1))

      sample_ids = Enum.map(samples, & &1.id)
      assert Enum.sort(sample_ids) == Enum.sort(ids)
    end

    test "filters out non-existent samples" do
      ids = ["id-1", "non-existent-id", "id-2"]
      assert {:ok, samples} = Mock.fetch_samples(ids)

      assert length(samples) == 2
      sample_ids = Enum.map(samples, & &1.id)
      assert "non-existent-id" not in sample_ids
    end

    test "handles empty list" do
      assert {:ok, []} = Mock.fetch_samples([])
    end
  end

  describe "verify_sample_exists/1" do
    test "returns true for valid ID" do
      assert Mock.verify_sample_exists("test-id") == true
    end

    test "returns false for non-existent ID" do
      assert Mock.verify_sample_exists("non-existent-id") == false
    end
  end

  describe "fetch_sample_version/1" do
    test "returns version for valid ID" do
      assert {:ok, "mock_v1"} = Mock.fetch_sample_version("test-id")
    end

    test "returns error for non-existent ID" do
      assert {:error, :not_found} = Mock.fetch_sample_version("non-existent-id")
    end
  end
end
