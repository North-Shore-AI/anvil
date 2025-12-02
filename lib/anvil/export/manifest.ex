defmodule Anvil.Export.Manifest do
  @moduledoc """
  Export manifest for tracking dataset lineage and reproducibility.

  Manifests include:
  - Export metadata (queue, schema version, format)
  - File hash for integrity verification
  - Export parameters for reproducibility
  - Anvil version for compatibility tracking
  """

  @enforce_keys [
    :export_id,
    :queue_id,
    :schema_version_id,
    :format,
    :output_path,
    :row_count,
    :sha256_hash,
    :exported_at,
    :parameters,
    :anvil_version
  ]

  defstruct [
    :export_id,
    :queue_id,
    :schema_version_id,
    :sample_version,
    :format,
    :output_path,
    :row_count,
    :sha256_hash,
    :exported_at,
    :parameters,
    :anvil_version,
    :schema_definition_hash
  ]

  @type t :: %__MODULE__{
          export_id: String.t(),
          queue_id: binary(),
          schema_version_id: binary(),
          sample_version: String.t() | nil,
          format: :csv | :jsonl | :parquet | :huggingface,
          output_path: String.t(),
          row_count: non_neg_integer(),
          sha256_hash: String.t(),
          exported_at: DateTime.t(),
          parameters: map(),
          anvil_version: String.t(),
          schema_definition_hash: String.t() | nil
        }

  @doc """
  Creates a new manifest with the given parameters.

  ## Examples

      iex> Anvil.Export.Manifest.new(%{
      ...>   queue_id: "queue_123",
      ...>   schema_version_id: "schema_v1",
      ...>   format: :csv,
      ...>   output_path: "/tmp/export.csv",
      ...>   row_count: 100,
      ...>   sha256_hash: "abc123",
      ...>   exported_at: ~U[2025-12-01 10:00:00Z],
      ...>   parameters: %{}
      ...> })
      %Anvil.Export.Manifest{...}
  """
  @spec new(map()) :: t()
  def new(params) do
    %__MODULE__{
      export_id: Map.get(params, :export_id, generate_export_id()),
      queue_id: Map.fetch!(params, :queue_id),
      schema_version_id: Map.fetch!(params, :schema_version_id),
      sample_version: Map.get(params, :sample_version),
      format: Map.fetch!(params, :format),
      output_path: Map.fetch!(params, :output_path),
      row_count: Map.fetch!(params, :row_count),
      sha256_hash: Map.fetch!(params, :sha256_hash),
      exported_at: Map.fetch!(params, :exported_at),
      parameters: Map.fetch!(params, :parameters),
      anvil_version: Map.get(params, :anvil_version, anvil_version()),
      schema_definition_hash: Map.get(params, :schema_definition_hash)
    }
  end

  @doc """
  Converts the manifest to a JSON string.

  ## Examples

      iex> manifest = %Anvil.Export.Manifest{...}
      iex> Anvil.Export.Manifest.to_json(manifest)
      "{\\"export_id\\": \\"exp_123\\", ...}"
  """
  @spec to_json(t()) :: String.t()
  def to_json(%__MODULE__{} = manifest) do
    manifest
    |> Map.from_struct()
    |> Jason.encode!(pretty: true)
  end

  @doc """
  Parses a JSON string into a manifest struct.

  ## Examples

      iex> json = ~s({"export_id": "exp_123", ...})
      iex> Anvil.Export.Manifest.from_json(json)
      {:ok, %Anvil.Export.Manifest{...}}
  """
  @spec from_json(String.t()) :: {:ok, t()} | {:error, term()}
  def from_json(json) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, data} ->
        manifest = %__MODULE__{
          export_id: data["export_id"],
          queue_id: data["queue_id"],
          schema_version_id: data["schema_version_id"],
          sample_version: data["sample_version"],
          format: String.to_existing_atom(data["format"]),
          output_path: data["output_path"],
          row_count: data["row_count"],
          sha256_hash: data["sha256_hash"],
          exported_at: parse_datetime(data["exported_at"]),
          parameters: data["parameters"] || %{},
          anvil_version: data["anvil_version"],
          schema_definition_hash: data["schema_definition_hash"]
        }

        {:ok, manifest}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Saves the manifest to a file.

  By default, saves to `<output_path>.manifest.json`.
  A custom path can be provided as the second argument.

  ## Examples

      iex> manifest = %Anvil.Export.Manifest{output_path: "/tmp/export.csv", ...}
      iex> Anvil.Export.Manifest.save(manifest)
      :ok
      # Creates /tmp/export.csv.manifest.json

      iex> Anvil.Export.Manifest.save(manifest, "/tmp/custom.json")
      :ok
      # Creates /tmp/custom.json
  """
  @spec save(t(), String.t() | nil) :: :ok | {:error, term()}
  def save(%__MODULE__{} = manifest, custom_path \\ nil) do
    path = custom_path || "#{manifest.output_path}.manifest.json"
    json = to_json(manifest)

    case File.write(path, json) do
      :ok -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Loads a manifest from a file.

  ## Examples

      iex> Anvil.Export.Manifest.load("/tmp/export.csv.manifest.json")
      {:ok, %Anvil.Export.Manifest{...}}
  """
  @spec load(String.t()) :: {:ok, t()} | {:error, term()}
  def load(path) do
    case File.read(path) do
      {:ok, json} -> from_json(json)
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Computes the SHA256 hash of a file.

  Uses streaming to handle large files without loading them into memory.

  ## Examples

      iex> Anvil.Export.Manifest.compute_file_hash("/tmp/export.csv")
      {:ok, "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"}
  """
  @spec compute_file_hash(String.t()) :: {:ok, String.t()} | {:error, term()}
  def compute_file_hash(path) do
    case File.exists?(path) do
      true ->
        hash =
          File.stream!(path, 2048, [])
          |> Enum.reduce(:crypto.hash_init(:sha256), fn chunk, acc ->
            :crypto.hash_update(acc, chunk)
          end)
          |> :crypto.hash_final()
          |> Base.encode16(case: :lower)

        {:ok, hash}

      false ->
        {:error, :enoent}
    end
  end

  # Private functions

  defp generate_export_id do
    "exp_" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
  end

  defp anvil_version do
    case Application.spec(:anvil, :vsn) do
      nil -> "0.1.0"
      vsn -> List.to_string(vsn)
    end
  end

  defp parse_datetime(nil), do: nil

  defp parse_datetime(string) when is_binary(string) do
    case DateTime.from_iso8601(string) do
      {:ok, datetime, _offset} -> datetime
      {:error, _} -> nil
    end
  end

  defp parse_datetime(%DateTime{} = datetime), do: datetime
end
