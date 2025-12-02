defmodule Anvil.Storage.ETS do
  @moduledoc """
  ETS-based storage implementation for testing and development.
  """

  @behaviour Anvil.Storage

  @impl true
  def init(opts) do
    queue_id = Keyword.fetch!(opts, :queue_id)

    state = %{
      queue_id: queue_id,
      assignments: :ets.new(:"assignments_#{queue_id}", [:set, :public]),
      labels: :ets.new(:"labels_#{queue_id}", [:set, :public]),
      samples: :ets.new(:"samples_#{queue_id}", [:set, :public])
    }

    {:ok, state}
  end

  @impl true
  def put_assignment(state, assignment) do
    :ets.insert(state.assignments, {assignment.id, assignment})
    {:ok, state}
  end

  @impl true
  def get_assignment(state, id) do
    case :ets.lookup(state.assignments, id) do
      [{^id, assignment}] -> {:ok, assignment, state}
      [] -> {:error, :not_found}
    end
  end

  @impl true
  def list_assignments(state, filters) do
    assignments =
      state.assignments
      |> :ets.tab2list()
      |> Enum.map(&elem(&1, 1))
      |> apply_filters(filters)

    {:ok, assignments, state}
  end

  @impl true
  def put_label(state, label) do
    :ets.insert(state.labels, {label.id, label})
    {:ok, state}
  end

  @impl true
  def get_label(state, id) do
    case :ets.lookup(state.labels, id) do
      [{^id, label}] -> {:ok, label, state}
      [] -> {:error, :not_found}
    end
  end

  @impl true
  def list_labels(state, filters) do
    labels =
      state.labels
      |> :ets.tab2list()
      |> Enum.map(&elem(&1, 1))
      |> apply_filters(filters)

    {:ok, labels, state}
  end

  @impl true
  def put_sample(state, sample) do
    :ets.insert(state.samples, {sample.id, sample})
    {:ok, state}
  end

  @impl true
  def get_sample(state, id) do
    case :ets.lookup(state.samples, id) do
      [{^id, sample}] -> {:ok, sample, state}
      [] -> {:error, :not_found}
    end
  end

  @impl true
  def list_samples(state, filters) do
    samples =
      state.samples
      |> :ets.tab2list()
      |> Enum.map(&elem(&1, 1))
      |> apply_filters(filters)

    {:ok, samples, state}
  end

  defp apply_filters(items, []), do: items

  defp apply_filters(items, [{:status, status} | rest]) when is_atom(status) do
    items
    |> Enum.filter(&(&1.status == status))
    |> apply_filters(rest)
  end

  defp apply_filters(items, [{:status, statuses} | rest]) when is_list(statuses) do
    items
    |> Enum.filter(&(&1.status in statuses))
    |> apply_filters(rest)
  end

  defp apply_filters(items, [{:sample_id, sample_id} | rest]) do
    items
    |> Enum.filter(&(&1.sample_id == sample_id))
    |> apply_filters(rest)
  end

  defp apply_filters(items, [{:labeler_id, labeler_id} | rest]) do
    items
    |> Enum.filter(&(&1.labeler_id == labeler_id))
    |> apply_filters(rest)
  end

  defp apply_filters(items, [{:valid?, valid?} | rest]) do
    items
    |> Enum.filter(&(&1.valid? == valid?))
    |> apply_filters(rest)
  end

  defp apply_filters(items, [_ | rest]), do: apply_filters(items, rest)
end
