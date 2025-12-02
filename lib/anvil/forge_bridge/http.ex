defmodule Anvil.ForgeBridge.HTTP do
  @moduledoc """
  HTTP API client implementation for ForgeBridge.

  Fetches samples from Forge via REST API. Best for microservices deployments
  where Anvil and Forge are separate services with independent databases.

  ## Configuration

      # config/prod.exs
      config :anvil,
        forge_bridge_backend: Anvil.ForgeBridge.HTTP,
        forge_base_url: "https://forge.nsai.example.com",
        forge_api_token: System.fetch_env!("FORGE_API_TOKEN"),
        forge_timeout: 5_000

  ## Circuit Breaker

  Uses Fuse for circuit breaking to fail fast when Forge is unavailable:
  - 5 failures in 10s window → open circuit for 30s
  - Prevents cascading failures
  - Graceful degradation

  ## API Contract

      GET /api/samples/:id
      Authorization: Bearer {token}

      Response:
      {
        "id": "uuid",
        "content": {...},
        "version_tag": "v2024-12-01",
        "metadata": {...}
      }
  """

  @behaviour Anvil.ForgeBridge

  alias Anvil.ForgeBridge.SampleDTO
  require Logger

  @fuse_name :forge_api_http
  @fuse_opts {{:standard, 5, 10_000}, {:reset, 30_000}}

  @impl true
  def fetch_sample(sample_id, opts \\ []) do
    with :ok <- check_circuit_breaker(),
         {:ok, response} <- do_fetch_sample(sample_id, opts) do
      {:ok, response}
    else
      {:error, :circuit_open} ->
        Logger.warning("Forge API circuit breaker open")
        {:error, :forge_unavailable}

      {:error, _} = error ->
        :fuse.melt(@fuse_name)
        error
    end
  end

  @impl true
  def fetch_samples(sample_ids, opts \\ []) when is_list(sample_ids) do
    with :ok <- check_circuit_breaker(),
         {:ok, response} <- do_fetch_samples(sample_ids, opts) do
      {:ok, response}
    else
      {:error, :circuit_open} ->
        Logger.warning("Forge API circuit breaker open")
        {:error, :forge_unavailable}

      {:error, _} = error ->
        :fuse.melt(@fuse_name)
        error
    end
  end

  @impl true
  def verify_sample_exists(sample_id) do
    case fetch_sample(sample_id) do
      {:ok, _} -> true
      {:error, _} -> false
    end
  end

  @impl true
  def fetch_sample_version(sample_id) do
    case fetch_sample(sample_id, include_metadata: false) do
      {:ok, sample} -> {:ok, sample.version}
      {:error, _} = error -> error
    end
  end

  # Private functions

  defp check_circuit_breaker do
    # Initialize fuse if not already present
    case :fuse.ask(@fuse_name, :sync) do
      :ok ->
        :ok

      :blown ->
        {:error, :circuit_open}

      {:error, :not_found} ->
        # Initialize the fuse
        :fuse.install(@fuse_name, @fuse_opts)
        :ok
    end
  end

  defp do_fetch_sample(sample_id, _opts) do
    url = "#{forge_base_url()}/api/samples/#{sample_id}"
    headers = build_headers()
    timeout = forge_timeout()

    case HTTPoison.get(url, headers, recv_timeout: timeout) do
      {:ok, %HTTPoison.Response{status_code: 200, body: body}} ->
        case Jason.decode(body) do
          {:ok, data} -> SampleDTO.from_map(data)
          {:error, _} -> {:error, :invalid_response}
        end

      {:ok, %HTTPoison.Response{status_code: 404}} ->
        {:error, :not_found}

      {:ok, %HTTPoison.Response{status_code: status}} ->
        Logger.error("Forge API returned status #{status}")
        {:error, {:http_error, status}}

      {:error, %HTTPoison.Error{reason: reason}} ->
        Logger.error("Forge API request failed: #{inspect(reason)}")
        {:error, :forge_unavailable}
    end
  end

  defp do_fetch_samples(sample_ids, _opts) do
    url = "#{forge_base_url()}/api/samples"
    headers = build_headers()
    timeout = forge_timeout()

    # Build query string: ?ids[]=uuid1&ids[]=uuid2
    query_params =
      sample_ids
      |> Enum.map(&"ids[]=#{&1}")
      |> Enum.join("&")

    full_url = "#{url}?#{query_params}"

    case HTTPoison.get(full_url, headers, recv_timeout: timeout) do
      {:ok, %HTTPoison.Response{status_code: 200, body: body}} ->
        case Jason.decode(body) do
          {:ok, %{"samples" => samples}} when is_list(samples) ->
            dtos =
              samples
              |> Enum.map(&SampleDTO.from_map/1)
              |> Enum.filter(&match?({:ok, _}, &1))
              |> Enum.map(fn {:ok, dto} -> dto end)

            {:ok, dtos}

          _ ->
            {:error, :invalid_response}
        end

      {:ok, %HTTPoison.Response{status_code: status}} ->
        Logger.error("Forge API batch returned status #{status}")
        {:error, {:http_error, status}}

      {:error, %HTTPoison.Error{reason: reason}} ->
        Logger.error("Forge API batch request failed: #{inspect(reason)}")
        {:error, :forge_unavailable}
    end
  end

  defp build_headers do
    [
      {"Authorization", "Bearer #{forge_api_token()}"},
      {"Content-Type", "application/json"},
      {"Accept", "application/json"}
    ]
  end

  defp forge_base_url do
    Application.fetch_env!(:anvil, :forge_base_url)
  end

  defp forge_api_token do
    Application.fetch_env!(:anvil, :forge_api_token)
  end

  defp forge_timeout do
    Application.get_env(:anvil, :forge_timeout, 5_000)
  end
end
