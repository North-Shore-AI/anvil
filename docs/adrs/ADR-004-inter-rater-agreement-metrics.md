# ADR-004: Inter-Rater Agreement Metrics

## Status

Accepted

## Context

When multiple labelers annotate the same samples, measuring agreement helps:

1. **Quality Assessment**: High agreement suggests clear task definition and quality labels
2. **Labeler Reliability**: Identify labelers who consistently disagree with others
3. **Task Clarity**: Low agreement may indicate ambiguous instructions
4. **Stopping Criteria**: Determine when sufficient labels have been collected
5. **Research Validity**: Agreement metrics are often required for publication

Different metrics are appropriate for different scenarios:
- Number of raters (2 vs many)
- Missing data tolerance
- Categorical vs ordinal vs continuous labels
- Chance correction requirements

## Decision

We will implement three inter-rater agreement metrics, each suited to different use cases:

### 1. Cohen's Kappa (κ)

**Use Case**: Two raters, categorical data

**Formula**:
```
κ = (p_o - p_e) / (1 - p_e)

where:
p_o = observed agreement
p_e = expected agreement by chance
```

**Range**: -1 to 1
- κ < 0: Agreement worse than chance
- κ = 0: Agreement equal to chance
- κ = 0.01-0.20: Slight agreement
- κ = 0.21-0.40: Fair agreement
- κ = 0.41-0.60: Moderate agreement
- κ = 0.61-0.80: Substantial agreement
- κ = 0.81-1.00: Almost perfect agreement

**API**:
```elixir
labels_rater1 = [
  %{sample_id: "s1", value: "cat"},
  %{sample_id: "s2", value: "dog"},
  %{sample_id: "s3", value: "cat"}
]

labels_rater2 = [
  %{sample_id: "s1", value: "cat"},
  %{sample_id: "s2", value: "cat"},
  %{sample_id: "s3", value: "cat"}
]

{:ok, kappa} = Anvil.Agreement.Cohen.compute(labels_rater1, labels_rater2)
# => {:ok, 0.333}
```

**Advantages**:
- Well-established and widely recognized
- Corrects for chance agreement
- Simple interpretation

**Disadvantages**:
- Only works with exactly 2 raters
- Requires complete data (no missing values)
- Assumes raters use all categories equally

### 2. Fleiss' Kappa (κ)

**Use Case**: Three or more raters, categorical data, fixed raters per sample

**Formula**:
```
κ = (P̄ - P̄_e) / (1 - P̄_e)

where:
P̄ = mean observed agreement across samples
P̄_e = expected agreement by chance
```

**Range**: Same interpretation as Cohen's kappa

**API**:
```elixir
# Multiple raters labeling the same samples
labels = [
  %{sample_id: "s1", labeler_id: "l1", value: "cat"},
  %{sample_id: "s1", labeler_id: "l2", value: "cat"},
  %{sample_id: "s1", labeler_id: "l3", value: "dog"},
  %{sample_id: "s2", labeler_id: "l1", value: "dog"},
  %{sample_id: "s2", labeler_id: "l2", value: "dog"},
  %{sample_id: "s2", labeler_id: "l3", value: "dog"}
]

{:ok, kappa} = Anvil.Agreement.Fleiss.compute(labels)
# => {:ok, 0.667}
```

**Advantages**:
- Extends Cohen's kappa to multiple raters
- Corrects for chance agreement
- Raters can vary across samples (unlike some alternatives)

**Disadvantages**:
- Requires same number of ratings per sample
- Sensitive to category prevalence
- Assumes all raters use same rating strategy

### 3. Krippendorff's Alpha (α)

**Use Case**: Any number of raters, any data type, handles missing data

**Formula**:
```
α = 1 - (D_o / D_e)

where:
D_o = observed disagreement
D_e = expected disagreement by chance
```

**Range**: 0 to 1
- α = 0: No agreement beyond chance
- α = 0.667: Minimum for tentative conclusions
- α = 0.800: Minimum for reliable conclusions
- α = 1.000: Perfect agreement

**API**:
```elixir
# Works with missing data and different numbers of raters per sample
labels = [
  %{sample_id: "s1", labeler_id: "l1", value: "cat"},
  %{sample_id: "s1", labeler_id: "l2", value: "cat"},
  # s1 has 2 raters
  %{sample_id: "s2", labeler_id: "l1", value: "dog"},
  %{sample_id: "s2", labeler_id: "l2", value: "dog"},
  %{sample_id: "s2", labeler_id: "l3", value: "dog"}
  # s2 has 3 raters
]

{:ok, alpha} = Anvil.Agreement.Krippendorff.compute(labels, metric: :nominal)
# => {:ok, 0.750}

# Supports different distance metrics
{:ok, alpha} = Anvil.Agreement.Krippendorff.compute(labels, metric: :ordinal)
{:ok, alpha} = Anvil.Agreement.Krippendorff.compute(labels, metric: :interval)
{:ok, alpha} = Anvil.Agreement.Krippendorff.compute(labels, metric: :ratio)
```

**Distance Metrics**:
- `:nominal` - Categorical data, no ordering
- `:ordinal` - Ordered categories (e.g., ratings 1-5)
- `:interval` - Numeric with equal intervals (e.g., temperature)
- `:ratio` - Numeric with true zero (e.g., count)

**Advantages**:
- Handles missing data gracefully
- Works with any number of raters
- Supports multiple data types
- Most flexible metric

**Disadvantages**:
- More complex to compute
- Less widely known than kappa
- Requires more data for stability

