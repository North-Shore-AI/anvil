# ADR-006: Assignment Lifecycle States

## Status

Accepted

## Context

Assignments flow through multiple states from creation to completion. Clear state management is critical for:

1. **Progress Tracking**: Understanding where work stands
2. **Timeout Handling**: Reclaiming expired assignments
3. **Quality Control**: Identifying abandoned or problematic assignments
4. **Metrics**: Computing throughput, completion rates, etc.
5. **Labeler Experience**: Providing clear status to labelers

The state machine must handle:
- Normal completion flow
- Timeout scenarios
- Labeler-initiated skips
- System failures
- Reassignment logic

## Decision

We will implement a state machine with 5 core states and well-defined transitions.

### Assignment States

```elixir
@type assignment_status ::
  :pending |
  :in_progress |
  :completed |
  :expired |
  :skipped
```

#### 1. `:pending`

**Description**: Assignment created but not yet started by labeler.

**Entry Conditions**:
- Queue assigns sample to labeler
- Sufficient samples available
- Labeler eligible for assignment

**Properties**:
```elixir
%Assignment{
  id: "assign_123",
  status: :pending,
  sample_id: "sample_1",
  labeler_id: "labeler_1",
  queue_id: "queue_1",
  deadline: nil,
  attempts: 0,
  created_at: ~U[2024-01-15 10:00:00Z],
  started_at: nil,
  completed_at: nil
}
```

**Exit Transitions**:
- `start_assignment/1` → `:in_progress`
- `timeout_check/1` → `:expired` (if pre-assignment timeout configured)

#### 2. `:in_progress`

**Description**: Labeler actively working on the assignment.

**Entry Conditions**:
- Labeler calls `start_assignment/1`
- Assignment was in `:pending` state

**Properties**:
```elixir
%Assignment{
  status: :in_progress,
  deadline: ~U[2024-01-15 11:00:00Z],  # Set when started
  started_at: ~U[2024-01-15 10:05:00Z],
  attempts: 1
}
```

**Exit Transitions**:
- `submit_label/2` → `:completed` (on successful validation)
- `skip_assignment/1` → `:skipped`
- `timeout_check/1` → `:expired` (if deadline passed)

#### 3. `:completed`

**Description**: Label successfully submitted and validated.

**Entry Conditions**:
- Labeler submits valid label
- Label passes all validation layers

**Properties**:
```elixir
%Assignment{
  status: :completed,
  completed_at: ~U[2024-01-15 10:15:00Z],
  label_id: "label_456"
}
```

**Exit Transitions**:
- None (terminal state)

**Note**: Completed assignments are immutable. If corrections are needed, create a new assignment.

#### 4. `:expired`

**Description**: Deadline passed without completion.

**Entry Conditions**:
- Background process checks deadlines
- Current time > assignment deadline
- Assignment still in `:in_progress` or `:pending`

**Properties**:
```elixir
%Assignment{
  status: :expired,
  expired_at: ~U[2024-01-15 11:00:01Z]
}
```

**Exit Transitions**:
- `reassign/1` → creates new `:pending` assignment (to same or different labeler)

**Reassignment Logic**:
```elixir
# Option 1: Reassign to same labeler (they can retry)
if assignment.attempts < max_attempts do
  create_assignment(assignment.sample_id, assignment.labeler_id)
end

# Option 2: Reassign to different labeler
if assignment.attempts >= max_attempts do
  assign_to_different_labeler(assignment.sample_id)
end
```

#### 5. `:skipped`

**Description**: Labeler chose to skip this assignment.

**Entry Conditions**:
- Labeler calls `skip_assignment/1`
- Assignment was in `:in_progress`

**Properties**:
```elixir
%Assignment{
  status: :skipped,
  skipped_at: ~U[2024-01-15 10:08:00Z],
  skip_reason: "Image quality too poor"  # Optional
}
```

**Exit Transitions**:
- `reassign/1` → creates new `:pending` assignment (always to different labeler)

**Reassignment Logic**:
```elixir
# Never reassign skipped assignment to same labeler
eligible_labelers = queue.labelers -- [assignment.labeler_id]
assign_to_next_labeler(assignment.sample_id, eligible_labelers)
```

### State Transition Diagram

