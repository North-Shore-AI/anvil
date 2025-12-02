defmodule Anvil.Export do
  @moduledoc """
  Export labeled data in various formats with deterministic lineage tracking.

  This module provides two interfaces:
  1. New ADR-005 interface: `to_format/3` with streaming, deterministic ordering, and manifests
  2. Legacy interface: `export/2` for backward compatibility

  ## ADR-005 Interface

  The new interface requires explicit schema version specification and produces:
  - Deterministically ordered exports
  - Export manifests with SHA256 hashes
  - Streaming for large datasets

  ## Examples

      # New interface (recommended)
      {:ok, result} = Anvil.Export.to_format(:csv, queue_id, %{
        schema_version_id: schema_version_id,
        output_path: "/tmp/export.csv"
      })

      # Legacy interface (for backward compatibility)
      Anvil.Export.export(queue, format: :csv, path: "/tmp/export.csv")
  """

  alias Anvil.Export.{CSV, JSONL, Manifest}

  @type format :: :csv | :jsonl
  @type export_result :: %{
          manifest: Manifest.t(),
          output_path: String.t()
        }

  @doc """
  Exports labels to the specified format following ADR-005 specification.

  This is the recommended interface for exports, providing:
  - Deterministic ordering for reproducibility
  - Export manifests with cryptographic hashes
  - Streaming for memory safety
  - Version pinning

  ## Parameters

    * `format` - Export format (`:csv` or `:jsonl`)
    * `queue_id` - UUID of the queue to export
    * `opts` - Export options (map)

  ## Options

    * `:schema_version_id` - (required) UUID of the schema version
    * `:output_path` - (required) File path for export
    * `:sample_version` - (optional) Forge version tag
    * `:limit` - (optional) Maximum number of rows
    * `:offset` - (optional) Number of rows to skip
    * `:filter` - (optional) Filter criteria

  ## Returns

    * `{:ok, %{manifest: manifest, output_path: path}}` on success
    * `{:error, reason}` on failure

  ## Examples

      iex> Anvil.Export.to_format(:csv, queue_id, %{
      ...>   schema_version_id: schema_v2_id,
      ...>   output_path: "/tmp/labels.csv"
      ...> })
      {:ok, %{manifest: %Manifest{...}, output_path: "/tmp/labels.csv"}}

      iex> Anvil.Export.to_format(:jsonl, queue_id, %{
      ...>   schema_version_id: schema_v2_id,
      ...>   output_path: "/tmp/labels.jsonl",
      ...>   limit: 1000,
      ...>   offset: 0
      ...> })
      {:ok, %{manifest: %Manifest{...}, output_path: "/tmp/labels.jsonl"}}
  """
  @spec to_format(format(), binary(), map()) :: {:ok, export_result()} | {:error, term()}
  def to_format(format, queue_id, opts) when is_map(opts) do
    case format do
      :csv -> CSV.to_format(queue_id, opts)
      :jsonl -> JSONL.to_format(queue_id, opts)
      _ -> {:error, {:unsupported_format, format}}
    end
  end

  @doc """
  Legacy export function for backward compatibility.

  This function is deprecated in favor of `to_format/3` which provides
  better reproducibility guarantees through deterministic ordering and
  export manifests.

  ## Options

    * `:format` - Export format (`:csv` or `:jsonl`)
    * `:path` - Output file path
    * `:filter` - Filter function to select labels
    * `:include_metadata` - Include labeling metadata (default: true)

  ## Examples

      iex> Anvil.Export.export(queue, format: :csv, path: "/tmp/labels.csv")
      :ok
  """
  @spec export(pid() | atom(), keyword()) :: :ok | {:error, term()}
  def export(queue, opts) do
    format = Keyword.fetch!(opts, :format)
    path = Keyword.fetch!(opts, :path)
    filter = Keyword.get(opts, :filter)

    labels = Anvil.Queue.get_labels(queue)

    labels =
      if filter do
        Enum.filter(labels, filter)
      else
        labels
      end

    case format do
      :csv -> CSV.export(labels, path, opts)
      :jsonl -> JSONL.export(labels, path, opts)
      _ -> {:error, {:unsupported_format, format}}
    end
  end

  @doc """
  Verifies export reproducibility by re-exporting and comparing hashes.

  ## Examples

      iex> manifest = Anvil.Export.Manifest.load("/tmp/export.csv.manifest.json")
      iex> Anvil.Export.verify_reproducibility(manifest)
      {:ok, :reproducible}
  """
  @spec verify_reproducibility(Manifest.t()) :: {:ok, :reproducible} | {:error, term()}
  def verify_reproducibility(%Manifest{} = manifest) do
    opts = %{
      schema_version_id: manifest.schema_version_id,
      output_path: manifest.output_path <> ".verify",
      sample_version: manifest.sample_version,
      limit: manifest.parameters[:limit],
      offset: manifest.parameters[:offset],
      filter: manifest.parameters[:filter]
    }

    case to_format(manifest.format, manifest.queue_id, opts) do
      {:ok, result} ->
        verify_path = manifest.output_path <> ".verify"

        try do
          if result.manifest.sha256_hash == manifest.sha256_hash do
            {:ok, :reproducible}
          else
            {:error, :hash_mismatch, old: manifest.sha256_hash, new: result.manifest.sha256_hash}
          end
        after
          File.rm(verify_path)
          File.rm(verify_path <> ".manifest.json")
        end

      {:error, reason} ->
        {:error, reason}
    end
  end
end