### Metric Selection Guide

```elixir
# Automatic metric selection based on data
defmodule Anvil.Agreement do
  def compute(labels, opts \\ []) do
    cond do
      exactly_two_raters?(labels) ->
        Cohen.compute(labels, opts)

      fixed_raters_per_sample?(labels) and categorical?(labels) ->
        Fleiss.compute(labels, opts)

      true ->
        Krippendorff.compute(labels, opts)
    end
  end
end

# Or explicit metric selection
Anvil.Agreement.compute(labels, metric: :cohen)
Anvil.Agreement.compute(labels, metric: :fleiss)
Anvil.Agreement.compute(labels, metric: :krippendorff)
```

## Consequences

### Positive

- **Comprehensive Coverage**: Supports all common scenarios
- **Research-Grade**: Metrics are academically validated
- **Flexibility**: Automatic or manual metric selection
- **Missing Data**: Krippendorff's alpha handles incomplete data
- **Data Types**: Support for categorical, ordinal, and continuous labels

### Negative

- **Complexity**: Multiple metrics increases learning curve
- **Performance**: Agreement computation can be expensive for large datasets
- **Interpretation**: Users must understand when to use which metric
- **Dependencies**: Complex mathematical computations

### Mitigation

- Provide clear documentation with decision tree for metric selection
- Implement performance optimizations (caching, parallel computation)
- Add warnings when metric may not be appropriate
- Include benchmarks in test suite
- Provide interpretation helpers (e.g., "substantial agreement")

## Implementation Details

### Performance Optimization

```elixir
# Parallel computation for large datasets
defmodule Anvil.Agreement.Krippendorff do
  def compute(labels, opts) do
    labels
    |> chunk_by_sample()
    |> Task.async_stream(&compute_sample_agreement/1)
    |> Enum.reduce(&combine_results/2)
  end
end

# Caching for repeated computations
defmodule Anvil.Agreement.Cache do
  def get_or_compute(labels, metric, opts) do
    cache_key = cache_key(labels, metric, opts)

    case get(cache_key) do
      {:ok, result} -> {:ok, result}
      :miss -> compute_and_cache(labels, metric, opts, cache_key)
    end
  end
end
```

### Progressive Computation

For streaming/real-time scenarios:

```elixir
# Initialize agreement tracker
tracker = Anvil.Agreement.Tracker.new(metric: :fleiss)

# Add labels incrementally
tracker = Anvil.Agreement.Tracker.add_label(tracker, label1)
tracker = Anvil.Agreement.Tracker.add_label(tracker, label2)

# Get current agreement estimate
{:ok, current_kappa} = Anvil.Agreement.Tracker.current_value(tracker)
```

### Confidence Intervals

Provide confidence intervals via bootstrapping:

```elixir
{:ok, result} = Anvil.Agreement.Cohen.compute(
  labels1,
  labels2,
  confidence_interval: 0.95,
  bootstrap_iterations: 1000
)

# => {:ok, %{
#      kappa: 0.75,
#      ci_lower: 0.68,
#      ci_upper: 0.82,
#      confidence: 0.95
#    }}
```

## Alternatives Considered

### 1. Only Implement Cohen's Kappa

**Rejected** because:
- Insufficient for >2 raters
- Real-world scenarios often need more flexibility
- Missing data is common in practice

### 2. Only Implement Krippendorff's Alpha

**Rejected** because:
- Cohen's and Fleiss' kappa are more widely recognized
- Simpler metrics are easier to understand
- Performance concerns for simple cases

### 3. Percent Agreement Only

**Rejected** because:
- Doesn't correct for chance agreement
- Not acceptable for research/publication
- Misleading for imbalanced categories

### 4. Use External Statistics Library

**Rejected** because:
- Want full control over implementation
- Optimize for our specific use case
- Reduce external dependencies
- Domain-specific optimizations possible

## Testing Strategy

Each metric implementation includes:

1. **Unit Tests**: Known examples with expected values
2. **Property Tests**: Mathematical properties (e.g., symmetry)
3. **Performance Tests**: Ensure acceptable performance at scale
4. **Edge Cases**: Missing data, all agree, all disagree, etc.

```elixir
defmodule Anvil.Agreement.CohenTest do
  use Supertester.ExUnitFoundation, isolation: :full_isolation

  property "kappa is symmetric" do
    check all labels1 <- label_list(),
              labels2 <- label_list() do
      {:ok, k1} = Cohen.compute(labels1, labels2)
      {:ok, k2} = Cohen.compute(labels2, labels1)
      assert_in_delta k1, k2, 0.001
    end
  end

  performance "handles large datasets efficiently" do
    labels1 = generate_labels(10_000)
    labels2 = generate_labels(10_000)

    assert_performs fn ->
      Cohen.compute(labels1, labels2)
    end, under: :milliseconds, count: 100
  end
end
```

## References

- [Cohen's Kappa](https://en.wikipedia.org/wiki/Cohen%27s_kappa)
- [Fleiss' Kappa](https://en.wikipedia.org/wiki/Fleiss%27_kappa)
- [Krippendorff's Alpha](https://en.wikipedia.org/wiki/Krippendorff%27s_alpha)
- [Measuring Agreement: Calculating and Using Scores and Metrics (Hayes & Krippendorff, 2007)](https://www.researchgate.net/publication/258050627)
- [Inter-Rater Reliability: The Kappa Statistic](https://www.ncbi.nlm.nih.gov/pmc/articles/PMC3900052/)
