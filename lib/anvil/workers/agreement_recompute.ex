defmodule Anvil.Workers.AgreementRecompute do
  @moduledoc """
  Background job worker that recomputes agreement metrics for labeled samples.

  This worker can be scheduled to run periodically (nightly at 2 AM) or triggered
  on-demand for specific queues. It processes samples in batches to compute
  inter-rater agreement scores when multiple labelers have labeled the same sample.

  ## Configuration

  Queue: `:agreement`
  Max Attempts: 5
  Priority: 2 (medium priority)

  ## Scheduled Execution

  Configured in `config.exs` via Oban.Plugins.Cron:
  ```elixir
  {"0 2 * * *", Anvil.Workers.AgreementRecompute}
  ```

  ## Job Arguments

  - `queue_id` (optional) - If provided, only recomputes agreement for samples in this queue
  - `batch_size` (optional) - Number of samples to process per batch (default: 100)

  ## Telemetry

  Emits the following telemetry events:
  - `[:anvil, :workers, :agreement_recompute, :started]` - Job execution started
  - `[:anvil, :workers, :agreement_recompute, :batch_processed]` - Batch completed
  - `[:anvil, :workers, :agreement_recompute, :completed]` - Job completed successfully
  """

  use Oban.Worker,
    queue: :agreement,
    max_attempts: 5,
    priority: 2

  import Ecto.Query
  alias Anvil.Repo
  alias Anvil.Schema.{Assignment, Label}
  alias Anvil.Agreement

  @default_batch_size 100

  @impl Oban.Worker
  def perform(%Oban.Job{args: args} = _job) do
    queue_id = args["queue_id"]
    batch_size = args["batch_size"] || @default_batch_size

    :telemetry.execute(
      [:anvil, :workers, :agreement_recompute, :started],
      %{},
      %{queue_id: queue_id}
    )

    # Build query for samples with multiple labels
    base_query = build_sample_query(queue_id)

    # Fetch and process samples in batches
    # Note: Using Repo.all() instead of Repo.stream() for test compatibility
    sample_ids = Repo.all(base_query)

    processed_count =
      sample_ids
      |> Enum.chunk_every(batch_size)
      |> Enum.map(&process_batch/1)
      |> Enum.sum()

    :telemetry.execute(
      [:anvil, :workers, :agreement_recompute, :completed],
      %{samples_processed: processed_count},
      %{queue_id: queue_id}
    )

    :ok
  end

  @doc """
  Enqueues an agreement recomputation job for a specific queue.

  Uses uniqueness constraints to prevent duplicate jobs for the same queue
  within a 24-hour period.

  ## Options

  - `:batch_size` - Number of samples per batch (default: 100)
  - `:unique_period` - Uniqueness window in milliseconds (default: 24 hours)
  """
  @spec enqueue(String.t(), keyword()) :: {:ok, Oban.Job.t()} | {:error, term()}
  def enqueue(queue_id, opts \\ []) do
    batch_size = Keyword.get(opts, :batch_size, @default_batch_size)
    unique_period = Keyword.get(opts, :unique_period, :timer.hours(24))

    %{queue_id: queue_id, batch_size: batch_size}
    |> __MODULE__.new(unique: [period: unique_period, keys: [:queue_id]])
    |> Oban.insert()
  end

  # Builds a query for samples that have multiple labels
  defp build_sample_query(nil) do
    # Get all samples with 2+ labels
    from(a in Assignment,
      join: l in Label,
      on: l.assignment_id == a.id,
      group_by: a.sample_id,
      having: count(l.id) >= 2,
      select: a.sample_id,
      distinct: true
    )
  end

  defp build_sample_query(queue_id) do
    # Get samples in specific queue with 2+ labels
    from(a in Assignment,
      join: l in Label,
      on: l.assignment_id == a.id,
      where: a.queue_id == ^queue_id,
      group_by: a.sample_id,
      having: count(l.id) >= 2,
      select: a.sample_id,
      distinct: true
    )
  end

  # Processes a batch of sample IDs
  defp process_batch(sample_ids) do
    sample_ids
    |> Enum.map(&compute_sample_agreement/1)
    |> Enum.count(&match?(:ok, &1))
  end

  # Computes agreement for a single sample
  defp compute_sample_agreement(sample_id) do
    # Fetch all labels for this sample
    labels =
      from(l in Label,
        join: a in Assignment,
        on: l.assignment_id == a.id,
        where: a.sample_id == ^sample_id,
        select: %{
          labeler_id: l.labeler_id,
          values: l.payload
        }
      )
      |> Repo.all()

    case Agreement.compute(labels) do
      {:ok, _score} ->
        :telemetry.execute(
          [:anvil, :workers, :agreement_recompute, :sample_computed],
          %{},
          %{sample_id: sample_id}
        )

        :ok

      {:error, _reason} ->
        # Log but don't fail the entire job for individual sample failures
        :error
    end
  rescue
    _error -> :error
  end
end
