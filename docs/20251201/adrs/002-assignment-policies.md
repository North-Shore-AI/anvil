# ADR-002: Assignment Policy Engine

## Status
Accepted

## Context

The current Anvil implementation provides only a basic behaviour interface for assignment selection (`Anvil.Assignment.next/2`), with no built-in policies for critical production scenarios:

- **Fair Distribution**: Ensuring all labelers receive work without manual queue management
- **Expertise Weighting**: Routing complex samples to experienced labelers while training novices on simpler cases
- **Quality Assurance**: Requiring multiple independent labels per sample to compute inter-rater reliability
- **Timeout Handling**: Automatically requeueing abandoned work without manual intervention
- **Labeler Management**: Preventing specific labelers from accessing certain queues (conflicts of interest, blocklisting)
- **Load Balancing**: Capping concurrent assignments per labeler to prevent hoarding and burnout

Different labeling workflows have fundamentally different requirements:
- CNS synthesis evaluation needs k=3 redundant labels per sample for agreement metrics
- Rapid prototyping may accept k=1 with best-effort assignment
- High-stakes medical annotation requires certification-based routing and audit trails

Without a flexible policy engine, every consumer must reimplement assignment logic, leading to inconsistent behavior, duplicated code, and difficulty enforcing organization-wide quality standards.

## Decision

We will implement a composable policy engine architecture with built-in policies for common scenarios and extension points for domain-specific logic.

### Policy Behaviour Interface

```elixir
defmodule Anvil.Policy do
  @callback select_assignment(
    queue_id :: binary(),
    labeler_id :: binary(),
    opts :: keyword()
  ) :: {:ok, assignment} | {:error, :no_available_work} | {:error, reason}

  @callback requeue_strategy(
    assignment :: map(),
    reason :: :timeout | :rejection | :system_failure
  ) :: :requeue | :archive | {:requeue_with_priority, integer()}

  @callback validate_labeler(
    queue_id :: binary(),
    labeler_id :: binary()
  ) :: :ok | {:error, :blocked | :max_concurrent_exceeded | reason}
end
```

### Built-In Policy Implementations

#### 1. RoundRobin Policy (`Anvil.Policy.RoundRobin`)

Simplest fair-distribution strategy; assigns next pending sample chronologically.

**Algorithm**:
```sql
SELECT * FROM assignments
WHERE queue_id = $1
  AND status = 'pending'
  AND sample_id NOT IN (
    SELECT sample_id FROM assignments
    WHERE labeler_id = $2 AND status IN ('reserved', 'completed')
  )
ORDER BY created_at ASC
LIMIT 1
FOR UPDATE SKIP LOCKED
```

**State**: Stateless; relies on created_at ordering
**Use Case**: Simple labeling queues where all samples have equal priority

#### 2. Weighted Expertise Policy (`Anvil.Policy.WeightedExpertise`)

Routes samples based on labeler skill levels and sample difficulty.

**Configuration** (stored in `queues.policy` jsonb):
```json
{
  "type": "weighted_expertise",
  "difficulty_field": "metadata.complexity",  // Field in sample payload
  "labeler_weights": {  // Loaded from labelers.expertise_weights
    "novice": 1.0,
    "intermediate": 1.5,
    "expert": 2.0
  },
  "difficulty_thresholds": {
    "simple": ["novice", "intermediate", "expert"],
    "moderate": ["intermediate", "expert"],
    "complex": ["expert"]
  }
}
```

**Algorithm**:
1. Load sample difficulty from Forge via `ForgeBridge.fetch_sample/2`
2. Filter eligible labelers based on difficulty threshold
3. Among eligible, prioritize by inverse of current workload (fewer active assignments = higher priority)
4. Randomize within priority tier for fairness

**State**: Tracks per-labeler active assignment counts in-memory (refreshed on assignment/completion)
**Use Case**: CNS synthesis labeling where experts validate model outputs, novices label ground truth

#### 3. Redundancy Policy (`Anvil.Policy.Redundancy`)

Ensures k independent labels per sample for inter-rater reliability computation.

**Configuration**:
```json
{
  "type": "redundancy",
  "target_labels_per_sample": 3,
  "allow_same_labeler": false,  // Prevent single labeler from dominating sample
  "completion_threshold": "all"  // Options: all, majority (>50%), quorum (k-1)
}
```

