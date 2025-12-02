# ADR-003: Label Validation Strategy

## Status

Accepted

## Context

Label quality is critical for machine learning model performance. Poor quality labels lead to:

1. **Model Degradation**: Garbage in, garbage out
2. **Wasted Resources**: Time and money spent on bad data
3. **Incorrect Metrics**: Agreement metrics are meaningless with invalid data
4. **Cascading Failures**: Downstream systems assume valid input

We need a comprehensive validation strategy that catches errors early while remaining flexible enough for diverse use cases.

## Decision

We will implement a multi-layered validation strategy with both schema-based and custom validation.

### Validation Layers

#### Layer 1: Schema Validation (Mandatory)

All labels must pass schema validation before being accepted.

**Checks**:
- Required fields are present
- Field types match schema definition
- Values are within allowed ranges/options
- Patterns match (for text fields)

**Example**:
```elixir
schema = Anvil.Schema.new(
  name: "sentiment",
  fields: [
    %Anvil.Schema.Field{
      name: "score",
      type: :range,
      required: true,
      min: 1,
      max: 5
    }
  ]
)

# Valid
Anvil.Schema.validate(schema, %{"score" => 3})
# => {:ok, %{"score" => 3}}

# Invalid - out of range
Anvil.Schema.validate(schema, %{"score" => 10})
# => {:error, [%{field: "score", error: "must be between 1 and 5"}]}

# Invalid - missing required
Anvil.Schema.validate(schema, %{})
# => {:error, [%{field: "score", error: "is required"}]}
```

#### Layer 2: Quality Control Checks (Optional)

Additional validation rules configured per-queue:

**Minimum Labeling Time**:
```elixir
quality_control: %{
  min_labeling_time: 5  # seconds
}
```
Rejects labels submitted too quickly (likely indicating inattention).

**Gold Standard Samples**:
```elixir
quality_control: %{
  gold_standard_samples: %{
    "sample_1" => %{"category" => "cat"},
    "sample_2" => %{"category" => "dog"}
  },
  gold_standard_threshold: 0.8  # 80% accuracy required
}
```
Periodically inject known-correct samples to verify labeler quality.

**Consistency Checks**:
```elixir
quality_control: %{
  consistency_checks: [
    {:conditional, "if field A is X, field B must be Y"}
  ]
}
```
Enforce logical relationships between fields.

#### Layer 3: Custom Validators (Optional)

User-defined validation functions for domain-specific rules:

```elixir
custom_validator = fn values ->
  # Custom validation logic
  if values["sentiment"] == "positive" and values["score"] < 3 do
    {:error, "Positive sentiment must have score >= 3"}
  else
    :ok
  end
end

{:ok, queue} = Anvil.create_queue(
  queue_id: "my_queue",
  schema: schema,
  validators: [custom_validator]
)
```

### Validation Flow

```
Label Submission
    |
    v
[1. Schema Validation]
    |
    ├─> Invalid -> Return errors immediately
    |
    v
[2. Quality Control Checks]
    |
    ├─> Failed -> Return errors + flag labeler
    |
    v
[3. Custom Validators]
    |
    ├─> Failed -> Return errors
    |
    v
[Accept Label]
    |
    v
[Store + Update Metrics]
```

### Error Reporting

Validation errors are structured and actionable:

```elixir
{:error, [
  %{
    field: "category",
    error: "must be one of: cat, dog, bird",
    provided: "fish",
    layer: :schema
  },
  %{
    field: nil,
    error: "labeling time too short (2s < 5s minimum)",
    layer: :quality_control
  }
]}
```

### Labeler Feedback Loop

Failed validations are tracked per-labeler:

```elixir
labeler_stats = %{
  "labeler_1" => %{
    total_submissions: 100,
    schema_errors: 5,
    quality_control_errors: 2,
    custom_validator_errors: 1,
    accuracy_on_gold: 0.92
  }
}
```

This enables:
- Identifying struggling labelers for retraining
- Automatic removal of consistently poor labelers
- Personalized feedback and guidance

## Consequences

### Positive

- **Data Quality**: Ensures only valid labels enter the system
- **Fast Feedback**: Labelers get immediate error messages
- **Flexibility**: Custom validators support any domain logic
- **Metrics**: Tracking validation failures provides quality insights
- **Prevention**: Catches errors before they pollute datasets

### Negative

- **Complexity**: Multiple validation layers increase system complexity
- **Performance**: Validation adds latency to label submission
- **False Positives**: Overly strict validation may reject valid edge cases
- **Configuration Burden**: Setting up quality control requires tuning

### Mitigation

- Cache validation results where appropriate
- Provide clear documentation with examples
- Add configuration presets for common scenarios
- Log all validation failures for debugging
- Allow validation rules to be updated without queue restart

## Implementation Details

### Performance Optimization

```elixir
# Schema validation is memoized
defmodule Anvil.Schema do
  use Memoize

  @decorate memoize(max_entries: 1000)
  def validate(schema, values) do
    # Validation logic
  end
end
```

### Graceful Degradation

If validation layers fail (e.g., due to bugs), the system should:
1. Log the error
2. Fall back to schema-only validation
3. Alert administrators
4. Continue processing

### Testing Support

Provide test helpers for validation:

```elixir
# In tests
test "validates sentiment labels" do
  schema = build_sentiment_schema()

  assert {:ok, _} = Anvil.Schema.validate(schema, %{"score" => 3})
  assert {:error, _} = Anvil.Schema.validate(schema, %{"score" => 10})
end
```

## Alternatives Considered

### 1. Validation Only at Export Time

**Rejected** because:
- Errors discovered too late
- No feedback to labelers
- Wasted labeling effort
- Harder to fix invalid data

### 2. External Validation Service

**Rejected** because:
- Adds latency and complexity
- Harder to maintain consistency
- More difficult to test
- Network failures could block labeling

### 3. ML-Based Anomaly Detection

**Rejected** for initial version because:
- Requires training data
- Hard to explain to users why a label was rejected
- Could be added as custom validator later
- Too complex for v1

### 4. Blockchain-Based Validation

**Rejected** because:
- Massive overkill for the problem
- Performance implications
- Unnecessary complexity
- Immutability conflicts with error correction

## References

- [Data Validation Best Practices](https://www.oreilly.com/library/view/reliable-machine-learning/9781098106218/)
- [Crowdsourcing Quality Control](https://dl.acm.org/doi/10.1145/2470654.2470660)
- [Input Validation Patterns](https://cheatsheetseries.owasp.org/cheatsheets/Input_Validation_Cheat_Sheet.html)
- [Design by Contract](https://en.wikipedia.org/wiki/Design_by_contract)
