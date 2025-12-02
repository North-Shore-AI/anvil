defmodule Anvil.Export.CSV do
  @moduledoc """
  CSV export functionality.
  """

  @doc """
  Exports labels to CSV format.
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
    if String.contains?(value, [",", "\"", "\n"]) do
      "\"" <> String.replace(value, "\"", "\"\"") <> "\""
    else
      value
    end
  end

  defp escape_csv_value(value), do: to_string(value)

  defp ensure_directory_exists(path) do
    dir = Path.dirname(path)

    case File.mkdir_p(dir) do
      :ok -> :ok
      {:error, reason} -> {:error, {:mkdir_failed, reason}}
    end
  end
end
