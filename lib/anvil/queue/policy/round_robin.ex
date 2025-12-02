defmodule Anvil.Queue.Policy.RoundRobin do
  @moduledoc """
  Round-robin assignment policy.

  Cycles through samples in creation order, ensuring fair distribution.
  """

  @behaviour Anvil.Queue.Policy

  @impl true
  def init(_config) do
    {:ok, %{last_index: 0}}
  end

  @impl true
  def next_assignment(state, _labeler_id, available_samples) do
    case available_samples do
      [] ->
        {:error, :no_samples_available}

      samples ->
        # Calculate the next index, wrapping around if necessary
        last_index = Map.get(state, :last_index, 0)
        index = rem(last_index, length(samples))
        sample = Enum.at(samples, index)
        {:ok, sample}
    end
  end

  @impl true
  def update_state(state, _sample) do
    last_index = Map.get(state, :last_index, 0)
    Map.put(state, :last_index, last_index + 1)
  end
end
