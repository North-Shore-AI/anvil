defmodule Anvil.ForgeBridgeTest do
  use ExUnit.Case, async: true

  alias Anvil.ForgeBridge
  alias Anvil.ForgeBridge.SampleDTO

  # Note: These tests use the Mock adapter configured in test.exs

  describe "fetch_sample/2" do
    test "fetches sample using configured backend" do
      assert {:ok, sample} = ForgeBridge.fetch_sample("test-id")
      assert %SampleDTO{} = sample
      assert sample.id == "test-id"
    end

    test "returns error for non-existent sample" do
      assert {:error, :not_found} = ForgeBridge.fetch_sample("non-existent-id")
    end

    test "emits telemetry events" do
      :telemetry.attach(
        "test-fetch-sample",
        [:anvil, :forge_bridge, :fetch_sample],
        fn event, measurements, metadata, _config ->
          send(self(), {:telemetry, event, measurements, metadata})
        end,
        nil
      )

      ForgeBridge.fetch_sample("test-id")

      assert_receive {:telemetry, [:anvil, :forge_bridge, :fetch_sample], measurements, metadata}
      assert is_integer(measurements.duration)
      assert metadata.sample_id == "test-id"
      assert metadata.result in [:ok, :error]

      :telemetry.detach("test-fetch-sample")
    end
  end

  describe "fetch_samples/2" do
    test "batch fetches multiple samples" do
      ids = ["id-1", "id-2", "id-3"]
      assert {:ok, samples} = ForgeBridge.fetch_samples(ids)

      assert length(samples) == 3
      assert Enum.all?(samples, &match?(%SampleDTO{}, &1))
    end

    test "emits telemetry events for batch fetch" do
      :telemetry.attach(
        "test-fetch-samples",
        [:anvil, :forge_bridge, :fetch_samples],
        fn event, measurements, metadata, _config ->
          send(self(), {:telemetry, event, measurements, metadata})
        end,
        nil
      )

      ForgeBridge.fetch_samples(["id-1", "id-2"])

      assert_receive {:telemetry, [:anvil, :forge_bridge, :fetch_samples], measurements,
                      _metadata}

      assert is_integer(measurements.duration)
      assert measurements.count == 2

      :telemetry.detach("test-fetch-samples")
    end
  end

  describe "verify_sample_exists/1" do
    test "verifies sample existence" do
      assert ForgeBridge.verify_sample_exists("test-id") == true
      assert ForgeBridge.verify_sample_exists("non-existent-id") == false
    end
  end

  describe "fetch_sample_version/1" do
    test "fetches only the sample version" do
      assert {:ok, version} = ForgeBridge.fetch_sample_version("test-id")
      assert is_binary(version)
    end

    test "returns error for non-existent sample" do
      assert {:error, :not_found} = ForgeBridge.fetch_sample_version("non-existent-id")
    end
  end
end