```
    ┌─────────┐
    │ PENDING │
    └────┬────┘
         │ start_assignment/1
         ▼
  ┌──────────────┐
  │ IN_PROGRESS  │
  └──┬─────────┬─┘
     │         │
     │         │ skip_assignment/1
     │         ▼
     │    ┌─────────┐     reassign/1    ┌─────────┐
     │    │ SKIPPED ├─────────────────► │ PENDING │
     │    └─────────┘                    └─────────┘
     │
     │ submit_label/2
     │ (valid)
     ▼
┌───────────┐
│ COMPLETED │
└───────────┘

  [Both PENDING and IN_PROGRESS]
     │ timeout_check/1
     ▼
┌──────────┐     reassign/1    ┌─────────┐
│ EXPIRED  ├─────────────────► │ PENDING │
└──────────┘                    └─────────┘
```

### API Functions

```elixir
# Get next pending assignment for labeler
{:ok, assignment} = Anvil.get_next_assignment(queue, "labeler_1")
# => %Assignment{status: :pending}

# Start working on assignment
{:ok, assignment} = Anvil.start_assignment(assignment.id)
# => %Assignment{status: :in_progress, deadline: ~U[...]}

# Submit label
{:ok, label} = Anvil.submit_label(assignment.id, %{"category" => "cat"})
# => Assignment transitions to :completed

# Skip assignment
{:ok, assignment} = Anvil.skip_assignment(assignment.id, reason: "unclear image")
# => Assignment transitions to :skipped

# Background timeout check (run periodically)
expired = Anvil.check_expired_assignments(queue)
# => [%Assignment{status: :expired}, ...]
```

### Configuration

```elixir
{:ok, queue} = Anvil.Queue.start_link(
  queue_id: "my_queue",
  schema: schema,
  assignment_config: %{
    timeout_seconds: 3600,           # 1 hour per assignment
    pre_assignment_timeout: 300,     # 5 min to start or expire
    max_attempts_per_labeler: 3,     # Max retries for same labeler
    max_attempts_total: 5,           # Max attempts across all labelers
    reassign_expired: true,          # Auto-reassign expired assignments
    reassign_skipped: true,          # Auto-reassign skipped assignments
    skip_requires_reason: false      # Make skip reason optional
  }
)
```

## Consequences

### Positive

- **Clear Semantics**: Each state has well-defined meaning
- **Audit Trail**: State transitions are trackable
- **Timeout Handling**: Automatic reclamation of stalled work
- **Flexibility**: Skip mechanism prevents forcing bad labels
- **Reliability**: Failed labelers don't block progress

### Negative

- **Complexity**: State machine adds cognitive overhead
- **Timing Issues**: Race conditions between timeout checks and submissions
- **Reassignment Logic**: Complex rules for when/how to reassign
- **Storage**: Need to track state history for analytics

### Mitigation

- Comprehensive documentation with state diagrams
- Atomic state transitions in GenServer
- Clear logging of all state changes
- Idempotent operations where possible
- Background job for timeout checks with proper locking

## Implementation Details

### Assignment Struct

```elixir
defmodule Anvil.Assignment do
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
end
```

### State Transition Functions

```elixir
defmodule Anvil.Assignment do
  def start(assignment = %{status: :pending}) do
    now = DateTime.utc_now()
    deadline = DateTime.add(now, assignment.timeout_seconds, :second)

    {:ok, %{assignment |
      status: :in_progress,
      started_at: now,
      deadline: deadline,
      attempts: assignment.attempts + 1
    }}
  end
  def start(%{status: status}) do
    {:error, {:invalid_transition, status, :in_progress}}
  end

  def complete(assignment = %{status: :in_progress}, label_id) do
    {:ok, %{assignment |
      status: :completed,
      completed_at: DateTime.utc_now(),
      label_id: label_id
    }}
  end

  def skip(assignment = %{status: :in_progress}, reason \\ nil) do
    {:ok, %{assignment |
      status: :skipped,
      skipped_at: DateTime.utc_now(),
      skip_reason: reason
    }}
  end

  def expire(assignment) when assignment.status in [:pending, :in_progress] do
    {:ok, %{assignment |
      status: :expired,
      expired_at: DateTime.utc_now()
    }}
  end
end
```

### Background Timeout Worker

