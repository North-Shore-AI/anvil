defmodule Anvil.Schema.Assignment do
  @moduledoc """
  Ecto schema for labeling assignments.

  Tracks the lifecycle of a sample assigned to a labeler, including
  status transitions, deadlines, and optimistic locking.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{
          id: Ecto.UUID.t() | nil,
          sample_id: Ecto.UUID.t() | nil,
          status: :pending | :reserved | :completed | :timed_out | :requeued | :skipped,
          reserved_at: DateTime.t() | nil,
          deadline: DateTime.t() | nil,
          timeout_seconds: integer() | nil,
          version: integer(),
          requeue_attempts: integer(),
          requeue_delay_until: DateTime.t() | nil,
          skip_reason: String.t() | nil,
          queue_id: Ecto.UUID.t() | nil,
          labeler_id: Ecto.UUID.t() | nil,
          queue: Anvil.Schema.Queue.t() | Ecto.Association.NotLoaded.t() | nil,
          labeler: Anvil.Schema.Labeler.t() | Ecto.Association.NotLoaded.t() | nil,
          labels: [Anvil.Schema.Label.t()] | Ecto.Association.NotLoaded.t(),
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "assignments" do
    field(:sample_id, :binary_id)

    field(:status, Ecto.Enum,
      values: [:pending, :reserved, :completed, :timed_out, :requeued, :skipped],
      default: :pending
    )

    field(:reserved_at, :utc_datetime)
    field(:deadline, :utc_datetime)
    field(:timeout_seconds, :integer)
    field(:version, :integer, default: 1)
    field(:requeue_attempts, :integer, default: 0)
    field(:requeue_delay_until, :utc_datetime)
    field(:skip_reason, :string)

    belongs_to(:queue, Anvil.Schema.Queue)
    belongs_to(:labeler, Anvil.Schema.Labeler)
    has_many(:labels, Anvil.Schema.Label)

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(assignment, attrs) do
    assignment
    |> cast(attrs, [
      :id,
      :queue_id,
      :sample_id,
      :labeler_id,
      :status,
      :reserved_at,
      :deadline,
      :timeout_seconds,
      :requeue_attempts,
      :requeue_delay_until,
      :skip_reason
    ])
    |> validate_required([:queue_id, :sample_id, :labeler_id])
    |> foreign_key_constraint(:queue_id)
    |> foreign_key_constraint(:labeler_id)
    |> foreign_key_constraint(:sample_id)
    |> optimistic_lock(:version)
  end

  @doc """
  Reserves an assignment for a labeler with a timeout.
  """
  def reserve(assignment, timeout_seconds) do
    now = DateTime.utc_now()
    deadline = DateTime.add(now, timeout_seconds, :second)

    assignment
    |> change(%{
      status: :reserved,
      reserved_at: now,
      deadline: deadline,
      timeout_seconds: timeout_seconds
    })
  end

  @doc """
  Marks an assignment as completed.
  """
  def complete(assignment) do
    assignment
    |> change(%{status: :completed})
  end

  @doc """
  Marks an assignment as timed out.
  """
  def timeout(assignment) do
    assignment
    |> change(%{status: :timed_out})
  end

  @doc """
  Requeues an assignment after timeout.
  """
  def requeue(assignment, delay_seconds \\ 0) do
    requeue_delay_until =
      if delay_seconds > 0 do
        DateTime.add(DateTime.utc_now(), delay_seconds, :second)
      else
        nil
      end

    assignment
    |> change(%{
      status: :requeued,
      requeue_attempts: (assignment.requeue_attempts || 0) + 1,
      requeue_delay_until: requeue_delay_until,
      reserved_at: nil,
      deadline: nil
    })
  end

  @doc """
  Marks an assignment as skipped.
  """
  def skip(assignment, reason \\ nil) do
    assignment
    |> change(%{
      status: :skipped,
      skip_reason: reason
    })
  end
end
