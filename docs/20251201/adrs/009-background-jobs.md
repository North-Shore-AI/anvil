# ADR-009: Background Job Management with Oban

## Status
Accepted

## Context

Labeling systems require background processing for tasks that are:

**Time-Intensive**:
- Export generation for large datasets (100k+ labels → 5-10 minutes)
- Agreement batch recomputation (scan all labels → minutes to hours)
- Retention sweeps across millions of audit logs

**Scheduled**:
- Timeout sweeps every 5 minutes (requeue abandoned assignments)
- Daily agreement metric refreshes (detect quality degradation)
- Nightly retention policy enforcement (PII deletion)
- Weekly export archival (snapshot datasets for reproducibility)

**Asynchronous**:
- Email notifications on label completion (avoid blocking API response)
- Webhook delivery to external systems (retry on failure)
- Sample pre-fetching from Forge (optimize assignment dispatch latency)

**Fault-Tolerant**:
- Retry on transient failures (network errors, DB deadlocks)
- Exponential backoff for rate-limited APIs
- Dead letter queue for permanently failed jobs

**Observable**:
- Job queue depth monitoring (detect backlog growth)
- Retry statistics (identify problematic jobs)
- Duration metrics (detect performance regressions)

The Elixir ecosystem provides several job processing options:

| Library | Persistence | Unique Jobs | Cron | Observability | Complexity |
|---------|-------------|-------------|------|---------------|------------|
| GenServer | None (in-memory) | No | Manual | Low | Low |
| Quantum | None | No | Yes | Low | Low |
| Exq | Redis | Partial | Via plugin | Medium | Medium |
| Oban | Postgres | Yes | Yes | High | Medium |

**Oban Advantages**:
- **Postgres-backed**: No additional infrastructure (Redis); leverages existing Anvil DB
- **Unique Jobs**: Built-in deduplication (prevent duplicate exports)
- **Cron Scheduling**: First-class support for recurring jobs
- **Observability**: Telemetry integration, Web UI, metrics
- **Reliability**: Transactional job insertion (job created iff DB write succeeds)
- **Ecosystem**: Wide adoption in Phoenix apps; battle-tested

Current Anvil v0.1 has no background job infrastructure:
- Timeout sweeps must be manually triggered
- Exports block HTTP requests (users wait minutes for response)
- No retry logic for transient failures
- Cannot schedule recurring tasks

## Decision

We will use Oban as the unified background job system for all asynchronous, scheduled, and time-intensive tasks in Anvil.

### 1. Oban Configuration

```elixir
# config/config.exs
config :anvil, Oban,
  repo: Anvil.Repo,
  plugins: [
    # Cron scheduling
    {Oban.Plugins.Cron,
     crontab: [
       # Timeout sweeps every 5 minutes
       {"*/5 * * * *", Anvil.Jobs.TimeoutSweep},
       # Agreement recompute nightly at 2 AM
       {"0 2 * * *", Anvil.Jobs.AgreementRecompute},
       # Retention sweep daily at 3 AM
       {"0 3 * * *", Anvil.Jobs.RetentionSweep},
       # Export archival weekly Sunday at 4 AM
       {"0 4 * * 0", Anvil.Jobs.ExportArchival}
     ]},

    # Prune completed jobs after 7 days
    {Oban.Plugins.Pruner, max_age: 60 * 60 * 24 * 7},

    # Rescue orphaned jobs (e.g., if node crashes mid-execution)
    {Oban.Plugins.Lifeline, rescue_after: :timer.minutes(30)},

    # Monitor queue depth
    {Oban.Plugins.Stager, interval: 1000}
  ],
  queues: [
    # High priority: User-facing operations
    exports: 3,          # Concurrent export jobs
    notifications: 5,    # Email/webhook delivery

    # Medium priority: Periodic maintenance
    analytics: 2,        # Agreement recomputation
    sweeps: 1,           # Timeout/retention sweeps

    # Low priority: Deferred tasks
    archival: 1          # Long-term storage migration
  ]

# Production overrides
# config/runtime.exs
if config_env() == :prod do
  config :anvil, Oban,
    queues: [
      exports: 10,       # Scale up for production load
      notifications: 20,
      analytics: 5,
      sweeps: 2,
      archival: 2
    ]
end
```