```elixir
defmodule Anvil.TimeoutWorker do
  use GenServer

  def init(queue_id) do
    schedule_check()
    {:ok, %{queue_id: queue_id}}
  end

  def handle_info(:check_timeouts, state) do
    check_and_expire_assignments(state.queue_id)
    schedule_check()
    {:noreply, state}
  end

  defp check_and_expire_assignments(queue_id) do
    now = DateTime.utc_now()

    Storage.list_assignments(queue_id, status: [:pending, :in_progress])
    |> Enum.filter(&past_deadline?(&1, now))
    |> Enum.each(&expire_and_reassign/1)
  end

  defp schedule_check do
    Process.send_after(self(), :check_timeouts, 60_000)  # Check every minute
  end
end
```

### Metrics and Analytics

Track state transition metrics:

```elixir
defmodule Anvil.Metrics do
  def assignment_metrics(queue_id) do
    assignments = Storage.list_assignments(queue_id)

    %{
      total: length(assignments),
      by_status: count_by_status(assignments),
      completion_rate: completion_rate(assignments),
      avg_time_to_complete: avg_completion_time(assignments),
      avg_attempts: avg_attempts(assignments),
      skip_rate: skip_rate(assignments),
      expire_rate: expire_rate(assignments)
    }
  end
end
```

## Alternatives Considered

### 1. Add `:assigned` State (Between Pending and In Progress)

**Rejected** because:
- Adds complexity with minimal benefit
- `:pending` effectively means "assigned but not started"
- Can use `started_at == nil` to distinguish

### 2. Add `:cancelled` State

**Rejected** because:
- Use case is rare (queue shutdown?)
- Can mark queue as inactive instead
- Adds complexity to state machine

### 3. Allow Transitions from `:completed` to `:in_progress` (Revisions)

**Rejected** because:
- Complicates immutability guarantees
- Better to create new assignment for revisions
- Preserves audit trail
- Prevents accidental data loss

### 4. Single `:failed` State Instead of `:expired` and `:skipped`

**Rejected** because:
- Different semantics and reassignment rules
- Important to distinguish labeler choice vs system timeout
- Metrics need to separate these cases

### 5. Add `:validated` State (After Completion)

**Rejected** because:
- Validation happens synchronously during submission
- `:completed` implies validated
- Post-hoc validation should be separate process

## Testing Strategy

```elixir
defmodule Anvil.AssignmentLifecycleTest do
  use Supertester.ExUnitFoundation, isolation: :full_isolation

  describe "state transitions" do
    test "pending -> in_progress -> completed" do
      assignment = create_assignment(:pending)

      {:ok, assignment} = Assignment.start(assignment)
      assert assignment.status == :in_progress
      assert assignment.started_at
      assert assignment.deadline

      {:ok, assignment} = Assignment.complete(assignment, "label_123")
      assert assignment.status == :completed
      assert assignment.completed_at
    end

    test "cannot complete pending assignment" do
      assignment = create_assignment(:pending)

      {:error, {:invalid_transition, :pending, :completed}} =
        Assignment.complete(assignment, "label_123")
    end

    test "in_progress -> skipped" do
      assignment = create_assignment(:in_progress)

      {:ok, assignment} = Assignment.skip(assignment, "bad image")
      assert assignment.status == :skipped
      assert assignment.skip_reason == "bad image"
    end

    test "in_progress -> expired (timeout)" do
      assignment = create_assignment(:in_progress, deadline: past_time())

      {:ok, assignment} = Assignment.expire(assignment)
      assert assignment.status == :expired
    end
  end

  chaos "handles concurrent state transitions" do
    assignment_id = create_assignment(:in_progress).id

    # Simulate race condition: timeout check vs submission
    tasks = [
      Task.async(fn -> Assignment.complete(assignment_id, "label_1") end),
      Task.async(fn -> Assignment.expire(assignment_id) end)
    ]

    results = Task.await_many(tasks)

    # One should succeed, one should fail
    assert {:ok, _} in results
    assert {:error, _} in results
  end
end
```

## References

- [Finite State Machines](https://en.wikipedia.org/wiki/Finite-state_machine)
- [State Pattern (Gang of Four)](https://en.wikipedia.org/wiki/State_pattern)
- [Idempotent State Transitions](https://martinfowler.com/articles/patterns-of-distributed-systems/idempotent-receiver.html)
- [Task Assignment Systems](https://dl.acm.org/doi/10.1145/3308558.3313652)
