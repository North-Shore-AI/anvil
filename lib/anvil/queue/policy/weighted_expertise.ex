defmodule Anvil.Queue.Policy.WeightedExpertise do
  @moduledoc """
  Weighted expertise assignment policy.

  Routes samples based on labeler skill levels and sample difficulty.
  Only assigns to labelers meeting minimum expertise threshold.
  """

  @behaviour Anvil.Queue.Policy

  @impl true
  def init(config) do
    {:ok,
     %{
       expertise_scores: config[:expertise_scores] || %{},
       min_expertise: config[:min_expertise] || 0.0,
       difficulty_field: config[:difficulty_field] || :difficulty
     }}
  end

  @impl true
  def next_assignment(state, labeler_id, available_samples) do
    labeler_expertise = Map.get(state.expertise_scores, labeler_id, 0.5)

    cond do
      labeler_expertise < state.min_expertise ->
        {:error, :labeler_below_threshold}

      available_samples == [] ->
        {:error, :no_samples_available}

      true ->
        # Select sample with appropriate difficulty
        # Prefer samples where labeler expertise is close to difficulty
        sample =
          available_samples
          |> Enum.map(fn s ->
            difficulty = get_difficulty(s, state.difficulty_field)
            # Score is better when expertise is closer to difficulty
            # but slightly favors easier samples
            score = labeler_expertise - difficulty
            {s, score}
          end)
          |> Enum.max_by(fn {_s, score} -> score end, fn -> {nil, 0} end)
          |> elem(0)

        if sample do
          {:ok, sample}
        else
          {:error, :no_samples_available}
        end
    end
  end

  @impl true
  def update_state(state, _sample) do
    state
  end

  defp get_difficulty(sample, field) do
    case Map.get(sample, field) do
      nil -> 0.5
      :easy -> 0.3
      :medium -> 0.5
      :hard -> 0.8
      value when is_number(value) -> value
      _ -> 0.5
    end
  end
end
