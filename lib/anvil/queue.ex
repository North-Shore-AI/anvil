defmodule Anvil.Queue do
  @moduledoc """
  GenServer that manages a labeling queue.

  Handles sample assignment, label submission, and queue state management.
  """

  use GenServer
  require Logger

  alias Anvil.{Assignment, Label, Schema, Storage, Telemetry}
  alias Anvil.Queue.Policy

  defstruct [
    :queue_id,
    :schema,
    :policy,
    :policy_config,
    :storage_module,
    :storage_state,
    :assignment_timeout,
    :labels_per_sample,
    :labelers,
    :policy_state
  ]

  # Client API

  @doc """
  Starts a queue process.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    queue_id = Keyword.fetch!(opts, :queue_id)
    GenServer.start_link(__MODULE__, opts, name: via_tuple(queue_id))
  end

  @doc """
  Adds samples to the queue.
  """
  @spec add_samples(pid() | atom(), [map()]) :: :ok | {:error, term()}
  def add_samples(queue, samples) do
    GenServer.call(queue, {:add_samples, samples})
  end

  @doc """
  Adds labelers to the queue.
  """
  @spec add_labelers(pid() | atom(), [String.t()]) :: :ok
  def add_labelers(queue, labelers) do
    GenServer.call(queue, {:add_labelers, labelers})
  end

  @doc """
  Gets the next assignment for a labeler.
  """
  @spec get_next_assignment(pid() | atom(), String.t()) ::
          {:ok, Assignment.t()} | {:error, term()}
  def get_next_assignment(queue, labeler_id) do
    GenServer.call(queue, {:get_next_assignment, labeler_id})
  end

  @doc """
  Starts an assignment.
  """
  @spec start_assignment(pid() | atom(), String.t()) ::
          {:ok, Assignment.t()} | {:error, term()}
  def start_assignment(queue, assignment_id) do
    GenServer.call(queue, {:start_assignment, assignment_id})
  end

  @doc """
  Submits a label for an assignment.
  """
  @spec submit_label(pid() | atom(), String.t(), map()) ::
          {:ok, Label.t()} | {:error, term()}
  def submit_label(queue, assignment_id, values) do
    GenServer.call(queue, {:submit_label, assignment_id, values})
  end

  @doc """
  Skips an assignment.
  """
  @spec skip_assignment(pid() | atom(), String.t(), keyword()) ::
          {:ok, Assignment.t()} | {:error, term()}
  def skip_assignment(queue, assignment_id, opts \\ []) do
    reason = Keyword.get(opts, :reason)
    GenServer.call(queue, {:skip_assignment, assignment_id, reason})
  end

  @doc """
  Gets all labels for the queue.
  """
  @spec get_labels(pid() | atom(), keyword()) :: [Label.t()]
  def get_labels(queue, filters \\ []) do
    GenServer.call(queue, {:get_labels, filters})
  end

  @doc """
  Gets all assignments for the queue.
  """
  @spec get_assignments(pid() | atom(), keyword()) :: [Assignment.t()]
  def get_assignments(queue, filters \\ []) do
    GenServer.call(queue, {:get_assignments, filters})
  end

  # Server Callbacks

  @impl true
  def init(opts) do
    queue_id = Keyword.fetch!(opts, :queue_id)
    schema = Keyword.fetch!(opts, :schema)
    labels_per_sample = Keyword.get(opts, :labels_per_sample, 1)
    # Use redundancy policy by default when labels_per_sample > 1
    default_policy = if labels_per_sample > 1, do: :redundancy, else: :round_robin
    policy = Keyword.get(opts, :policy, default_policy)
    base_policy_config = Keyword.get(opts, :policy_config, %{})
    # Merge labels_per_sample into policy_config for redundancy policy
    policy_config = Map.merge(base_policy_config, %{labels_per_sample: labels_per_sample})
    storage_module = Keyword.get(opts, :storage, Storage.ETS)
    assignment_timeout = Keyword.get(opts, :assignment_timeout, 3600)

    {:ok, storage_state} = storage_module.init(queue_id: queue_id)
    {:ok, policy_state} = Policy.init_policy(policy, policy_config)

    state = %__MODULE__{
      queue_id: queue_id,
      schema: schema,
      policy: policy,
      policy_config: policy_config,
      storage_module: storage_module,
      storage_state: storage_state,
      assignment_timeout: assignment_timeout,
      labels_per_sample: labels_per_sample,
      labelers: [],
      policy_state: policy_state
    }

    # Emit queue created telemetry event
    Telemetry.emit_queue_created(queue_id, %{
      policy_type: policy,
      labels_per_sample: labels_per_sample
    })

    {:ok, state}
  end

  @impl true
  def handle_call({:add_samples, samples}, _from, state) do
    result =
      Enum.reduce_while(samples, {:ok, state}, fn sample, {:ok, acc_state} ->
        case state.storage_module.put_sample(acc_state.storage_state, sample) do
          {:ok, new_storage_state} ->
            {:cont, {:ok, %{acc_state | storage_state: new_storage_state}}}

          {:error, reason} ->
            {:halt, {:error, reason}}
        end
      end)

    case result do
      {:ok, new_state} -> {:reply, :ok, new_state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_call({:add_labelers, labelers}, _from, state) do
    new_labelers = Enum.uniq(state.labelers ++ labelers)
    {:reply, :ok, %{state | labelers: new_labelers}}
  end

  @impl true
  def handle_call({:get_next_assignment, labeler_id}, _from, state) do
    with {:ok, available_samples} <- get_available_samples(state, labeler_id),
         {:ok, sample} <-
           Policy.next_sample(state.policy, state.policy_state, labeler_id, available_samples) do
      # Wrap assignment dispatch in telemetry span
      Telemetry.span_assignment_dispatch(
        %{queue_id: state.queue_id, labeler_id: labeler_id, policy_type: state.policy},
        fn ->
          assignment =
            Assignment.new(
              sample_id: sample.id,
              labeler_id: labeler_id,
              queue_id: state.queue_id
            )

          {:ok, new_storage_state} =
            state.storage_module.put_assignment(state.storage_state, assignment)

          new_policy_state = Policy.update_state(state.policy, state.policy_state, sample)

          new_state = %{
            state
            | storage_state: new_storage_state,
              policy_state: new_policy_state
          }

          # Emit assignment created event
          Telemetry.emit_assignment_created(assignment.id, %{
            queue_id: state.queue_id,
            labeler_id: labeler_id,
            sample_id: sample.id
          })

          {{:reply, {:ok, assignment}, new_state},
           %{sample_id: sample.id, eligible_samples: length(available_samples)}}
        end
      )
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_call({:start_assignment, assignment_id}, _from, state) do
    with {:ok, assignment, storage_state} <-
           state.storage_module.get_assignment(state.storage_state, assignment_id),
         {:ok, updated_assignment} <- Assignment.start(assignment, state.assignment_timeout),
         {:ok, new_storage_state} <-
           state.storage_module.put_assignment(storage_state, updated_assignment) do
      {:reply, {:ok, updated_assignment}, %{state | storage_state: new_storage_state}}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_call({:submit_label, assignment_id, values}, _from, state) do
    # Wrap label submission in telemetry span
    Telemetry.span_label_submit(
      %{assignment_id: assignment_id, queue_id: state.queue_id},
      fn ->
        with {:ok, assignment, storage_state} <-
               state.storage_module.get_assignment(state.storage_state, assignment_id),
             {:ok, validated_values} <- Schema.validate(state.schema, values),
             labeling_time <- Assignment.labeling_time_seconds(assignment),
             label <- create_label(assignment, validated_values, labeling_time),
             {:ok, storage_state} <- state.storage_module.put_label(storage_state, label),
             {:ok, completed_assignment} <- Assignment.complete(assignment, label.id),
             {:ok, new_storage_state} <-
               state.storage_module.put_assignment(storage_state, completed_assignment) do
          # Emit assignment completed event
          Telemetry.emit_assignment_completed(assignment_id, %{
            queue_id: state.queue_id,
            labeler_id: assignment.labeler_id,
            labeling_time_seconds: labeling_time
          })

          {{:reply, {:ok, label}, %{state | storage_state: new_storage_state}},
           %{validation_errors: 0}}
        else
          {:error, errors} when is_list(errors) ->
            # Emit validation failed event
            Telemetry.emit_label_validation_failed(assignment_id, errors, %{
              queue_id: state.queue_id
            })

            {{:reply, {:error, {:validation_failed, errors}}, state},
             %{validation_errors: length(errors)}}

          {:error, reason} ->
            {{:reply, {:error, reason}, state}, %{error: reason}}
        end
      end
    )
  end

  @impl true
  def handle_call({:skip_assignment, assignment_id, reason}, _from, state) do
    with {:ok, assignment, storage_state} <-
           state.storage_module.get_assignment(state.storage_state, assignment_id),
         {:ok, skipped_assignment} <- Assignment.skip(assignment, reason),
         {:ok, new_storage_state} <-
           state.storage_module.put_assignment(storage_state, skipped_assignment) do
      {:reply, {:ok, skipped_assignment}, %{state | storage_state: new_storage_state}}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_call({:get_labels, filters}, _from, state) do
    {:ok, labels, _storage_state} = state.storage_module.list_labels(state.storage_state, filters)
    {:reply, labels, state}
  end

  @impl true
  def handle_call({:get_assignments, filters}, _from, state) do
    {:ok, assignments, _storage_state} =
      state.storage_module.list_assignments(state.storage_state, filters)

    {:reply, assignments, state}
  end

  # Private Functions

  defp get_available_samples(state, labeler_id) do
    {:ok, all_samples, _} = state.storage_module.list_samples(state.storage_state, [])
    {:ok, assignments, _} = state.storage_module.list_assignments(state.storage_state, [])

    # Count labels per sample
    label_counts =
      assignments
      |> Enum.filter(&(&1.status == :completed))
      |> Enum.frequencies_by(& &1.sample_id)

    # Get samples that haven't been assigned to this labeler yet
    assigned_to_labeler =
      assignments
      |> Enum.filter(&(&1.labeler_id == labeler_id))
      |> Enum.map(& &1.sample_id)
      |> MapSet.new()

    available =
      all_samples
      |> Enum.reject(fn sample ->
        label_count = Map.get(label_counts, sample.id, 0)
        label_count >= state.labels_per_sample || MapSet.member?(assigned_to_labeler, sample.id)
      end)

    {:ok, available}
  end

  defp create_label(assignment, values, labeling_time) do
    Label.new(
      assignment_id: assignment.id,
      sample_id: assignment.sample_id,
      labeler_id: assignment.labeler_id,
      values: values,
      valid?: true,
      labeling_time_seconds: labeling_time
    )
  end

  defp via_tuple(queue_id) do
    {:via, Registry, {Anvil.Registry, queue_id}}
  end
end