**Algorithm**:
1. For each pending sample, count existing labels (across all labelers)
2. Filter out samples where `label_count >= target_labels_per_sample`
3. Among remaining, exclude samples already labeled by requesting labeler (if allow_same_labeler=false)
4. Select sample with fewest labels (prioritize under-labeled samples)

**State**: Denormalized `sample_label_counts` table maintained via triggers or background job
**Use Case**: Quality assurance workflows requiring Cohen's kappa / Fleiss' kappa metrics

#### 4. Timeout & Requeue Policy (`Anvil.Policy.TimeoutRequeue`)

Automatically returns abandoned assignments to queue based on configured timeouts.

**Configuration**:
```json
{
  "type": "timeout_requeue",
  "default_timeout_seconds": 3600,  // 1 hour
  "max_requeue_attempts": 3,
  "requeue_delay_seconds": 300,  // 5 min cooldown before reassignment
  "escalate_on_final_timeout": true  // Flag for manual review
}
```

**Sweep Job** (via Oban):
```elixir
defmodule Anvil.Jobs.TimeoutSweep do
  use Oban.Worker, queue: :anvil_sweeps

  def perform(_job) do
    now = DateTime.utc_now()

    Repo.update_all(
      from(a in Assignment,
        where: a.status == :reserved and a.deadline < ^now
      ),
      [set: [
        status: :timed_out,
        updated_at: ^now
      ]]
    )

    # Requeue logic based on requeue_attempts counter
    for assignment <- timed_out_assignments() do
      if assignment.requeue_attempts < max_attempts do
        requeue_with_delay(assignment, delay_seconds)
      else
        escalate_for_review(assignment)
      end
    end
  end
end
```

**State**: Adds `requeue_attempts` (integer) and `requeue_delay_until` (timestamptz) to assignments table
**Use Case**: Production queues where labelers may disconnect or abandon work

#### 5. Blocklist Policy (`Anvil.Policy.Blocklist`)

Prevents specific labelers from accessing certain queues (conflicts of interest, performance issues).

**Configuration**:
```json
{
  "type": "blocklist",
  "mode": "per_labeler"  // Options: per_labeler, per_queue
}
```

**Storage**:
- **Per-Labeler Mode**: Store in `labelers.blocklisted_queues` (UUID array)
- **Per-Queue Mode**: Store in new `queue_blocklists` table with `(queue_id, labeler_id)` pairs

**Validation** (called before assignment dispatch):
```elixir
def validate_labeler(queue_id, labeler_id) do
  labeler = Repo.get!(Labeler, labeler_id)

  if queue_id in labeler.blocklisted_queues do
    {:error, :blocked}
  else
    :ok
  end
end
```

**Use Case**: Removing labelers who consistently produce low-quality labels or have dataset contamination concerns

#### 6. Concurrency Limit Policy (`Anvil.Policy.ConcurrencyLimit`)

Caps maximum concurrent active assignments per labeler to prevent hoarding.

**Configuration**:
```json
{
  "type": "concurrency_limit",
  "max_concurrent_per_labeler": 5,
  "queue_specific_overrides": {
    "urgent_queue_id": 10
  }
}
```

**Validation**:
```elixir
def validate_labeler(queue_id, labeler_id) do
  active_count = Repo.one(
    from a in Assignment,
    where: a.labeler_id == ^labeler_id and a.status == :reserved,
    select: count(a.id)
  )

  limit = get_limit_for_queue(queue_id, labeler_id)

  if active_count >= limit do
    {:error, :max_concurrent_exceeded}
  else
    :ok
  end
end
```

**Use Case**: Preventing labeler burnout and ensuring fair work distribution across team

### Policy Composition

Policies can be stacked via a composition policy:

```elixir
defmodule Anvil.Policy.Composed do
  defstruct validators: [], selector: nil, requeue_handler: nil

  def new(opts) do
    %__MODULE__{
      validators: [
        Anvil.Policy.Blocklist,
        Anvil.Policy.ConcurrencyLimit
      ],
      selector: Anvil.Policy.WeightedExpertise,
      requeue_handler: Anvil.Policy.TimeoutRequeue
    }
  end

  def select_assignment(queue_id, labeler_id, opts) do
    with :ok <- run_validators(queue_id, labeler_id),
         {:ok, assignment} <- selector.select_assignment(queue_id, labeler_id, opts) do
      reserve_with_timeout(assignment, opts)
    end
  end
end
```

