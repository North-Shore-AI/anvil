defmodule Anvil.Export.CSV do
  @moduledoc """
  CSV export adapter with deterministic ordering and lineage tracking.

  Implements the ADR-005 export system with:
  - Streaming for memory safety
  - Deterministic ordering (sample_id ASC, labeler_id ASC, submitted_at ASC)
  - Export manifest generation with SHA256 hashes
  - Proper CSV escaping
  """

  alias Anvil.Export.Manifest
  alias Anvil.Repo
  alias Anvil.Schema.{Label, Assignment}
  import Ecto.Query

  @doc """
  Exports labels to CSV format following ADR-005 specification.

  ## Options

    * `:schema_version_id` - (required) UUID of the schema version for reproducibility
    * `:output_path` - (required) File path for the CSV export
    * `:sample_version` - (optional) Forge version tag for full lineage tracking
    * `:limit` - (optional) Maximum number of rows to export
    * `:offset` - (optional) Number of rows to skip before exporting
    * `:filter` - (optional) Additional filter criteria

  ## Returns

    * `{:ok, %{manifest: manifest, output_path: path}}` on success
    * `{:error, reason}` on failure

  ## Examples

      iex> Anvil.Export.CSV.to_format(queue_id, %{
      ...>   schema_version_id: schema_v2_id,
      ...>   output_path: "/tmp/labels.csv"
      ...> })
      {:ok, %{manifest: %Manifest{...}, output_path: "/tmp/labels.csv"}}
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
        row_count = write_csv_file(tmp_path, queue_id, schema_version_id, opts)

        # Rename tmp file to final destination
        :ok = File.rename!(tmp_path, output_path)

        case Manifest.compute_file_hash(output_path) do
          {:ok, sha256_hash} ->
            manifest =
              Manifest.new(%{
                queue_id: queue_id,
                schema_version_id: schema_version_id,
                sample_version: Map.get(opts, :sample_version),
                format: :csv,
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
      # Write header
      header = build_header(labels, include_metadata)
      IO.write(file, header <> "\n")

      # Write rows
      Enum.each(labels, fn label ->
        row = build_row(label, include_metadata)
        IO.write(file, row <> "\n")
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

  defp write_csv_file(path, queue_id, schema_version_id, opts) do
    File.open!(path, [:write, :utf8], fn file ->
      # Get first label to determine fields for header
      first_label_query =
        from(l in Label,
          join: a in Assignment,
          on: l.assignment_id == a.id,
          where: a.queue_id == ^queue_id,
          where: l.schema_version_id == ^schema_version_id,
          limit: 1
        )

      first_label = Repo.one(first_label_query)

      # Write header
      header = build_csv_header(first_label)
      IO.write(file, header <> "\n")

      # Stream labels with deterministic ordering
      query = build_export_query(queue_id, schema_version_id, opts)

      {:ok, row_count} =
        Repo.transaction(fn ->
          Repo.stream(query, max_rows: 1000)
          |> Stream.chunk_every(100)
          |> Stream.map(fn batch ->
            rows = Enum.map(batch, &encode_csv_row/1)
            IO.write(file, Enum.join(rows, "\n") <> "\n")
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

  defp build_csv_header(nil) do
    # Default header when no labels exist
    "sample_id,labeler_id,submitted_at"
  end

  defp build_csv_header(label) do
    base_fields = ["sample_id", "labeler_id"]

    # Extract field names from payload and sort them for consistency
    payload_fields =
      case label.payload do
        nil -> []
        payload -> Map.keys(payload) |> Enum.sort()
      end

    metadata_fields = ["submitted_at"]

    (base_fields ++ payload_fields ++ metadata_fields)
    |> Enum.join(",")
  end

  defp encode_csv_row(label) do
    base_values = [
      escape_csv_value(label.sample_id),
      escape_csv_value(label.labeler_id)
    ]

    # Extract payload values in sorted key order
    payload_values =
      case label.payload do
        nil ->
          []

        payload ->
          payload
          |> Enum.sort_by(fn {k, _} -> k end)
          |> Enum.map(fn {_, v} -> escape_csv_value(v) end)
      end

    metadata_values = [
      escape_csv_value(DateTime.to_iso8601(label.submitted_at))
    ]

    (base_values ++ payload_values ++ metadata_values)
    |> Enum.join(",")
  end

  defp build_header(labels, include_metadata) do
    base_fields = ["sample_id", "labeler_id"]

    value_fields =
      case List.first(labels) do
        nil -> []
        label -> Map.keys(label.values)
      end

    metadata_fields =
      if include_metadata do
        ["labeling_time_seconds", "created_at", "valid"]
      else
        []
      end

    (base_fields ++ value_fields ++ metadata_fields)
    |> Enum.join(",")
  end

  defp build_row(label, include_metadata) do
    base_values = [label.sample_id, label.labeler_id]

    value_fields =
      label.values
      |> Enum.sort_by(fn {k, _} -> k end)
      |> Enum.map(fn {_, v} -> escape_csv_value(v) end)

    metadata_values =
      if include_metadata do
        [
          to_string(label.labeling_time_seconds || ""),
          DateTime.to_iso8601(label.created_at),
          to_string(label.valid?)
        ]
      else
        []
      end

    (base_values ++ value_fields ++ metadata_values)
    |> Enum.join(",")
  end

  defp escape_csv_value(value) when is_binary(value) do
    if String.contains?(value, [",", "\"", "\n", "\r"]) do
      "\"" <> String.replace(value, "\"", "\"\"") <> "\""
    else
      value
    end
  end

  defp escape_csv_value(value) when is_boolean(value), do: to_string(value)
  defp escape_csv_value(value) when is_number(value), do: to_string(value)
  defp escape_csv_value(nil), do: ""
  defp escape_csv_value(value), do: to_string(value)

  defp ensure_directory_exists(path) do
    dir = Path.dirname(path)

    case File.mkdir_p(dir) do
      :ok -> :ok
      {:error, reason} -> {:error, {:mkdir_failed, reason}}
    end
  end
end