### 2. Job Implementations

#### Timeout Sweep Job

```elixir
defmodule Anvil.Jobs.TimeoutSweep do
  use Oban.Worker,
    queue: :sweeps,
    max_attempts: 3,
    priority: 1  # High priority (lower number)

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    now = DateTime.utc_now()

    # Find timed-out assignments
    timed_out_assignments =
      from(a in Assignment,
        where: a.status == :reserved and a.deadline < ^now
      )
      |> Repo.all()

    # Update status and handle requeuing
    results = Enum.map(timed_out_assignments, &handle_timeout/1)

    timed_out_count = length(timed_out_assignments)
    requeued_count = Enum.count(results, &match?({:ok, :requeued}, &1))
    escalated_count = Enum.count(results, &match?({:ok, :escalated}, &1))

    # Emit telemetry
    :telemetry.execute(
      [:anvil, :jobs, :timeout_sweep, :completed],
      %{timed_out: timed_out_count, requeued: requeued_count, escalated: escalated_count},
      %{}
    )

    {:ok, %{timed_out: timed_out_count, requeued: requeued_count}}
  end

  defp handle_timeout(assignment) do
    queue = Repo.get!(Queue, assignment.queue_id)
    policy = load_policy(queue.policy)

    case policy.requeue_strategy(assignment, :timeout) do
      :requeue ->
        Assignment.requeue(assignment)
        {:ok, :requeued}

      :archive ->
        Assignment.archive(assignment, reason: :max_timeout_attempts)
        {:ok, :escalated}

      {:requeue_with_priority, priority} ->
        Assignment.requeue(assignment, priority: priority)
        {:ok, :requeued}
    end
  end
end
```

#### Agreement Recompute Job

```elixir
defmodule Anvil.Jobs.AgreementRecompute do
  use Oban.Worker,
    queue: :analytics,
    max_attempts: 5,
    priority: 2

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"queue_id" => queue_id}}) do
    # Stream samples in batches to avoid memory issues
    Sample
    |> where(queue_id: ^queue_id)
    |> Repo.stream()
    |> Stream.chunk_every(100)
    |> Stream.each(&compute_batch_agreement/1)
    |> Stream.run()

    :ok
  end

  # Enqueue job for specific queue (idempotent)
  def enqueue(queue_id) do
    %{queue_id: queue_id}
    |> Anvil.Jobs.AgreementRecompute.new(
      unique: [period: :timer.hours(24), keys: [:queue_id]]
    )
    |> Oban.insert()
  end

  defp compute_batch_agreement(samples) do
    for sample <- samples do
      labels = Repo.all(from l in Label, where: l.sample_id == ^sample.id)

      if length(labels) >= 2 do
        agreement = Anvil.Agreement.compute(labels)
        Anvil.Agreement.upsert_metric(sample.id, agreement)
      end
    end
  end
end
```

#### Export Generation Job

