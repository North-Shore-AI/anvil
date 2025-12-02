defmodule Anvil.Queue.Policy do
  @moduledoc """
  Behaviour for queue assignment policies.

  Policies control how samples are assigned to labelers.
  """

  @callback next_assignment(
              queue_state :: map(),
              labeler_id :: String.t(),
              available_samples :: [map()]
            ) :: {:ok, map()} | {:error, atom()}

  @doc """
  Returns the next sample for a labeler based on the policy.
  """
  @spec next_sample(atom() | module(), map(), String.t(), [map()]) ::
          {:ok, map()} | {:error, atom()}
  def next_sample(:round_robin, state, _labeler_id, available_samples) do
    round_robin_next(state, available_samples)
  end

  def next_sample(:random, _state, _labeler_id, available_samples) do
    random_next(available_samples)
  end

  def next_sample(:expertise, state, labeler_id, available_samples) do
    expertise_next(state, labeler_id, available_samples)
  end

  def next_sample({module, _config}, state, labeler_id, available_samples) do
    module.next_assignment(state, labeler_id, available_samples)
  end

  # Round-robin implementation
  defp round_robin_next(_state, []), do: {:error, :no_samples_available}

  defp round_robin_next(_state, available_samples) do
    # Just return the first available sample
    # The queue manages what's "available" for each labeler
    {:ok, hd(available_samples)}
  end

  # Random implementation
  defp random_next([]), do: {:error, :no_samples_available}

  defp random_next(available_samples) do
    sample = Enum.random(available_samples)
    {:ok, sample}
  end

  # Expertise-based implementation
  defp expertise_next(_state, _labeler_id, []), do: {:error, :no_samples_available}

  defp expertise_next(state, labeler_id, available_samples) do
    config = Map.get(state, :policy_config, %{})
    expertise_scores = Map.get(config, :expertise_scores, %{})
    min_expertise = Map.get(config, :min_expertise, 0.0)
    sample_difficulty = Map.get(config, :sample_difficulty, %{})

    labeler_expertise = Map.get(expertise_scores, labeler_id, 0.5)

    if labeler_expertise < min_expertise do
      {:error, :insufficient_expertise}
    else
      # Select sample with appropriate difficulty
      sample =
        available_samples
        |> Enum.map(fn s ->
          difficulty = Map.get(sample_difficulty, s.id, 0.5)
          score = labeler_expertise - difficulty
          {s, score}
        end)
        |> Enum.max_by(fn {_s, score} -> score end)
        |> elem(0)

      {:ok, sample}
    end
  end

  @doc """
  Updates the policy state after an assignment.
  """
  @spec update_state(atom() | module(), map(), map()) :: map()
  def update_state(:round_robin, state, _sample) do
    Map.update(state, :round_robin_index, 0, &(&1 + 1))
  end

  def update_state(_policy, state, _sample), do: state
end
