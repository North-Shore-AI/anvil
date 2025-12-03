defmodule Anvil.ForgeBridge.CachedTest do
  use Supertester.ExUnitFoundation, isolation: :full_isolation

  alias Anvil.ForgeBridge.Cached
  alias Anvil.ForgeBridge.SampleDTO

  setup do
    # Clear cache before each test
    Cached.clear_cache()
    :ok
  end

  describe "fetch_sample/2" do
    test "caches sample on first fetch" do
      assert {:ok, sample} = Cached.fetch_sample("test-id")
      assert %SampleDTO{} = sample

      # Verify it's in the cache
      {:ok, cached} = Cachex.get(:forge_samples, "test-id")
      assert cached == sample
    end

    test "returns cached sample on subsequent fetch" do
      # First fetch
      {:ok, sample1} = Cached.fetch_sample("test-id")

      # Second fetch should hit cache
      {:ok, sample2} = Cached.fetch_sample("test-id")

      assert sample1 == sample2
    end

    test "emits cache hit telemetry" do
      # Prime the cache
      Cached.fetch_sample("test-id")

      # Attach telemetry handler
      :telemetry.attach(
        "test-cache-hit",
        [:anvil, :forge_bridge, :cache_hit],
        fn event, _measurements, metadata, _config ->
          send(self(), {:telemetry, event, metadata})
        end,
        nil
      )

      # Fetch again (should hit cache)
      Cached.fetch_sample("test-id")

      assert_receive {:telemetry, [:anvil, :forge_bridge, :cache_hit], metadata}
      assert metadata.sample_id == "test-id"

      :telemetry.detach("test-cache-hit")
    end

    test "emits cache miss telemetry" do
      :telemetry.attach(
        "test-cache-miss",
        [:anvil, :forge_bridge, :cache_miss],
        fn event, _measurements, metadata, _config ->
          send(self(), {:telemetry, event, metadata})
        end,
        nil
      )

      Cached.fetch_sample("test-id")

      assert_receive {:telemetry, [:anvil, :forge_bridge, :cache_miss], metadata}
      assert metadata.sample_id == "test-id"

      :telemetry.detach("test-cache-miss")
    end

    test "bypasses cache when bypass_cache option is true" do
      # Prime the cache
      {:ok, _sample1} = Cached.fetch_sample("test-id")

      # Fetch with bypass_cache
      {:ok, sample2} = Cached.fetch_sample("test-id", bypass_cache: true)

      # Should still work but bypass cache
      assert %SampleDTO{} = sample2
    end

    test "handles cache errors gracefully" do
      # This should work even if cache has issues
      assert {:ok, sample} = Cached.fetch_sample("test-id")
      assert %SampleDTO{} = sample
    end
  end

  describe "fetch_samples/2" do
    test "caches all fetched samples" do
      ids = ["id-1", "id-2", "id-3"]
      assert {:ok, samples} = Cached.fetch_samples(ids)

      assert length(samples) == 3

      # Verify all are cached
      Enum.each(ids, fn id ->
        {:ok, cached} = Cachex.get(:forge_samples, id)
        assert %SampleDTO{id: ^id} = cached
      end)
    end

    test "returns mix of cached and freshly fetched samples" do
      # Prime cache with some samples
      Cached.fetch_sample("id-1")
      Cached.fetch_sample("id-2")

      # Fetch batch including cached and uncached
      ids = ["id-1", "id-2", "id-3", "id-4"]
      assert {:ok, samples} = Cached.fetch_samples(ids)

      assert length(samples) == 4

      sample_ids = Enum.map(samples, & &1.id) |> Enum.sort()
      assert sample_ids == Enum.sort(ids)
    end

    test "handles partial failures gracefully" do
      # Prime some cache
      Cached.fetch_sample("id-1")

      # This should return at least the cached samples
      ids = ["id-1", "id-2"]
      assert {:ok, samples} = Cached.fetch_samples(ids)

      assert length(samples) >= 1
    end
  end

  describe "invalidate/1" do
    test "removes sample from cache" do
      # Cache a sample
      Cached.fetch_sample("test-id")
      {:ok, cached} = Cachex.get(:forge_samples, "test-id")
      assert %SampleDTO{} = cached

      # Invalidate it
      assert :ok = Cached.invalidate("test-id")

      # Should be gone
      {:ok, result} = Cachex.get(:forge_samples, "test-id")
      assert is_nil(result)
    end
  end

  describe "warm_cache/1" do
    test "preloads samples into cache" do
      ids = ["id-1", "id-2", "id-3"]

      # Warm the cache - this is synchronous and waits for all tasks to complete
      assert :ok = Cached.warm_cache(ids)

      # Verify samples are cached
      Enum.each(ids, fn id ->
        {:ok, cached} = Cachex.get(:forge_samples, id)
        assert %SampleDTO{id: ^id} = cached
      end)
    end

    test "handles empty list" do
      assert :ok = Cached.warm_cache([])
    end
  end

  describe "clear_cache/0" do
    test "clears all cached samples" do
      # Cache some samples
      Cached.fetch_sample("id-1")
      Cached.fetch_sample("id-2")

      # Clear cache
      assert {:ok, _count} = Cached.clear_cache()

      # Verify cache is empty
      {:ok, result1} = Cachex.get(:forge_samples, "id-1")
      {:ok, result2} = Cachex.get(:forge_samples, "id-2")

      assert is_nil(result1)
      assert is_nil(result2)
    end
  end

  describe "verify_sample_exists/1" do
    test "checks cache first" do
      # Cache a sample
      Cached.fetch_sample("test-id")

      # This should hit cache, not backend
      assert true == Cached.verify_sample_exists("test-id")
    end

    test "falls back to backend if not cached" do
      # Not cached, should check backend
      assert true == Cached.verify_sample_exists("uncached-id")
    end
  end

  describe "fetch_sample_version/1" do
    test "returns version from cache if available" do
      # Cache a sample
      {:ok, sample} = Cached.fetch_sample("test-id")

      # Version fetch should hit cache
      assert {:ok, version} = Cached.fetch_sample_version("test-id")
      assert version == sample.version
    end

    test "falls back to backend if not cached" do
      assert {:ok, version} = Cached.fetch_sample_version("uncached-id")
      assert is_binary(version)
    end
  end
end