```elixir
defmodule Anvil.Jobs.ExportGeneration do
  use Oban.Worker,
    queue: :exports,
    max_attempts: 3,
    priority: 0  # Highest priority (user-facing)

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    queue_id = args["queue_id"]
    format = String.to_atom(args["format"])
    output_path = args["output_path"]
    opts = Map.get(args, "opts", %{})

    # Emit progress events
    :telemetry.execute([:anvil, :jobs, :export, :started], %{}, %{queue_id: queue_id})

    case Anvil.Export.to_format(queue_id, format, opts) do
      {:ok, manifest} ->
        # Upload to S3 if configured
        if s3_bucket = Application.get_env(:anvil, :export_s3_bucket) do
          upload_to_s3(output_path, s3_bucket, manifest.export_id)
        end

        # Register in AITrace
        Anvil.AITrace.register_export(manifest)

        :telemetry.execute([:anvil, :jobs, :export, :completed], %{},
          %{queue_id: queue_id, row_count: manifest.row_count}
        )

        {:ok, manifest}

      {:error, reason} ->
        :telemetry.execute([:anvil, :jobs, :export, :failed], %{},
          %{queue_id: queue_id, reason: inspect(reason)}
        )

        {:error, reason}
    end
  end

  # Enqueue export job (idempotent for same parameters)
  def enqueue(queue_id, format, opts \\ %{}) do
    output_path = generate_output_path(queue_id, format)

    %{
      queue_id: queue_id,
      format: to_string(format),
      output_path: output_path,
      opts: opts
    }
    |> Anvil.Jobs.ExportGeneration.new(
      unique: [
        period: :timer.minutes(5),
        keys: [:queue_id, :format],
        states: [:available, :scheduled, :executing]
      ]
    )
    |> Oban.insert()
  end
end
```

#### Retention Sweep Job

```elixir
defmodule Anvil.Jobs.RetentionSweep do
  use Oban.Worker,
    queue: :sweeps,
    max_attempts: 3,
    priority: 2

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    # Delete audit logs older than 7 years (default retention)
    cutoff = DateTime.add(DateTime.utc_now(), -7 * 365, :day)

    {deleted_count, _} =
      from(a in AuditLog, where: a.occurred_at < ^cutoff)
      |> Repo.delete_all()

    # Redact labels past field retention period
    redacted_count = Anvil.GDPR.run_retention_sweep()

    :telemetry.execute([:anvil, :jobs, :retention_sweep, :completed], %{
      audit_logs_deleted: deleted_count,
      labels_redacted: redacted_count
    })

    {:ok, %{audit_logs_deleted: deleted_count, labels_redacted: redacted_count}}
  end
end
```

### 3. Job Orchestration Patterns

#### Parent-Child Jobs (Fan-Out)

```elixir
defmodule Anvil.Jobs.BulkExport do
  use Oban.Worker, queue: :exports

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"queue_ids" => queue_ids}}) do
    # Enqueue child export jobs
    for queue_id <- queue_ids do
      Anvil.Jobs.ExportGeneration.enqueue(queue_id, :csv)
    end

    :ok
  end
end
```

#### Scheduled Job with Dependencies

```elixir
# Enqueue job to run in 1 hour (deferred execution)
%{queue_id: queue_id}
|> Anvil.Jobs.AgreementRecompute.new(schedule_in: :timer.hours(1))
|> Oban.insert()

# Enqueue job after specific timestamp
%{queue_id: queue_id}
|> Anvil.Jobs.ExportGeneration.new(scheduled_at: ~U[2025-12-15 00:00:00Z])
|> Oban.insert()
```

#### Workflow with Retries and Backoff

```elixir
defmodule Anvil.Jobs.WebhookDelivery do
  use Oban.Worker,
    queue: :notifications,
    max_attempts: 5

  @impl Oban.Worker
  def perform(%Oban.Job{args: args, attempt: attempt}) do
    url = args["webhook_url"]
    payload = args["payload"]

    case HTTPoison.post(url, Jason.encode!(payload)) do
      {:ok, %{status_code: 200}} ->
        :ok

      {:ok, %{status_code: code}} when code >= 500 ->
        # Transient server error, retry with exponential backoff
        {:snooze, backoff_duration(attempt)}

      {:ok, %{status_code: code}} when code >= 400 ->
        # Permanent client error, don't retry
        {:discard, "Client error: #{code}"}

      {:error, %HTTPoison.Error{reason: reason}} ->
        # Network error, retry
        {:snooze, backoff_duration(attempt)}
    end
  end

  defp backoff_duration(attempt) do
    # Exponential backoff: 1min, 2min, 4min, 8min, 16min
    :timer.minutes(2 ** (attempt - 1))
  end
end
```

### 4. Unique Job Constraints

**Prevent Duplicate Jobs**:

```elixir
# Only one export job per queue per hour
%{queue_id: queue_id, format: "csv"}
|> Anvil.Jobs.ExportGeneration.new(
  unique: [
    period: :timer.hours(1),
    keys: [:queue_id, :format],
    states: [:available, :scheduled, :executing]
  ]
)
|> Oban.insert()

# Attempting to insert duplicate job within 1 hour returns existing job
case Oban.insert(job) do
  {:ok, %Oban.Job{} = job} -> {:ok, job}
  {:error, %Ecto.Changeset{errors: [unique: _]}} -> {:error, :duplicate_job}
end
```

**Replace Existing Job** (for parameter updates):

```elixir
%{queue_id: queue_id}
|> Anvil.Jobs.AgreementRecompute.new(
  unique: [
    period: :timer.hours(24),
    keys: [:queue_id],
    replace: [:scheduled]  # Replace scheduled jobs with new parameters
  ]
)
|> Oban.insert()
```

### 5. Monitoring and Observability

**Telemetry Integration**:

```elixir
# Oban emits built-in telemetry events
:telemetry.attach_many(
  "anvil-oban-monitoring",
  [
    [:oban, :job, :start],
    [:oban, :job, :stop],
    [:oban, :job, :exception]
  ],
  &handle_oban_event/4,
  nil
)

defp handle_oban_event([:oban, :job, :start], measurements, metadata, _config) do
  :telemetry.execute([:anvil, :jobs, :started], measurements, %{
    worker: metadata.worker,
    queue: metadata.queue
  })
end

defp handle_oban_event([:oban, :job, :stop], measurements, metadata, _config) do
  :telemetry.execute([:anvil, :jobs, :completed], measurements, %{
    worker: metadata.worker,
    queue: metadata.queue,
    duration_ms: System.convert_time_unit(measurements.duration, :native, :millisecond)
  })
end

defp handle_oban_event([:oban, :job, :exception], measurements, metadata, _config) do
  Logger.error("Job failed: #{metadata.worker}", error: metadata.error)

  :telemetry.execute([:anvil, :jobs, :failed], measurements, %{
    worker: metadata.worker,
    queue: metadata.queue,
    attempt: metadata.attempt,
    error: inspect(metadata.error)
  })
end
```

**Oban Web UI** (for production monitoring):

```elixir
# lib/anvil_web/router.ex
scope "/admin" do
  pipe_through [:browser, :require_admin]

  forward "/oban", Oban.Web.Router, namespace: "oban"
end
```

**Custom Metrics**:

```elixir
# Queue depth monitoring
def queue_depth_metrics do
  [
    last_value("anvil.oban.queue_depth",
      measurement: fn ->
        Oban.check_queue(Anvil.Oban, queue: :exports)
        |> Map.get(:available)
      end,
      tags: [:queue]
    )
  ]
end
```

### 6. Error Handling and Dead Letter Queue

**Permanent Failures**:

```elixir
defmodule Anvil.Jobs.ExportGeneration do
  use Oban.Worker, queue: :exports, max_attempts: 3

  @impl Oban.Worker
  def perform(%Oban.Job{attempt: attempt} = job) do
    case Anvil.Export.to_format(...) do
      {:ok, manifest} ->
        :ok

      {:error, :invalid_schema_version} ->
        # Permanent error, don't retry
        {:discard, "Invalid schema version"}

      {:error, reason} when attempt < 3 ->
        # Transient error, retry
        {:error, reason}

      {:error, reason} ->
        # Max attempts reached, send to dead letter queue
        send_to_dead_letter_queue(job, reason)
        {:discard, "Max attempts reached"}
    end
  end

  defp send_to_dead_letter_queue(job, reason) do
    # Log to dedicated table or external system
    DeadLetterQueue.insert(%{
      worker: job.worker,
      args: job.args,
      error: inspect(reason),
      failed_at: DateTime.utc_now()
    })

    # Alert on-call
    send_alert(:error, "Export job permanently failed", %{job_id: job.id})
  end
end
```

## Consequences

