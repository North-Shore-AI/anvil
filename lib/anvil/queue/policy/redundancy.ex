defmodule Anvil.Queue.Policy.Redundancy do
  @moduledoc """
  Redundancy assignment policy.

  Ensures k independent labels per sample for inter-rater reliability.
  Tracks label counts and prioritizes under-labeled samples.
  """

  @behaviour Anvil.Queue.Policy

  @impl true
  def init(config) do
    {:ok,
     %{
       labels_per_sample: config[:labels_per_sample] || 3,
       allow_same_labeler: config[:allow_same_labeler] || false,
       label_counts: config[:label_counts] || %{}
     }}
  end

  @impl true
  def next_assignment(state, labeler_id, available_samples) do
    target = state.labels_per_sample

    # Filter samples that need more labels
    candidates =
      available_samples
      |> Enum.filter(fn sample ->
        count = Map.get(state.label_counts, sample.id, 0)
        count < target
      end)

    # If not allowing same labeler, filter out samples already labeled by this labeler
    candidates =
      if Map.get(state, :allow_same_labeler, false) do
        candidates
      else
        Enum.filter(candidates, fn sample ->
          labelers = Map.get(state.label_counts, "#{sample.id}_labelers", [])
          labeler_id not in labelers
        end)
      end

    case candidates do
      [] ->
        {:error, :no_samples_available}

      samples ->
        # Prioritize samples with fewest labels
        sample =
          samples
          |> Enum.min_by(fn s ->
            Map.get(state.label_counts, s.id, 0)
          end)

        {:ok, sample}
    end
  end

  @impl true
  def update_state(state, _sample) do
    # No state updates needed - the queue tracks label counts via storage
    state
  end

  @doc """
  Updates the label count for a sample with a specific labeler.
  """
  def record_label(state, sample_id, labeler_id) do
    count = Map.get(state.label_counts, sample_id, 0)
    labelers = Map.get(state.label_counts, "#{sample_id}_labelers", [])

    label_counts =
      state.label_counts
      |> Map.put(sample_id, count + 1)
      |> Map.put("#{sample_id}_labelers", [labeler_id | labelers])

    %{state | label_counts: label_counts}
  end
end
