defmodule Anvil.Label do
  @moduledoc """
  Represents a label submitted by a labeler for an assignment.

  Labels are validated against the queue's schema before being stored.
  """

  @type t :: %__MODULE__{
          id: String.t(),
          assignment_id: String.t(),
          sample_id: String.t(),
          labeler_id: String.t(),
          values: map(),
          valid?: boolean(),
          errors: [map()],
          labeling_time_seconds: non_neg_integer() | nil,
          created_at: DateTime.t()
        }

  defstruct [
    :id,
    :assignment_id,
    :sample_id,
    :labeler_id,
    :values,
    :valid?,
    :errors,
    :labeling_time_seconds,
    :created_at
  ]

  @doc """
  Creates a new label.
  """
  @spec new(keyword()) :: t()
  def new(opts) do
    struct(
      __MODULE__,
      Keyword.merge(
        [
          id: generate_id(),
          errors: [],
          created_at: DateTime.utc_now()
        ],
        opts
      )
    )
  end

  defp generate_id do
    ("label_" <> :crypto.strong_rand_bytes(16)) |> Base.encode16(case: :lower)
  end
end
