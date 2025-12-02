# ADR-002: Queue Assignment Policies

## Status

Accepted

## Context

When distributing annotation tasks to labelers, different strategies may be optimal depending on:

1. **Workload Balance**: Ensuring fair distribution of work
2. **Expertise Matching**: Assigning tasks to qualified labelers
3. **Quality Control**: Managing redundancy for inter-rater agreement
4. **Efficiency**: Minimizing idle time and maximizing throughput

We need a pluggable policy system that supports multiple assignment strategies.

## Decision

We will implement a policy-based assignment system with three built-in policies and an extension mechanism for custom policies.

### Policy Structure

```elixir
defmodule Anvil.Queue.Policy do
  @callback next_assignment(
    queue_state :: map(),
    labeler_id :: String.t(),
    available_samples :: [map()]
  ) :: {:ok, sample :: map()} | {:error, reason :: atom()}

  @callback priority_score(
    sample :: map(),
    labeler_id :: String.t(),
    context :: map()
  ) :: float()
end
```

### Built-in Policies

#### 1. Round Robin (`:round_robin`)

Assigns samples in sequential order to labelers.

**Use Case**: Fair distribution with predictable assignment order

**Algorithm**:
```
1. Track last assigned sample index per queue
2. For each labeler request, return next unassigned sample
3. Wrap around to beginning when reaching end
```

**Advantages**:
- Perfectly balanced workload
- Simple and predictable
- No configuration required

**Disadvantages**:
- Ignores labeler expertise
- May assign difficult samples to novices

#### 2. Random (`:random`)

Randomly assigns available samples.

**Use Case**: Eliminating assignment bias, A/B testing

**Algorithm**:
```
1. Filter available samples for labeler
2. Select random sample from available pool
3. Mark as assigned
```

**Advantages**:
- Eliminates systematic bias
- Good for quality control testing
- Simple implementation

**Disadvantages**:
- Less predictable workload distribution
- No expertise matching

#### 3. Expertise-Based (`:expertise`)

Assigns samples based on labeler expertise scores and sample difficulty.

**Use Case**: Maximizing quality by matching task complexity to skill level

**Configuration**:
```elixir
%{
  type: :expertise,
  expertise_scores: %{
    "labeler_1" => 0.95,
    "labeler_2" => 0.70
  },
  min_expertise: 0.6,
  sample_difficulty: %{
    "sample_1" => 0.8,  # Difficult
    "sample_2" => 0.3   # Easy
  }
}
```

**Algorithm**:
```
1. Calculate assignment score = labeler_expertise - sample_difficulty
2. Only assign if labeler_expertise >= min_expertise
3. Prefer assignments with higher scores
```

**Advantages**:
- Quality optimization
- Efficient use of expert time
- Supports skill-based routing

**Disadvantages**:
- Requires expertise data
- More complex configuration
- Risk of overloading experts

### Queue Configuration

```elixir
{:ok, queue} = Anvil.Queue.start_link(
  queue_id: "my_queue",
  schema: schema,
  policy: :round_robin,  # or :random, :expertise, {CustomPolicy, config}
  labels_per_sample: 3   # Multiple assignments for agreement
)
```

### Custom Policy Implementation

```elixir
defmodule MyCustomPolicy do
  @behaviour Anvil.Queue.Policy

  def next_assignment(queue_state, labeler_id, available_samples) do
    # Custom logic here
    {:ok, selected_sample}
  end

  def priority_score(sample, labeler_id, context) do
    # Calculate priority score
    1.0
  end
end

# Usage
{:ok, queue} = Anvil.Queue.start_link(
  queue_id: "custom_queue",
  schema: schema,
  policy: {MyCustomPolicy, %{custom_config: "value"}}
)
```

## Consequences

### Positive

- **Flexibility**: Supports diverse use cases without core changes
- **Extensibility**: Custom policies can implement domain-specific logic
- **Testability**: Policies are pure functions, easy to test
- **Performance**: Policy selection happens at queue creation, not per-assignment

### Negative

- **Complexity**: Multiple policies increase cognitive load
- **Configuration**: Expertise-based policy requires additional data
- **Debugging**: Understanding why a particular assignment was made may be unclear

### Mitigation

- Provide detailed logging for assignment decisions
- Document common patterns and use cases for each policy
- Add introspection API to explain assignment rationale
- Include policy simulation tools for testing before deployment

## Implementation Notes

### State Management

Each queue maintains:
```elixir
%{
  policy: :round_robin,
  policy_config: %{},
  policy_state: %{
    last_assigned_index: 0,
    assignments_per_labeler: %{}
  }
}
```

### Concurrency

- Assignment requests are serialized through GenServer
- Policy functions must be pure (no side effects)
- State updates are atomic within queue process

### Performance Considerations

- Cache policy calculations when possible
- Limit available_samples list size for large queues
- Index samples by relevant attributes (difficulty, tags, etc.)

## Alternatives Considered

### 1. Hard-Coded Single Policy

**Rejected** because:
- Not flexible enough for diverse use cases
- Would require core changes for new strategies
- Limits experimentation

### 2. External Assignment Service

**Rejected** because:
- Adds latency and complexity
- Harder to maintain consistency
- More difficult to test

### 3. ML-Based Assignment

**Rejected** for initial version because:
- Too complex for v1
- Requires training data
- Harder to understand and debug
- Could be added as custom policy later

## References

- [Task Assignment in Crowdsourcing](https://dl.acm.org/doi/10.1145/2976749.2978315)
- [Expertise-Aware Task Assignment](https://arxiv.org/abs/1709.05273)
- [Work Distribution Strategies in Collaborative Systems](https://www.sciencedirect.com/science/article/pii/S0167739X16304101)
