defmodule Anvil.Assignment do
  @moduledoc """
  Represents a labeling task assigned to a specific labeler.

  Tracks the lifecycle of an assignment from creation through completion,
  expiration, or skipping.
  """

  @type status :: :pending | :in_progress | :completed | :expired | :skipped

  @type t :: %__MODULE__{
          id: String.t(),
          sample_id: String.t(),
          labeler_id: String.t(),
          queue_id: String.t(),
          status: status(),
          deadline: DateTime.t() | nil,
          attempts: non_neg_integer(),
          label_id: String.t() | nil,
          skip_reason: String.t() | nil,
          created_at: DateTime.t(),
          started_at: DateTime.t() | nil,
          completed_at: DateTime.t() | nil,
          expired_at: DateTime.t() | nil,
          skipped_at: DateTime.t() | nil
        }

  defstruct [
    :id,
    :sample_id,
    :labeler_id,
    :queue_id,
    :status,
    :deadline,
    :attempts,
    :label_id,
    :skip_reason,
    :created_at,
    :started_at,
    :completed_at,
    :expired_at,
    :skipped_at
  ]

  @doc """
  Creates a new pending assignment.
  """
  @spec new(keyword()) :: t()
  def new(opts) do
    struct(
      __MODULE__,
      Keyword.merge(
        [
          id: generate_id(),
          status: :pending,
          attempts: 0,
          created_at: DateTime.utc_now()
        ],
        opts
      )
    )
  end

  @doc """
  Starts an assignment, transitioning from :pending to :in_progress.
  """
  @spec start(t(), pos_integer()) :: {:ok, t()} | {:error, term()}
  def start(%__MODULE__{status: :pending} = assignment, timeout_seconds) do
    now = DateTime.utc_now()
    deadline = DateTime.add(now, timeout_seconds, :second)

    {:ok,
     %{
       assignment
       | status: :in_progress,
         started_at: now,
         deadline: deadline,
         attempts: assignment.attempts + 1
     }}
  end

  def start(%__MODULE__{status: status}, _timeout) do
    {:error, {:invalid_transition, status, :in_progress}}
  end

  @doc """
  Completes an assignment with a label ID.
  """
  @spec complete(t(), String.t()) :: {:ok, t()} | {:error, term()}
  def complete(%__MODULE__{status: :in_progress} = assignment, label_id) do
    {:ok,
     %{
       assignment
       | status: :completed,
         completed_at: DateTime.utc_now(),
         label_id: label_id
     }}
  end

  def complete(%__MODULE__{status: status}, _label_id) do
    {:error, {:invalid_transition, status, :completed}}
  end

  @doc """
  Skips an assignment with an optional reason.
  """
  @spec skip(t(), String.t() | nil) :: {:ok, t()} | {:error, term()}
  def skip(assignment, reason \\ nil)

  def skip(%__MODULE__{status: :pending} = assignment, reason) do
    {:ok,
     %{
       assignment
       | status: :skipped,
         skipped_at: DateTime.utc_now(),
         skip_reason: reason
     }}
  end

  def skip(%__MODULE__{status: :in_progress} = assignment, reason) do
    {:ok,
     %{
       assignment
       | status: :skipped,
         skipped_at: DateTime.utc_now(),
         skip_reason: reason
     }}
  end

  def skip(%__MODULE__{status: status}, _reason) do
    {:error, {:invalid_transition, status, :skipped}}
  end

  @doc """
  Expires an assignment that has passed its deadline.
  """
  @spec expire(t()) :: {:ok, t()} | {:error, term()}
  def expire(%__MODULE__{status: status} = assignment)
      when status in [:pending, :in_progress] do
    {:ok, %{assignment | status: :expired, expired_at: DateTime.utc_now()}}
  end

  def expire(%__MODULE__{status: status}) do
    {:error, {:invalid_transition, status, :expired}}
  end

  @doc """
  Checks if the assignment is past its deadline.
  """
  @spec past_deadline?(t()) :: boolean()
  def past_deadline?(%__MODULE__{deadline: nil}), do: false

  def past_deadline?(%__MODULE__{deadline: deadline}) do
    DateTime.compare(DateTime.utc_now(), deadline) == :gt
  end

  @doc """
  Returns the labeling time in seconds, or nil if not completed.
  """
  @spec labeling_time_seconds(t()) :: non_neg_integer() | nil
  def labeling_time_seconds(%__MODULE__{started_at: nil}), do: nil
  def labeling_time_seconds(%__MODULE__{completed_at: nil}), do: nil

  def labeling_time_seconds(%__MODULE__{started_at: started, completed_at: completed}) do
    DateTime.diff(completed, started, :second)
  end

  defp generate_id do
    Ecto.UUID.generate()
  end
end
