defmodule Anvil.Queue.Policy.Composite do
  @moduledoc """
  Composite policy for chaining multiple policies together.

  Allows combining multiple policies with filters and selectors.
  For example: filter by expertise, then select with redundancy logic.
  """

  @behaviour Anvil.Queue.Policy

  @impl true
  def init(config) do
    policies = config[:policies] || []

    # Initialize each policy
    policy_states =
      Enum.map(policies, fn
        {policy_type, policy_config} ->
          module = policy_module(policy_type)
          {:ok, state} = module.init(policy_config)
          {policy_type, module, state}

        policy_type when is_atom(policy_type) ->
          module = policy_module(policy_type)
          {:ok, state} = module.init(%{})
          {policy_type, module, state}
      end)

    {:ok, %{policies: policy_states}}
  end

  @impl true
  def next_assignment(state, labeler_id, available_samples) do
    # Apply each policy in sequence
    Enum.reduce_while(state.policies, {:ok, available_samples}, fn
      {_type, module, policy_state}, {:ok, samples} ->
        case module.next_assignment(policy_state, labeler_id, samples) do
          {:ok, sample} ->
            # Last policy wins - return the selected sample
            {:halt, {:ok, sample}}

          {:error, reason} ->
            # If a policy fails, stop the chain
            {:halt, {:error, reason}}
        end
    end)
  end

  @impl true
  def update_state(state, sample) do
    # Update all policy states
    updated_policies =
      Enum.map(state.policies, fn {type, module, policy_state} ->
        updated_policy_state = module.update_state(policy_state, sample)
        {type, module, updated_policy_state}
      end)

    %{state | policies: updated_policies}
  end

  defp policy_module(:round_robin), do: Anvil.Queue.Policy.RoundRobin
  defp policy_module(:random), do: Anvil.Queue.Policy.Random
  defp policy_module(:expertise), do: Anvil.Queue.Policy.WeightedExpertise
  defp policy_module(:weighted_expertise), do: Anvil.Queue.Policy.WeightedExpertise
  defp policy_module(:redundancy), do: Anvil.Queue.Policy.Redundancy
  defp policy_module(module) when is_atom(module), do: module
end
