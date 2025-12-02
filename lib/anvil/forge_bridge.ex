defmodule Anvil.ForgeBridge do
  @moduledoc """
  Abstract interface for fetching samples from Forge.

  Supports multiple backends (direct DB, HTTP, cached) to enable different
  deployment topologies:
  - Direct: Same Postgres cluster, cross-schema queries
  - HTTP: Separate services with REST API
  - Cached: Performance wrapper with TTL-based caching

  ## Configuration

      # config/config.exs
      config :anvil,
        forge_bridge_backend: Anvil.ForgeBridge.Direct

  ## Usage

      {:ok, sample} = Anvil.ForgeBridge.fetch_sample(sample_id)
      %SampleDTO{id: id, content: content, version: version} = sample
  """

  alias Anvil.ForgeBridge.SampleDTO

  @type sample_id :: binary()
  @type sample_dto :: SampleDTO.t()
  @type error_reason :: :not_found | :forge_unavailable | atom()

  @doc """
  Fetches a single sample from Forge by ID.

  ## Options

  - `:version` - Fetch specific version (optional)
  - `:include_metadata` - Include full metadata (default: true)
  """
  @callback fetch_sample(sample_id(), opts :: keyword()) ::
              {:ok, sample_dto()} | {:error, error_reason()}

  @doc """
  Batch fetch multiple samples from Forge.

  Returns samples in same order as input IDs. Missing samples are omitted.
  """
  @callback fetch_samples([sample_id()], opts :: keyword()) ::
              {:ok, [sample_dto()]} | {:error, error_reason()}

  @doc """
  Verifies if a sample exists in Forge (lightweight check).
  """
  @callback verify_sample_exists(sample_id()) :: boolean()

  @doc """
  Fetches only the version tag for a sample (lightweight query).
  """
  @callback fetch_sample_version(sample_id()) :: {:ok, String.t()} | {:error, error_reason()}

  # Delegation functions

  @doc """
  Fetches a single sample using the configured backend.
  """
  @spec fetch_sample(sample_id(), keyword()) :: {:ok, sample_dto()} | {:error, error_reason()}
  def fetch_sample(sample_id, opts \\ []) do
    start_time = System.monotonic_time()

    result = backend().fetch_sample(sample_id, opts)

    duration = System.monotonic_time() - start_time

    :telemetry.execute(
      [:anvil, :forge_bridge, :fetch_sample],
      %{duration: duration},
      %{
        backend: backend(),
        sample_id: sample_id,
        result: elem(result, 0)
      }
    )

    result
  end

  @doc """
  Batch fetches samples using the configured backend.
  """
  @spec fetch_samples([sample_id()], keyword()) ::
          {:ok, [sample_dto()]} | {:error, error_reason()}
  def fetch_samples(sample_ids, opts \\ []) do
    start_time = System.monotonic_time()

    result = backend().fetch_samples(sample_ids, opts)

    duration = System.monotonic_time() - start_time

    :telemetry.execute(
      [:anvil, :forge_bridge, :fetch_samples],
      %{duration: duration, count: length(sample_ids)},
      %{backend: backend(), result: elem(result, 0)}
    )

    result
  end

  @doc """
  Verifies sample existence using the configured backend.
  """
  @spec verify_sample_exists(sample_id()) :: boolean()
  def verify_sample_exists(sample_id) do
    backend().verify_sample_exists(sample_id)
  end

  @doc """
  Fetches sample version using the configured backend.
  """
  @spec fetch_sample_version(sample_id()) :: {:ok, String.t()} | {:error, error_reason()}
  def fetch_sample_version(sample_id) do
    backend().fetch_sample_version(sample_id)
  end

  # Private helpers

  defp backend do
    Application.get_env(:anvil, :forge_bridge_backend, Anvil.ForgeBridge.Direct)
  end
end
