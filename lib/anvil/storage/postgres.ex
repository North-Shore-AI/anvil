defmodule Anvil.Storage.Postgres do
  @moduledoc """
  Postgres storage adapter for Anvil.

  Implements the Anvil.Storage behaviour using Ecto and Postgres for
  durable, scalable storage with multi-tenancy support.
  """

  @behaviour Anvil.Storage

  alias Anvil.Schema.{Assignment, Label, SampleRef}
  alias Anvil.Telemetry
  import Ecto.Query

  @impl true
  def init(opts) do
    repo = Keyword.get(opts, :repo, Anvil.Repo)
    {:ok, %{repo: repo}}
  end

  @impl true
  def put_sample(state, sample) do
    Telemetry.span_storage_query("put_sample", %{}, fn ->
      attrs = %{
        sample_id: sample.id || sample[:id],
        metadata: Map.get(sample, :metadata, %{})
      }

      changeset = SampleRef.changeset(%SampleRef{}, attrs)

      case state.repo.insert(changeset, on_conflict: :nothing) do
        {:ok, _sample_ref} -> {{:ok, state}, %{}}
        {:error, changeset} -> {{:error, {:invalid_sample, changeset}}, %{error: :invalid_sample}}
      end
    end)
  end

  @impl true
  def get_sample(state, id) do
    case state.repo.get_by(SampleRef, sample_id: id) do
      nil -> {:error, :not_found}
      sample_ref -> {:ok, to_sample_map(sample_ref), state}
    end
  end

  @impl true
  def list_samples(state, filters) do
    Telemetry.span_storage_query("list_samples", %{filter_count: length(filters)}, fn ->
      query = from(s in SampleRef)

      query =
        Enum.reduce(filters, query, fn
          {:sample_ids, ids}, q ->
            where(q, [s], s.sample_id in ^ids)

          _, q ->
            q
        end)

      samples =
        state.repo.all(query)
        |> Enum.map(&to_sample_map/1)

      {{:ok, samples, state}, %{row_count: length(samples)}}
    end)
  end

  @impl true
  def put_assignment(state, assignment) do
    # Map the in-memory Assignment struct status to Ecto schema status
    ecto_status = map_status_to_ecto(assignment.status)

    attrs = %{
      id: parse_uuid(assignment.id),
      queue_id: assignment.queue_id,
      sample_id: assignment.sample_id,
      labeler_id: assignment.labeler_id,
      status: ecto_status,
      reserved_at: assignment.started_at,
      deadline: assignment.deadline,
      timeout_seconds: if(assignment.deadline, do: 3600, else: nil),
      skip_reason: assignment.skip_reason
    }

    changeset = Assignment.changeset(%Assignment{}, attrs)

    case state.repo.insert(changeset,
           on_conflict: {:replace_all_except, [:id, :inserted_at]},
           conflict_target: :id
         ) do
      {:ok, _assignment} -> {:ok, state}
      {:error, changeset} -> {:error, {:invalid_assignment, changeset}}
    end
  end

  @impl true
  def get_assignment(state, id) do
    case state.repo.get(Assignment, parse_uuid(id)) do
      nil -> {:error, :not_found}
      assignment -> {:ok, to_assignment_struct(assignment), state}
    end
  end

  @impl true
  def list_assignments(state, filters) do
    Telemetry.span_storage_query("list_assignments", %{filter_count: length(filters)}, fn ->
      query = from(a in Assignment)

      query =
        Enum.reduce(filters, query, fn
          {:queue_id, queue_id}, q ->
            where(q, [a], a.queue_id == ^queue_id)

          {:labeler_id, labeler_id}, q ->
            where(q, [a], a.labeler_id == ^labeler_id)

          {:status, status}, q ->
            where(q, [a], a.status == ^status)

          {:sample_id, sample_id}, q ->
            where(q, [a], a.sample_id == ^sample_id)

          _, q ->
            q
        end)

      assignments =
        state.repo.all(query)
        |> Enum.map(&to_assignment_struct/1)

      {{:ok, assignments, state}, %{row_count: length(assignments)}}
    end)
  end

  @impl true
  def put_label(state, label) do
    attrs = %{
      id: parse_uuid(label.id),
      assignment_id: parse_uuid(label.assignment_id),
      labeler_id: label.labeler_id,
      schema_version_id: get_schema_version_id(state, label),
      payload: label.values,
      submitted_at: label.created_at
    }

    changeset = Label.changeset(%Label{}, attrs)

    case state.repo.insert(changeset) do
      {:ok, _label} -> {:ok, state}
      {:error, changeset} -> {:error, {:invalid_label, changeset}}
    end
  end

  @impl true
  def get_label(state, id) do
    case state.repo.get(Label, parse_uuid(id)) do
      nil -> {:error, :not_found}
      label -> {:ok, to_label_struct(label), state}
    end
  end

  @impl true
  def list_labels(state, filters) do
    Telemetry.span_storage_query("list_labels", %{filter_count: length(filters)}, fn ->
      query = from(l in Label)

      query =
        Enum.reduce(filters, query, fn
          {:assignment_id, assignment_id}, q ->
            where(q, [l], l.assignment_id == ^assignment_id)

          {:labeler_id, labeler_id}, q ->
            where(q, [l], l.labeler_id == ^labeler_id)

          {:sample_id, sample_id}, q ->
            join(q, :inner, [l], a in Assignment, on: l.assignment_id == a.id)
            |> where([l, a], a.sample_id == ^sample_id)

          _, q ->
            q
        end)

      labels =
        state.repo.all(query)
        |> Enum.map(&to_label_struct/1)

      {{:ok, labels, state}, %{row_count: length(labels)}}
    end)
  end

  # Helper functions

  defp to_sample_map(sample_ref) do
    %{
      id: sample_ref.sample_id,
      metadata: sample_ref.metadata
    }
  end

  defp to_assignment_struct(assignment) do
    %Anvil.Assignment{
      id: assignment.id,
      queue_id: assignment.queue_id,
      sample_id: assignment.sample_id,
      labeler_id: assignment.labeler_id,
      status: map_status(assignment.status),
      deadline: assignment.deadline,
      attempts: assignment.requeue_attempts,
      label_id: nil,
      skip_reason: assignment.skip_reason,
      created_at: assignment.inserted_at,
      started_at: assignment.reserved_at,
      completed_at: if(assignment.status == :completed, do: assignment.updated_at, else: nil),
      expired_at: if(assignment.status == :timed_out, do: assignment.updated_at, else: nil),
      skipped_at: if(assignment.status == :skipped, do: assignment.updated_at, else: nil)
    }
  end

  defp to_label_struct(label) do
    %Anvil.Label{
      id: label.id,
      assignment_id: label.assignment_id,
      labeler_id: label.labeler_id,
      sample_id: get_sample_id_from_assignment(label.assignment_id),
      values: label.payload,
      valid?: true,
      errors: [],
      labeling_time_seconds: nil,
      created_at: label.inserted_at
    }
  end

  # Map Anvil.Assignment status to Ecto schema status
  defp map_status_to_ecto(:pending), do: :pending
  defp map_status_to_ecto(:in_progress), do: :reserved
  defp map_status_to_ecto(:completed), do: :completed
  defp map_status_to_ecto(:expired), do: :timed_out
  defp map_status_to_ecto(:skipped), do: :skipped
  defp map_status_to_ecto(status), do: status

  # Map Ecto schema status back to Anvil.Assignment status
  defp map_status(:pending), do: :pending
  defp map_status(:reserved), do: :in_progress
  defp map_status(:completed), do: :completed
  defp map_status(:timed_out), do: :expired
  defp map_status(:skipped), do: :skipped
  defp map_status(:requeued), do: :pending
  defp map_status(status), do: status

  defp parse_uuid(id) when is_binary(id) do
    case Ecto.UUID.cast(id) do
      {:ok, uuid} -> uuid
      :error -> id
    end
  end

  defp parse_uuid(id), do: id

  defp get_schema_version_id(state, label) do
    # Fetch the schema_version_id from the queue associated with the assignment
    query =
      from(a in Assignment,
        join: q in Anvil.Schema.Queue,
        on: a.queue_id == q.id,
        where: a.id == ^parse_uuid(label.assignment_id),
        select: q.schema_version_id
      )

    case state.repo.one(query) do
      nil -> raise "Assignment #{label.assignment_id} not found or has no associated queue"
      schema_version_id -> schema_version_id
    end
  end

  defp get_sample_id_from_assignment(_assignment_id) do
    # For now, return nil. In a real implementation, this would
    # fetch the sample_id from the assignment
    nil
  end
end
