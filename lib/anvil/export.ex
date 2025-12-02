defmodule Anvil.Export do
  @moduledoc """
  Export labeled data in various formats.
  """

  alias Anvil.Export.{CSV, JSONL}

  @doc """
  Exports labels from a queue to a file.

  ## Options

    * `:format` - Export format (:csv or :jsonl)
    * `:path` - Output file path
    * `:filter` - Filter function to select labels
    * `:include_metadata` - Include labeling metadata (default: true)

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
end