### Positive

- **Reliability**: Postgres-backed job queue survives restarts; transactional insertion prevents lost jobs
- **Scalability**: Queue-based concurrency limits prevent resource exhaustion; horizontal scaling via multiple nodes
- **Observability**: Built-in telemetry and Web UI enable real-time monitoring of job health
- **Maintainability**: Cron plugin eliminates need for external schedulers (no crontab management)
- **Fault Tolerance**: Automatic retries with exponential backoff handle transient failures gracefully
- **Uniqueness**: Built-in deduplication prevents duplicate exports and concurrent modification races
- **Ecosystem Integration**: Oban is battle-tested in Phoenix apps; abundant documentation and community support

### Negative

- **Postgres Load**: Job polling queries add ~1-5 QPS per queue; requires connection pool tuning
- **Latency**: Minimum job execution latency ~1 second (polling interval); not suitable for real-time tasks
- **Complexity**: Oban configuration (plugins, queues, unique constraints) has learning curve
- **Migration Risk**: Oban schema migrations must be coordinated with Anvil migrations
- **Lock Contention**: High job insertion rates can cause Postgres advisory lock contention (mitigated by Stager plugin)

### Neutral

- **Alternative Workers**: Can still use GenServer for truly real-time tasks (e.g., WebSocket push notifications)
- **Multi-Node Coordination**: Oban handles distributed job execution across nodes; no additional coordination needed
- **Job Versioning**: Worker module changes may require job schema migrations (handle in `perform/1` with pattern matching)
- **Cost**: Managed Postgres (RDS) compute scales with job volume; monitor query load

## Implementation Notes

1. **Migration Setup**:
   ```bash
   # Install Oban
   mix deps.get

   # Generate Oban migration
   mix ecto.gen.migration add_oban_jobs_table

   # Copy Oban migration SQL (from Oban docs)
   mix ecto.migrate
   ```

2. **Supervision Tree**:
   ```elixir
   defmodule Anvil.Application do
     def start(_type, _args) do
       children = [
         Anvil.Repo,
         {Oban, Application.fetch_env!(:anvil, Oban)},
         # ... other services
       ]

       Supervisor.start_link(children, strategy: :one_for_one)
     end
   end
   ```

3. **Testing Strategy**:
   ```elixir
   # Use Oban testing mode (synchronous execution)
   # config/test.exs
   config :anvil, Oban, testing: :inline

   # Test job execution
   defmodule Anvil.Jobs.TimeoutSweepTest do
     use Anvil.DataCase
     use Oban.Testing, repo: Anvil.Repo

     test "requeues timed-out assignments" do
       assignment = insert(:assignment, status: :reserved, deadline: ~U[2020-01-01 00:00:00Z])

       perform_job(Anvil.Jobs.TimeoutSweep, %{})

       assert Repo.reload(assignment).status == :pending
     end
   end
   ```

4. **Performance Tuning**:
   - **Polling Interval**: Reduce from 1s to 100ms for lower latency (higher DB load)
   - **Queue Concurrency**: Start conservative (3-5), scale based on CPU/DB capacity
   - **Connection Pool**: Increase Ecto pool size to accommodate Oban workers
   - **Pruner Settings**: Tune max_age based on audit requirements (7-90 days)

5. **Deployment Considerations**:
   - **Blue-Green Deploys**: Oban gracefully handles old workers with new job schema (version payload)
   - **Node Count**: Scale horizontally by adding nodes; Oban distributes jobs automatically
   - **Queue Pausing**: Pause queues during maintenance: `Oban.pause_queue(:exports)`

6. **Alerting Rules**:
   - Queue depth > 1000 for 10+ minutes (backlog alert)
   - Job failure rate > 5% (quality alert)
   - Average job duration > 2x baseline (performance regression)

7. **Job Priorities**:
   - 0: User-facing (exports requested via UI)
   - 1: System-critical (timeout sweeps)
   - 2: Maintenance (agreement recompute)
   - 3: Deferred (archival, analytics)
