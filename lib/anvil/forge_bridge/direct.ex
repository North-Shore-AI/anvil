defmodule Anvil.ForgeBridge.Direct do
  @moduledoc """
  Direct database access implementation for ForgeBridge.

  Queries Forge samples directly from the database using cross-schema queries.
  Best for shared Postgres deployments where Anvil and Forge share the same
  database cluster.

  ## Configuration

      # config/config.exs
      config :anvil,
        forge_bridge_backend: Anvil.ForgeBridge.Direct,
        forge_schema: "forge"  # Schema name in Postgres

  ## Performance

  - Fastest option (<5ms p99)
  - No network overhead
  - Transactional consistency
  - Requires shared database cluster

  ## Database Setup

  Requires Forge samples table to be accessible:

      -- Cross-schema query
      SELECT * FROM forge.samples WHERE id = $1;

  """

  @behaviour Anvil.ForgeBridge

  alias Anvil.ForgeBridge.SampleDTO
  alias Anvil.Repo
  import Ecto.Query

  @impl true
  def fetch_sample(sample_id, opts \\ []) do
    schema = forge_schema()

    query =
      from(s in fragment("?.samples", literal(^schema)),
        where: s.id == ^sample_id,
        select: %{
          id: s.id,
          content: s.content,
          version_tag: s.version_tag,
          metadata: s.metadata,
          created_at: s.inserted_at
        }
      )

    case Repo.one(query) do
      nil ->
        {:error, :not_found}

      sample_row ->
        dto = to_dto(sample_row, opts)
        {:ok, dto}
    end
  rescue
    e in Postgrex.Error ->
      require Logger
      Logger.error("Forge DB query failed: #{inspect(e)}")
      {:error, :forge_unavailable}
  end

  @impl true
  def fetch_samples(sample_ids, opts \\ []) when is_list(sample_ids) do
    schema = forge_schema()

    query =
      from(s in fragment("?.samples", literal(^schema)),
        where: s.id in ^sample_ids,
        select: %{
          id: s.id,
          content: s.content,
          version_tag: s.version_tag,
          metadata: s.metadata,
          created_at: s.inserted_at
        }
      )

    samples =
      query
      |> Repo.all()
      |> Enum.map(&to_dto(&1, opts))

    {:ok, samples}
  rescue
    e in Postgrex.Error ->
      require Logger
      Logger.error("Forge DB batch query failed: #{inspect(e)}")
      {:error, :forge_unavailable}
  end

  @impl true
  def verify_sample_exists(sample_id) do
    schema = forge_schema()

    query =
      from(s in fragment("?.samples", literal(^schema)),
        where: s.id == ^sample_id,
        select: 1
      )

    Repo.exists?(query)
  rescue
    _ -> false
  end

  @impl true
  def fetch_sample_version(sample_id) do
    schema = forge_schema()

    query =
      from(s in fragment("?.samples", literal(^schema)),
        where: s.id == ^sample_id,
        select: s.version_tag
      )

    case Repo.one(query) do
      nil -> {:error, :not_found}
      version -> {:ok, version}
    end
  rescue
    _ -> {:error, :forge_unavailable}
  end

  # Private helpers

  defp to_dto(sample_row, _opts) do
    %SampleDTO{
      id: sample_row.id,
      content: sample_row.content,
      version: sample_row.version_tag,
      metadata: sample_row.metadata || %{},
      asset_urls: extract_asset_urls(sample_row.metadata),
      source: extract_source(sample_row.metadata),
      created_at: sample_row.created_at
    }
  end

  defp extract_asset_urls(%{"asset_keys" => keys}) when is_list(keys) do
    # In production, generate pre-signed S3 URLs
    # For now, return placeholder URLs
    Enum.map(keys, fn key ->
      "https://forge-assets.example.com/#{key}"
    end)
  end

  defp extract_asset_urls(_), do: []

  defp extract_source(%{"source" => source}), do: source
  defp extract_source(_), do: nil

  defp forge_schema do
    Application.get_env(:anvil, :forge_schema, "forge")
  end
end
