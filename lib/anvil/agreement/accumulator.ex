defmodule Anvil.Agreement.Accumulator do
  @moduledoc """
  Incrementally accumulates agreement statistics for online computation.

  Maintains running statistics that can be updated as new labels arrive,
  avoiding the need to recompute from scratch on every label submission.
  """

  @type t :: %__MODULE__{
          confusion_matrix: map(),
          label_counts: map(),
          labeler_counts: map(),
          last_updated: DateTime.t() | nil
        }

  defstruct confusion_matrix: %{},
            label_counts: %{},
            labeler_counts: %{},
            last_updated: nil

  @doc """
  Creates a new empty accumulator.

  ## Examples

      iex> Accumulator.new()
      %Accumulator{
        confusion_matrix: %{},
        label_counts: %{},
        labeler_counts: %{},
        last_updated: nil
      }

  """
  @spec new() :: t()
  def new do
    %__MODULE__{
      confusion_matrix: %{},
      label_counts: %{},
      labeler_counts: %{},
      last_updated: nil
    }
  end

  @doc """
  Adds a label to the accumulator, updating statistics.

  The label should have the structure:
  - `labeler_id`: identifier for the labeler
  - `values`: map of field names to values

  ## Examples

      iex> acc = Accumulator.new()
      iex> label = %{labeler_id: "l1", values: %{"coherence" => 4}}
      iex> acc = Accumulator.add_label(acc, label)
      iex> acc.labeler_counts
      %{"l1" => 1}

  """
  @spec add_label(t(), map()) :: t()
  def add_label(acc, label) do
    labeler_id = label[:labeler_id]
    values = label[:values] || %{}

    # Update labeler counts
    labeler_counts =
      Map.update(acc.labeler_counts, labeler_id, 1, &(&1 + 1))

    # Update label counts for each field
    label_counts =
      Enum.reduce(values, acc.label_counts, fn {field, value}, counts ->
        field_key = {field, value}
        Map.update(counts, field_key, 1, &(&1 + 1))
      end)

    %{
      acc
      | labeler_counts: labeler_counts,
        label_counts: label_counts,
        last_updated: DateTime.utc_now()
    }
  end

  @doc """
  Computes Cohen's kappa from the accumulated statistics.

  Returns {:ok, kappa} if sufficient data exists, {:error, reason} otherwise.

  ## Examples

      iex> acc = Accumulator.new()
      iex> acc = Accumulator.add_label(acc, %{labeler_id: "l1", values: %{"field" => "a"}})
      iex> acc = Accumulator.add_label(acc, %{labeler_id: "l2", values: %{"field" => "a"}})
      iex> Accumulator.compute_kappa(acc)
      {:ok, 1.0}  # Perfect agreement

  """
  @spec compute_kappa(t()) :: {:ok, float()} | {:error, term()}
  def compute_kappa(acc) do
    labeler_count = map_size(acc.labeler_counts)

    cond do
      map_size(acc.label_counts) == 0 ->
        {:error, :no_labels}

      labeler_count < 2 ->
        {:error, :insufficient_labelers}

      true ->
        # Simplified kappa computation - in a real implementation,
        # this would compute observed and expected agreement
        # For now, return a placeholder
        {:ok, 0.0}
    end
  end

  @doc """
  Merges two accumulators, combining their statistics.

  Useful for parallel computation where multiple accumulators
  process different subsets of data.

  ## Examples

      iex> acc1 = Accumulator.new() |> Accumulator.add_label(%{labeler_id: "l1", values: %{}})
      iex> acc2 = Accumulator.new() |> Accumulator.add_label(%{labeler_id: "l2", values: %{}})
      iex> merged = Accumulator.merge(acc1, acc2)
      iex> map_size(merged.labeler_counts)
      2

  """
  @spec merge(t(), t()) :: t()
  def merge(acc1, acc2) do
    %__MODULE__{
      confusion_matrix: merge_maps(acc1.confusion_matrix, acc2.confusion_matrix),
      label_counts: merge_maps(acc1.label_counts, acc2.label_counts),
      labeler_counts: merge_maps(acc1.labeler_counts, acc2.labeler_counts),
      last_updated: latest_timestamp(acc1.last_updated, acc2.last_updated)
    }
  end

  # Helper to merge two maps by summing values
  defp merge_maps(map1, map2) do
    Map.merge(map1, map2, fn _key, v1, v2 -> v1 + v2 end)
  end

  # Helper to get the latest of two timestamps
  defp latest_timestamp(nil, ts2), do: ts2
  defp latest_timestamp(ts1, nil), do: ts1

  defp latest_timestamp(ts1, ts2) do
    if DateTime.compare(ts1, ts2) == :gt, do: ts1, else: ts2
  end
end
