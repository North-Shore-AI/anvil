defmodule Anvil.Workers.RetentionSweep do
  @moduledoc """
  Background job worker that enforces data retention policies.

  This worker runs periodically (daily at 3 AM) to clean up old data according
  to retention policies. It handles:

  - Deletion of audit logs older than the retention period (default: 7 years)
  - Redaction of PII in labels past their retention period (field-level retention)
  - Cleanup of expired assignments and temporary data

  ## PII Retention Actions

  The worker supports three retention actions for labels with expired PII fields:
  - `:field_redaction` - Redact only expired fields, keep unexpired (default)
  - `:soft_delete` - Keep metadata, strip entire payload
  - `:hard_delete` - Permanent deletion (breaks reproducibility)

  ## Configuration

  Queue: `:maintenance`
  Max Attempts: 3
  Priority: 2 (medium priority)

  ## Scheduled Execution

  Configured in `config.exs` via Oban.Plugins.Cron:
  ```elixir
  {"0 3 * * *", Anvil.Workers.RetentionSweep}
  ```

  ## Job Arguments

  - `retention_days` (optional) - Number of days to retain audit logs (default: 2555 = ~7 years)
  - `dry_run` (optional) - If true, only counts records without deleting (default: false)
  - `pii_retention_action` (optional) - Retention action for PII fields (`:field_redaction`, `:soft_delete`, `:hard_delete`) (default: `:field_redaction`)
  - `process_pii` (optional) - If true, process PII retention (default: true)

  ## Telemetry

  Emits the following telemetry events:
  - `[:anvil, :workers, :retention_sweep, :started]` - Job execution started
  - `[:anvil, :workers, :retention_sweep, :completed]` - Job completed successfully
  """

  use Oban.Worker,
    queue: :maintenance,
    max_attempts: 3,
    priority: 2

  import Ecto.Query
  alias Anvil.Repo
  alias Anvil.Schema.AuditLog
  alias Anvil.PII.Retention

  @default_retention_days 2555

  @impl Oban.Worker
  def perform(%Oban.Job{args: args} = _job) do
    retention_days = args["retention_days"] || @default_retention_days
    dry_run = args["dry_run"] || false
    process_pii = Map.get(args, "process_pii", true)

    pii_retention_action =
      String.to_existing_atom(Map.get(args, "pii_retention_action", "field_redaction"))

    :telemetry.execute(
      [:anvil, :workers, :retention_sweep, :started],
      %{},
      %{retention_days: retention_days, dry_run: dry_run, process_pii: process_pii}
    )

    cutoff = DateTime.add(DateTime.utc_now(), -retention_days, :day)

    # Delete old audit logs
    {audit_logs_deleted, _} = delete_old_audit_logs(cutoff, dry_run)

    # Process PII retention if enabled
    labels_processed =
      if process_pii do
        case Retention.process_expired_labels(
               dry_run: dry_run,
               action: pii_retention_action
             ) do
          {:ok, count} -> count
        end
      else
        0
      end

    :telemetry.execute(
      [:anvil, :workers, :retention_sweep, :completed],
      %{
        audit_logs_deleted: audit_logs_deleted,
        labels_processed: labels_processed
      },
      %{retention_days: retention_days, dry_run: dry_run, process_pii: process_pii}
    )

    :ok
  end

  @doc """
  Deletes audit logs older than the specified cutoff date.

  ## Parameters

  - `cutoff` - DateTime before which logs should be deleted
  - `dry_run` - If true, only counts without deleting

  ## Returns

  A tuple `{count, nil}` where count is the number of records deleted (or counted in dry run mode).
  """
  @spec delete_old_audit_logs(DateTime.t(), boolean()) :: {non_neg_integer(), nil}
  def delete_old_audit_logs(cutoff, dry_run \\ false) do
    query = from(a in AuditLog, where: a.occurred_at < ^cutoff)

    if dry_run do
      count = Repo.aggregate(query, :count, :id)
      {count, nil}
    else
      Repo.delete_all(query)
    end
  end

  @doc """
  Enqueues a retention sweep job.

  ## Options

  - `:retention_days` - Number of days to retain audit logs (default: 2555)
  - `:dry_run` - If true, only counts records without deleting (default: false)
  - `:process_pii` - If true, process PII retention (default: true)
  - `:pii_retention_action` - Retention action for PII (default: :field_redaction)
  """
  @spec enqueue(keyword()) :: {:ok, Oban.Job.t()} | {:error, term()}
  def enqueue(opts \\ []) do
    retention_days = Keyword.get(opts, :retention_days, @default_retention_days)
    dry_run = Keyword.get(opts, :dry_run, false)
    process_pii = Keyword.get(opts, :process_pii, true)
    pii_retention_action = Keyword.get(opts, :pii_retention_action, :field_redaction)

    %{
      retention_days: retention_days,
      dry_run: dry_run,
      process_pii: process_pii,
      pii_retention_action: Atom.to_string(pii_retention_action)
    }
    |> __MODULE__.new()
    |> Oban.insert()
  end
end
