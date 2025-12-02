defmodule Anvil.Export.JSONL do
  @moduledoc """
  JSONL (JSON Lines) export functionality.
  """

  @doc """
  Exports labels to JSONL format.
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
