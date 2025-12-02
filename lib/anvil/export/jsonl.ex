defmodule Anvil.Export.JSONL do
  @moduledoc """
  JSONL (JSON Lines) export adapter with deterministic ordering and lineage tracking.

  Implements the ADR-005 export system with:
  - Streaming for memory safety
  - Deterministic ordering (sample_id ASC, labeler_id ASC, submitted_at ASC)
  - Export manifest generation with SHA256 hashes
  - Preservation of nested JSON structures
  """

  alias Anvil.Export.Manifest
  alias Anvil.Repo
  alias Anvil.Schema.{Label, Assignment, SchemaVersion, Labeler}
  alias Anvil.PII.Redactor
  import Ecto.Query

  @doc """
  Exports labels to JSONL format following ADR-005 specification.

  ## Options

    * `:schema_version_id` - (required) UUID of the schema version for reproducibility
    * `:output_path` - (required) File path for the JSONL export
    * `:sample_version` - (optional) Forge version tag for full lineage tracking
    * `:limit` - (optional) Maximum number of rows to export
    * `:offset` - (optional) Number of rows to skip before exporting
    * `:filter` - (optional) Additional filter criteria
    * `:redaction_mode` - (optional) Redaction mode (`:none`, `:automatic`, `:aggressive`) (default: `:automatic`)
    * `:use_pseudonyms` - (optional) Use labeler pseudonyms instead of IDs (default: `true`)

  ## Returns

    * `{:ok, %{manifest: manifest, output_path: path}}` on success
    * `{:error, reason}` on failure

  ## Examples

      iex> Anvil.Export.JSONL.to_format(queue_id, %{
      ...>   schema_version_id: schema_v2_id,
      ...>   output_path: "/tmp/labels.jsonl"
      ...> })
      {:ok, %{manifest: %Manifest{...}, output_path: "/tmp/labels.jsonl"}}
  """
  @spec to_format(binary(), map()) :: {:ok, map()} | {:error, term()}
  def to_format(queue_id, opts) when is_map(opts) do
    with {:ok, schema_version_id} <- validate_required_opt(opts, :schema_version_id),
         {:ok, output_path} <- validate_required_opt(opts, :output_path),
         :ok <- ensure_directory_exists(output_path) do
      # Write export to temporary file first (atomic operation)
      tmp_path = output_path <> ".tmp"

      try do
        # Stream labels and write to file
        row_count = write_jsonl_file(tmp_path, queue_id, schema_version_id, opts)

        # Rename tmp file to final destination
        :ok = File.rename!(tmp_path, output_path)

        case Manifest.compute_file_hash(output_path) do
          {:ok, sha256_hash} ->
            manifest =
              Manifest.new(%{
                queue_id: queue_id,
                schema_version_id: schema_version_id,
                sample_version: Map.get(opts, :sample_version),
                format: :jsonl,
                output_path: output_path,
                row_count: row_count,
                sha256_hash: sha256_hash,
                exported_at: DateTime.utc_now(),
                parameters: %{
                  limit: Map.get(opts, :limit),
                  offset: Map.get(opts, :offset),
                  filter: Map.get(opts, :filter)
                }
              })

            # Save manifest
            :ok = Manifest.save(manifest)

            {:ok, %{manifest: manifest, output_path: output_path}}

          {:error, reason} ->
            File.rm(output_path)
            {:error, reason}
        end
      rescue
        e ->
          # Clean up temp file on error
          File.rm(tmp_path)
          {:error, e}
      end
    end
  end

  @doc """
  Legacy export function for backward compatibility.

  This function is deprecated in favor of `to_format/2`.
  """
  @spec export([Anvil.Label.t()], String.t(), keyword()) :: :ok | {:error, term()}
  def export(labels, path, opts \\ []) do
    include_metadata = Keyword.get(opts, :include_metadata, true)

    with :ok <- ensure_directory_exists(path),
         {:ok, file} <- File.open(path, [:write, :utf8]) do
      Enum.each(labels, fn label ->
        json = to_json(label, include_metadata)
        IO.write(file, json <> "\n")
      end)

      File.close(file)
      :ok
    else
      {:error, reason} -> {:error, reason}
    end
  end

  # Private functions

  defp validate_required_opt(opts, key) do
    case Map.fetch(opts, key) do
      {:ok, value} -> {:ok, value}
      :error -> {:error, {:missing_required_option, key}}
    end
  end

  defp write_jsonl_file(path, queue_id, schema_version_id, opts) do
    File.open!(path, [:write, :utf8], fn file ->
      # Load schema version for field metadata
      schema_version = Repo.get!(SchemaVersion, schema_version_id)

      field_metadata_map =
        Anvil.PII.Retention.extract_field_metadata(schema_version.schema_definition)

      redaction_mode = Map.get(opts, :redaction_mode, :automatic)
      use_pseudonyms = Map.get(opts, :use_pseudonyms, true)

      # Stream labels with deterministic ordering
      query = build_export_query(queue_id, schema_version_id, opts)

      {:ok, row_count} =
        Repo.transaction(fn ->
          Repo.stream(query, max_rows: 1000)
          |> Stream.chunk_every(100)
          |> Stream.map(fn batch ->
            lines =
              Enum.map(batch, fn label ->
                encode_jsonl_line(label, field_metadata_map, redaction_mode, use_pseudonyms)
              end)

            IO.write(file, Enum.join(lines, "\n"))

            # Add newline after batch if not empty
            if length(batch) > 0 do
              IO.write(file, "\n")
            end

            length(batch)
          end)
          |> Enum.sum()
        end)

      row_count
    end)
  end

  defp build_export_query(queue_id, schema_version_id, opts) do
    query =
      from(l in Label,
        join: a in Assignment,
        on: l.assignment_id == a.id,
        where: a.queue_id == ^queue_id,
        where: l.schema_version_id == ^schema_version_id,
        order_by: [asc: a.sample_id, asc: l.labeler_id, asc: l.submitted_at],
        select: %{
          sample_id: a.sample_id,
          labeler_id: l.labeler_id,
          payload: l.payload,
          submitted_at: l.submitted_at
        }
      )

    query = maybe_apply_limit(query, Map.get(opts, :limit))
    query = maybe_apply_offset(query, Map.get(opts, :offset))

    query
  end

  defp maybe_apply_limit(query, nil), do: query
  defp maybe_apply_limit(query, limit), do: from(q in query, limit: ^limit)

  defp maybe_apply_offset(query, nil), do: query
  defp maybe_apply_offset(query, offset), do: from(q in query, offset: ^offset)

  defp encode_jsonl_line(label, field_metadata_map, redaction_mode, use_pseudonyms) do
    # Get labeler identifier (pseudonym or ID)
    labeler_value =
      if use_pseudonyms do
        case Repo.get(Labeler, label.labeler_id) do
          nil -> label.labeler_id
          labeler -> labeler.pseudonym || label.labeler_id
        end
      else
        label.labeler_id
      end

    # Apply redaction to payload
    redacted_payload =
      Redactor.redact_payload(label.payload || %{}, field_metadata_map, redaction_mode)

    data = %{
      sample_id: label.sample_id,
      labeler_id: labeler_value,
      payload: redacted_payload,
      submitted_at: DateTime.to_iso8601(label.submitted_at)
    }

    Jason.encode!(data)
  end

  defp to_json(label, include_metadata) do
    base = %{
      sample_id: label.sample_id,
      labeler_id: label.labeler_id,
      values: label.values
    }

    data =
      if include_metadata do
        Map.merge(base, %{
          labeling_time_seconds: label.labeling_time_seconds,
          created_at: DateTime.to_iso8601(label.created_at),
          valid: label.valid?
        })
      else
        base
      end

    Jason.encode!(data)
  end

  defp ensure_directory_exists(path) do
    dir = Path.dirname(path)

    case File.mkdir_p(dir) do
      :ok -> :ok
      {:error, reason} -> {:error, {:mkdir_failed, reason}}
    end
  end
end
