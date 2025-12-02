defmodule Anvil.Queue.Policy do
  @moduledoc """
  Behaviour for queue assignment policies.

  Policies control how samples are assigned to labelers.
  """

  @type policy_state :: map()
  @type sample :: map()

  @callback init(config :: map()) :: {:ok, policy_state()}

  @callback next_assignment(
              policy_state(),
              labeler_id :: String.t(),
              available_samples :: [sample()]
            ) :: {:ok, sample()} | {:error, atom()}

  @callback update_state(policy_state(), sample()) :: policy_state()

  @doc """
  Initializes policy state based on the policy type.

  Dispatches to the appropriate policy module.
  """
  @spec init_policy(atom() | module(), map()) :: {:ok, map()}
  def init_policy(:round_robin, config) do
    Anvil.Queue.Policy.RoundRobin.init(config)
  end

  def init_policy(:random, config) do
    Anvil.Queue.Policy.Random.init(config)
  end

  def init_policy(:expertise, config) do
    Anvil.Queue.Policy.WeightedExpertise.init(config)
  end

  def init_policy(:redundancy, config) do
    Anvil.Queue.Policy.Redundancy.init(config)
  end

  def init_policy(module, config) when is_atom(module) do
    module.init(config)
  end

  @doc """
  Returns the next sample for a labeler based on the policy.

  Dispatches to the appropriate policy module.
  """
  @spec next_sample(atom() | module(), map(), String.t(), [map()]) ::
          {:ok, map()} | {:error, atom()}
  def next_sample(:round_robin, state, labeler_id, available_samples) do
    Anvil.Queue.Policy.RoundRobin.next_assignment(state, labeler_id, available_samples)
  end

  def next_sample(:random, state, labeler_id, available_samples) do
    Anvil.Queue.Policy.Random.next_assignment(state, labeler_id, available_samples)
  end

  def next_sample(:expertise, state, labeler_id, available_samples) do
    Anvil.Queue.Policy.WeightedExpertise.next_assignment(state, labeler_id, available_samples)
  end

  def next_sample(:redundancy, state, labeler_id, available_samples) do
    Anvil.Queue.Policy.Redundancy.next_assignment(state, labeler_id, available_samples)
  end

  def next_sample({module, _config}, state, labeler_id, available_samples)
      when is_atom(module) do
    module.next_assignment(state, labeler_id, available_samples)
  end

  def next_sample(module, state, labeler_id, available_samples) when is_atom(module) do
    module.next_assignment(state, labeler_id, available_samples)
  end

  @doc """
  Updates the policy state after an assignment.
  """
  @spec update_state(atom() | module(), map(), map()) :: map()
  def update_state(:round_robin, state, sample) do
    Anvil.Queue.Policy.RoundRobin.update_state(state, sample)
  end

  def update_state(:random, state, sample) do
    Anvil.Queue.Policy.Random.update_state(state, sample)
  end

  def update_state(:expertise, state, sample) do
    Anvil.Queue.Policy.WeightedExpertise.update_state(state, sample)
  end

  def update_state(:redundancy, state, sample) do
    Anvil.Queue.Policy.Redundancy.update_state(state, sample)
  end

  def update_state({module, _config}, state, sample) when is_atom(module) do
    module.update_state(state, sample)
  end

  def update_state(module, state, sample) when is_atom(module) do
    module.update_state(state, sample)
  end

  def update_state(_policy, state, _sample), do: state
end
