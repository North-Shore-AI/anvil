defmodule Anvil do
  @moduledoc """
  Labeling queue library for managing human labeling workflows.

  Anvil is a domain-agnostic system for orchestrating human annotation tasks
  across any sample type - images, text, audio, video, or custom data structures.

  ## Quick Start

      # 1. Define a schema
      schema = Anvil.Schema.new(
        name: "sentiment",
        fields: [
          %Anvil.Schema.Field{
            name: "sentiment",
            type: :select,
            required: true,
            options: ["positive", "negative", "neutral"]
          }
        ]
      )

      # 2. Create a queue
      {:ok, queue} = Anvil.create_queue(
        queue_id: "sentiment_queue",
        schema: schema
      )

      # 3. Add samples
      Anvil.add_samples(queue, [
        %{id: "s1", text: "Great product!"},
        %{id: "s2", text: "Not good."}
      ])

      # 4. Add labelers
      Anvil.add_labelers(queue, ["labeler_1", "labeler_2"])

      # 5. Get assignment
      {:ok, assignment} = Anvil.get_next_assignment(queue, "labeler_1")

      # 6. Submit label
      {:ok, label} = Anvil.submit_label(assignment.id, %{"sentiment" => "positive"})

  """

  alias Anvil.Queue

  @doc """
  Creates a new labeling queue.

  ## Options

    * `:queue_id` - Unique identifier for the queue (required)
    * `:schema` - LabelSchema defining the label structure (required)
    * `:policy` - Assignment policy (`:round_robin`, `:random`, `:expertise`) (default: `:round_robin`)
    * `:labels_per_sample` - Number of labels needed per sample (default: 1)
    * `:assignment_timeout` - Timeout in seconds (default: 3600)

  """
  @spec create_queue(keyword()) :: {:ok, pid()} | {:error, term()}
  def create_queue(opts) do
    Queue.start_link(opts)
  end

  @doc """
  Adds samples to a queue for labeling.
  """
  @spec add_samples(pid() | atom(), [map()]) :: :ok | {:error, term()}
  defdelegate add_samples(queue, samples), to: Queue

  @doc """
  Adds labelers to a queue.
  """
  @spec add_labelers(pid() | atom(), [String.t()]) :: :ok
  defdelegate add_labelers(queue, labelers), to: Queue

  @doc """
  Gets the next assignment for a labeler.
  """
  @spec get_next_assignment(pid() | atom(), String.t()) ::
          {:ok, Anvil.Assignment.t()} | {:error, term()}
  defdelegate get_next_assignment(queue, labeler_id), to: Queue

  @doc """
  Starts an assignment.
  """
  @spec start_assignment(String.t()) :: {:ok, Anvil.Assignment.t()} | {:error, term()}
  def start_assignment(assignment_id) do
    # For now, we need the queue reference
    # In a real implementation, we'd look this up from a registry
    {:error, :not_implemented}
  end

  @doc """
  Submits a label for an assignment.
  """
  @spec submit_label(pid() | atom(), String.t(), map()) ::
          {:ok, Anvil.Label.t()} | {:error, term()}
  defdelegate submit_label(queue, assignment_id, values), to: Queue

  @doc """
  Skips an assignment.
  """
  @spec skip_assignment(pid() | atom(), String.t(), keyword()) ::
          {:ok, Anvil.Assignment.t()} | {:error, term()}
  defdelegate skip_assignment(queue, assignment_id, opts \\ []), to: Queue

  @doc """
  Computes inter-rater agreement metrics.
  """
  @spec compute_agreement(pid() | atom(), keyword()) :: {:ok, float()} | {:error, term()}
  def compute_agreement(queue, opts \\ []) do
    labels = Queue.get_labels(queue)
    Anvil.Agreement.compute(labels, opts)
  end

  @doc """
  Exports labeled data.
  """
  @spec export(pid() | atom(), keyword()) :: :ok | {:error, term()}
  defdelegate export(queue, opts), to: Anvil.Export
end
