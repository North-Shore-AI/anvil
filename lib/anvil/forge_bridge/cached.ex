defmodule Anvil.ForgeBridge.Cached do
  @moduledoc """
  Caching wrapper for ForgeBridge backends.

  Adds TTL-based caching layer on top of any ForgeBridge backend to improve
  performance and reduce load on Forge. Best for hybrid deployments where
  sample content is relatively stable.

  ## Configuration

      # config/config.exs
      config :anvil,
        forge_bridge_backend: Anvil.ForgeBridge.Cached,
        forge_bridge_primary_backend: Anvil.ForgeBridge.Direct,
        forge_cache_ttl: :timer.minutes(15)

  ## Features

  - TTL-based expiration (default 15 minutes)
  - Cache warming for hot queues
  - Graceful degradation (serve stale on backend failure)
  - Telemetry events for cache hits/misses

  ## Cache Invalidation

  Subscribe to sample update events for proactive invalidation:

      Phoenix.PubSub.subscribe(Forge.PubSub, "sample_updates")

      def handle_info({:sample_updated, sample_id}, state) do
        Anvil.ForgeBridge.Cached.invalidate(sample_id)
        {:noreply, state}
      end
  """

  @behaviour Anvil.ForgeBridge

  alias Anvil.ForgeBridge.SampleDTO
  require Logger

  @cache_name :forge_samples

  @impl true
  def fetch_sample(sample_id, opts \\ []) do
    # Check if caching is disabled for this request
    if Keyword.get(opts, :bypass_cache, false) do
      fetch_from_backend(sample_id, opts)
    else
      case Cachex.get(@cache_name, sample_id) do
        {:ok, nil} ->
          # Cache miss
          :telemetry.execute([:anvil, :forge_bridge, :cache_miss], %{}, %{
            sample_id: sample_id
          })

          fetch_and_cache(sample_id, opts)

        {:ok, sample_dto} ->
          # Cache hit
          :telemetry.execute([:anvil, :forge_bridge, :cache_hit], %{}, %{sample_id: sample_id})
          {:ok, sample_dto}

        {:error, _} ->
          # Cache error, bypass cache
          Logger.warning("Cache error for sample #{sample_id}, bypassing cache")
          fetch_from_backend(sample_id, opts)
      end
    end
  end

  @impl true
  def fetch_samples(sample_ids, opts \\ []) when is_list(sample_ids) do
    if Keyword.get(opts, :bypass_cache, false) do
      fetch_samples_from_backend(sample_ids, opts)
    else
      # Split into cached and uncached
      {cached, uncached} = partition_cached(sample_ids)

      # Fetch uncached samples
      case fetch_samples_from_backend(uncached, opts) do
        {:ok, fetched} ->
          # Cache the newly fetched samples
          Enum.each(fetched, &cache_sample/1)

          # Combine cached and fetched
          all_samples = cached ++ fetched
          {:ok, all_samples}

        {:error, _} = error ->
          # Return cached samples even on error (graceful degradation)
          if Enum.empty?(cached) do
            error
          else
            Logger.warning(
              "Partial sample fetch failed, returning #{length(cached)} cached samples"
            )

            {:ok, cached}
          end
      end
    end
  end

  @impl true
  def verify_sample_exists(sample_id) do
    # Check cache first
    case Cachex.get(@cache_name, sample_id) do
      {:ok, %SampleDTO{}} ->
        true

      _ ->
        # Fall back to backend
        primary_backend().verify_sample_exists(sample_id)
    end
  end

  @impl true
  def fetch_sample_version(sample_id) do
    # Check cache first
    case Cachex.get(@cache_name, sample_id) do
      {:ok, %SampleDTO{version: version}} ->
        {:ok, version}

      _ ->
        # Fall back to backend
        primary_backend().fetch_sample_version(sample_id)
    end
  end

  # Public API for cache management

  @doc """
  Invalidates a cached sample by ID.
  """
  @spec invalidate(binary()) :: :ok
  def invalidate(sample_id) do
    Cachex.del(@cache_name, sample_id)
    :ok
  end

  @doc """
  Warms the cache for a list of sample IDs.

  Useful for preloading samples for a queue before labelers request them.
  """
  @spec warm_cache([binary()]) :: :ok
  def warm_cache(sample_ids) when is_list(sample_ids) do
    Task.Supervisor.async_stream_nolink(
      Anvil.TaskSupervisor,
      sample_ids,
      fn sample_id -> fetch_sample(sample_id) end,
      max_concurrency: 10,
      timeout: 5_000,
      on_timeout: :kill_task
    )
    |> Stream.run()

    :ok
  end

  @doc """
  Clears the entire sample cache.
  """
  @spec clear_cache() :: {:ok, integer()}
  def clear_cache do
    Cachex.clear(@cache_name)
  end

  # Private helpers

  defp fetch_and_cache(sample_id, opts) do
    case fetch_from_backend(sample_id, opts) do
      {:ok, sample_dto} = result ->
        cache_sample(sample_dto)
        result

      error ->
        error
    end
  end

  defp fetch_from_backend(sample_id, opts) do
    primary_backend().fetch_sample(sample_id, opts)
  end

  defp fetch_samples_from_backend(sample_ids, opts) do
    primary_backend().fetch_samples(sample_ids, opts)
  end

  defp cache_sample(%SampleDTO{} = sample) do
    ttl = cache_ttl()
    Cachex.put(@cache_name, sample.id, sample, ttl: ttl)
  end

  defp partition_cached(sample_ids) do
    sample_ids
    |> Enum.map(fn id ->
      case Cachex.get(@cache_name, id) do
        {:ok, %SampleDTO{} = sample} -> {:cached, sample}
        _ -> {:uncached, id}
      end
    end)
    |> Enum.split_with(&match?({:cached, _}, &1))
    |> then(fn {cached, uncached} ->
      {
        Enum.map(cached, fn {:cached, sample} -> sample end),
        Enum.map(uncached, fn {:uncached, id} -> id end)
      }
    end)
  end

  defp primary_backend do
    Application.get_env(:anvil, :forge_bridge_primary_backend, Anvil.ForgeBridge.Direct)
  end

  defp cache_ttl do
    Application.get_env(:anvil, :forge_cache_ttl, :timer.minutes(15))
  end
end
