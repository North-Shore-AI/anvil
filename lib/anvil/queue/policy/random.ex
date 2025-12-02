defmodule Anvil.Queue.Policy.Random do
  @moduledoc """
  Random assignment policy.

  Selects a random sample from available samples.
  """

  @behaviour Anvil.Queue.Policy

  @impl true
  def init(_config) do
    {:ok, %{}}
  end

  @impl true
  def next_assignment(_state, _labeler_id, available_samples) do
    case available_samples do
      [] ->
        {:error, :no_samples_available}

      samples ->
        sample = Enum.random(samples)
        {:ok, sample}
    end
  end

  @impl true
  def update_state(state, _sample) do
    state
  end
end