Queue configuration:
```elixir
Anvil.Queue.create(%{
  name: "cns_synthesis_labels",
  schema_version_id: schema_v1_id,
  policy: %{
    type: "composed",
    validators: ["blocklist", "concurrency_limit"],
    selector: %{type: "weighted_expertise", ...},
    requeue: %{type: "timeout_requeue", ...}
  }
})
```

### State Management

**In-Memory Caching**:
- Policy modules can cache frequently-accessed data (labeler weights, active counts) using ETS
- Cache invalidated on label submission, assignment completion, or periodic sweep (every 60s)

**Database-Backed State**:
- Authoritative state always in Postgres (assignments, labels, labeler configs)
- Caches are optimization only; can be rebuilt on process restart

**Concurrency**:
- Assignment selection queries use `FOR UPDATE SKIP LOCKED` to prevent race conditions
- Optimistic locking on assignment version prevents double-dispatch

## Consequences

### Positive

- **Flexibility**: Consumers select policy via configuration, not code changes; supports A/B testing of assignment strategies
- **Reusability**: Built-in policies cover 80% of use cases; avoid reimplementing fair distribution logic
- **Quality Enforcement**: Redundancy policy ensures sufficient labels for statistical agreement metrics (Cohen's kappa, Fleiss' kappa)
- **Operational Safety**: Timeout sweeps prevent work from getting stuck indefinitely; automatic escalation for manual review
- **Fair Distribution**: Round-robin and concurrency limits prevent labeler hoarding and ensure equitable workload
- **Access Control**: Blocklist policy supports compliance requirements (conflict-of-interest isolation, performance management)
- **Composability**: Stacking policies (validators + selector + requeue) enables sophisticated workflows without monolithic logic

### Negative

- **Complexity**: Policy engine adds abstraction layer; developers must understand multiple policy types and their interactions
- **Performance**: Weighted expertise and redundancy policies require additional queries (sample metadata, label counts); requires careful indexing
- **State Synchronization**: In-memory caches can drift from database state if invalidation logic is incorrect; requires monitoring
- **Configuration Overhead**: Per-queue policy tuning requires operational expertise; poor defaults can degrade quality or throughput
- **Testing Burden**: Each policy requires dedicated test coverage; composition multiplies test matrix
- **Migration Risk**: Changing policies mid-queue requires careful handling of in-flight assignments

### Neutral

- **Policy Evolution**: New policies can be added without breaking changes (implement behaviour, register in composition engine)
- **Metrics Integration**: Policy decisions (assignment source, requeue reason) should emit :telemetry events for observability
- **Default Policy**: If no policy specified, fall back to simple round-robin with basic timeout requeue
- **Custom Policies**: Consumers can implement `Anvil.Policy` behaviour for domain-specific logic (e.g., time-of-day routing)

## Implementation Notes

1. **Query Optimization**:
   - Index `(queue_id, status, created_at)` for round-robin
   - Denormalized `sample_label_counts` table with trigger maintenance for redundancy policy
   - ETS cache for labeler active assignment counts (refresh on every assignment state change)

2. **Oban Integration**:
   - `Anvil.Jobs.TimeoutSweep` runs every 5 minutes, processes assignments with `deadline < now()`
   - `Anvil.Jobs.PolicyCacheMaintenance` runs every 60 seconds, refreshes in-memory state
   - Job concurrency limits prevent thundering herd on large queues

3. **Telemetry Events**:
   - `[:anvil, :policy, :select_assignment, :start | :stop | :exception]` with metadata: `%{policy: type, queue_id: id}`
   - `[:anvil, :policy, :requeue, :start]` with metadata: `%{reason: :timeout, attempt: 2}`
   - `[:anvil, :policy, :validate_labeler, :blocked]` with metadata: `%{reason: :blocklist}`

4. **Configuration Validation**:
   - Validate policy configuration JSON schema at queue creation time
   - Fail fast if required fields missing or invalid policy type specified

5. **Graceful Degradation**:
   - If policy module crashes, fall back to round-robin to prevent queue starvation
   - Log errors to sentry with full policy config for debugging

6. **Testing Strategy**:
   - Unit tests for each policy in isolation with mock storage
   - Integration tests for composed policies with real Postgres
   - Load tests for timeout sweep with 100k+ timed-out assignments
