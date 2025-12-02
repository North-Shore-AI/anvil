defmodule Anvil.Workers.TimeoutChecker do
  @moduledoc """
  Background job worker that checks for timed-out assignments and requeues them.

  This worker runs periodically (every 5 minutes via cron) to find assignments
  that have exceeded their deadline and transitions them from :reserved to
  :timed_out status, then requeues them for another labeler.

  ## Configuration

  Queue: `:timeouts`
  Max Attempts: 3
  Priority: 1 (high priority)

  ## Scheduled Execution

  Configured in `config.exs` via Oban.Plugins.Cron:
  ```elixir
  {"*/5 * * * *", Anvil.Workers.TimeoutChecker}
  ```

  ## Telemetry

  Emits the following telemetry events:
  - `[:anvil, :workers, :timeout_checker, :started]` - Job execution started
  - `[:anvil, :workers, :timeout_checker, :completed]` - Job completed successfully
  - `[:anvil, :workers, :timeout_checker, :failed]` - Job failed
  """

  use Oban.Worker,
    queue: :timeouts,
    max_attempts: 3,
    priority: 1

  import Ecto.Query
  alias Anvil.Repo
  alias Anvil.Schema.Assignment

  @impl Oban.Worker
  def perform(%Oban.Job{} = _job) do
    :telemetry.execute([:anvil, :workers, :timeout_checker, :started], %{}, %{})

    now = DateTime.utc_now()

    # Find all reserved assignments that have passed their deadline
    timed_out_assignments =
      from(a in Assignment,
        where: a.status == :reserved and a.deadline < ^now
      )
      |> Repo.all()

    results = Enum.map(timed_out_assignments, &handle_timeout/1)

    timed_out_count = length(timed_out_assignments)
    requeued_count = Enum.count(results, &match?({:ok, :requeued}, &1))
    failed_count = Enum.count(results, &match?({:error, _}, &1))

    :telemetry.execute(
      [:anvil, :workers, :timeout_checker, :completed],
      %{
        timed_out: timed_out_count,
        requeued: requeued_count,
        failed: failed_count
      },
      %{}
    )

    if failed_count > 0 do
      {:error, "Failed to process #{failed_count} assignments"}
    else
      :ok
    end
  end

  @doc """
  Handles a single timed-out assignment by marking it as timed_out and requeuing it.
  """
  @spec handle_timeout(Assignment.t()) :: {:ok, :requeued} | {:error, term()}
  def handle_timeout(%Assignment{} = assignment) do
    Repo.transaction(fn ->
      # First mark as timed out
      {:ok, timed_out_assignment} =
        assignment
        |> Assignment.timeout()
        |> Repo.update()

      # Then requeue for retry
      timed_out_assignment
      |> Assignment.requeue()
      |> Repo.update!()

      :requeued
    end)
  rescue
    error -> {:error, error}
  end
end
