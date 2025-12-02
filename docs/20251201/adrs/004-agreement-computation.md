# ADR-004: Inter-Rater Agreement Computation

## Status
Accepted

## Context

Inter-rater reliability (IRR) metrics quantify the consistency of labels across multiple annotators, essential for:

- **Quality Assurance**: Low agreement indicates unclear guidelines, ambiguous samples, or unreliable labelers
- **Dataset Validation**: High-stakes applications (medical diagnosis, legal discovery) require statistical confidence in labels
- **Labeler Performance**: Individual agreement scores identify training needs or poor performers
- **Experimental Design**: Power analysis requires agreement estimates to determine required sample sizes
- **Publication**: Academic papers mandate IRR reporting (e.g., Nature journals require κ ≥ 0.8 for human annotation studies)

Common agreement metrics have different statistical properties and applicability:

| Metric | Use Case | Raters | Missing Data | Accounts for Chance |
|--------|----------|--------|--------------|---------------------|
| Percent Agreement | Quick sanity check | 2+ | No | No (inflated for imbalanced data) |
| Cohen's Kappa | Standard 2-rater | 2 | No | Yes |
| Fleiss' Kappa | Multiple raters, complete data | 3+ | No | Yes |
| Krippendorff's Alpha | Missing data, ordinal scales | 2+ | Yes | Yes (most conservative) |
| ICC | Continuous ratings | 2+ | Partial | Yes |

CNS synthesis labeling exemplifies complexity:
- **Multi-Dimensional**: coherence, grounded, balance, novelty rated independently
- **Redundancy**: k=3 labelers per sample for statistical power
- **Missing Data**: Labelers may skip dimensions or timeout on assignments
- **Scale Mixing**: Boolean (coherence), ordinal (1-5 Likert), and free-text (notes)

Without systematic agreement computation, teams resort to ad-hoc spreadsheet analysis, producing inconsistent metrics and delaying quality feedback.

## Decision

We will implement a flexible agreement computation system with automatic metric selection, per-dimension analysis, and online/batch modes.

### Architecture

#### 1. Agreement Computation Modes

**Online (Incremental)**:
```elixir
# Triggered on every label submission via Postgres trigger or Phoenix PubSub
defmodule Anvil.Agreement.Online do
  def update_on_label_submit(label) do
    # Update running statistics for affected sample
    sample_id = get_sample_id(label.assignment_id)
    existing_labels = get_labels_for_sample(sample_id)

    if length(existing_labels) >= 2 do
      # Sufficient labels to compute agreement
      agreement = compute_pairwise(existing_labels)
      upsert_agreement_cache(sample_id, agreement)
    end
  end
end
```

**Batch (Recompute)**:
```elixir
# Oban job for full recomputation (run nightly or on-demand)
defmodule Anvil.Jobs.AgreementRecompute do
  use Oban.Worker, queue: :anvil_analytics

  def perform(%{queue_id: queue_id}) do
    samples = get_samples_with_multiple_labels(queue_id)

    for sample <- samples do
      labels = get_labels_for_sample(sample.id)
      agreement = Anvil.Agreement.compute(labels, opts)
      upsert_agreement_result(sample.id, agreement)
    end
  end
end
```

**Rationale**:
- Online mode provides real-time feedback for labeler quality monitoring
- Batch mode ensures correctness after migrations, requeues, or metric changes
- Batch runs are idempotent; can recover from crashes

#### 2. Automatic Metric Selection

```elixir
defmodule Anvil.Agreement.Metrics do
  def select_metric(labels, field_schema) do
    labeler_count = Enum.uniq_by(labels, & &1.labeler_id) |> length()
    has_missing = Enum.any?(labels, &is_nil(&1.payload[field]))

    cond do
      has_missing -> :krippendorff_alpha
      labeler_count == 2 -> :cohen_kappa
      labeler_count >= 3 -> :fleiss_kappa
      true -> :percent_agreement
    end
  end
end
```

**Metric Implementations**:

**Cohen's Kappa** (2 raters):
```elixir
def cohen_kappa(labels_a, labels_b) do
  # Build confusion matrix
  pairs = Enum.zip(labels_a, labels_b)
  observed_agreement = Enum.count(pairs, fn {a, b} -> a == b end) / length(pairs)

  # Marginal probabilities
  p_a = label_distribution(labels_a)
  p_b = label_distribution(labels_b)

  expected_agreement =
    Enum.map(p_a, fn {category, prob_a} ->
      prob_b = Map.get(p_b, category, 0)
      prob_a * prob_b
    end)
    |> Enum.sum()

  kappa = (observed_agreement - expected_agreement) / (1 - expected_agreement)
  %{metric: :cohen_kappa, value: kappa, interpretation: interpret_kappa(kappa)}
end

defp interpret_kappa(k) when k < 0, do: "poor (worse than chance)"
defp interpret_kappa(k) when k < 0.20, do: "slight"
defp interpret_kappa(k) when k < 0.40, do: "fair"
defp interpret_kappa(k) when k < 0.60, do: "moderate"
defp interpret_kappa(k) when k < 0.80, do: "substantial"
defp interpret_kappa(k), do: "near perfect"
```

**Fleiss' Kappa** (n raters, complete data):
```elixir
def fleiss_kappa(labels_by_sample) do
  n_raters = length(hd(labels_by_sample))
  n_samples = length(labels_by_sample)
  categories = extract_categories(labels_by_sample)

  # For each sample, count raters per category
  p_i = for sample_labels <- labels_by_sample do
    category_counts = Enum.frequencies(sample_labels)
    sum_squared = Enum.map(category_counts, fn {_, count} -> count * count end) |> Enum.sum()
    (sum_squared - n_raters) / (n_raters * (n_raters - 1))
  end

  p_bar = Enum.sum(p_i) / n_samples

  # Marginal category probabilities
  p_j = for category <- categories do
    total_count = Enum.flat_map(labels_by_sample, &Enum.count(&1, fn x -> x == category end)) |> Enum.sum()
    total_count / (n_samples * n_raters)
  end

  p_e_bar = Enum.map(p_j, &(&1 * &1)) |> Enum.sum()

  kappa = (p_bar - p_e_bar) / (1 - p_e_bar)
  %{metric: :fleiss_kappa, value: kappa, n_raters: n_raters, n_samples: n_samples}
end
```

**Krippendorff's Alpha** (handles missing data):
```elixir
def krippendorff_alpha(reliability_data, level: level) do
  # reliability_data: %{sample_id => %{labeler_id => value | nil}}
  # level: :nominal | :ordinal | :interval | :ratio

  coincidence_matrix = build_coincidence_matrix(reliability_data)
  observed_disagreement = compute_disagreement(coincidence_matrix, level)

  # Expected disagreement (assuming independence)
  marginals = compute_marginals(coincidence_matrix)
  expected_disagreement = compute_expected_disagreement(marginals, level)

  alpha = 1 - (observed_disagreement / expected_disagreement)
  %{metric: :krippendorff_alpha, value: alpha, level: level}
end

defp compute_disagreement(matrix, :nominal) do
  # Nominal: 0 if same, 1 if different
  for {cat_i, row} <- matrix, {cat_j, count} <- row, cat_i != cat_j, reduce: 0 do
    acc -> acc + count
  end
end

defp compute_disagreement(matrix, :ordinal) do
  # Ordinal: squared rank distance
  # Implementation uses cumulative distributions
  # ...
end
```

**Implementation via ExStats** (external dependency):
- Leverage existing `ex_stats` or `statistics` library for tested implementations
- Fallback to naive implementations if dependency unavailable

#### 3. Per-Dimension Agreement

CNS labeling schema has multiple independent dimensions; compute agreement for each:

```elixir
defmodule Anvil.Schema.CNSSynthesis do
  def dimensions do
    [:coherence, :grounded, :balance, :novelty, :overall]
  end
end

def compute_multidimensional_agreement(labels, schema_version) do
  dimensions = schema_version.dimensions()

  for dimension <- dimensions, into: %{} do
    dimension_labels = Enum.map(labels, &get_in(&1.payload, [dimension]))

    metric = select_metric(dimension_labels, schema_version.field_schema(dimension))
    agreement = compute_agreement(dimension_labels, metric)

    {dimension, agreement}
  end
end

# Example output:
%{
  coherence: %{metric: :fleiss_kappa, value: 0.72, interpretation: "substantial"},
  grounded: %{metric: :fleiss_kappa, value: 0.85, interpretation: "near perfect"},
  balance: %{metric: :fleiss_kappa, value: 0.45, interpretation: "moderate"},
  novelty: %{metric: :fleiss_kappa, value: 0.38, interpretation: "fair"},  # <- Flag for review
  overall: %{metric: :fleiss_kappa, value: 0.68, interpretation: "substantial"}
}
```

**Alerting**: Emit telemetry event when dimension agreement drops below threshold (e.g., κ < 0.6)

#### 4. Sample-Level vs Queue-Level Agreement

**Sample-Level** (primary):
```elixir
# Agreement for specific sample (e.g., sample_id="abc123")
Anvil.Agreement.for_sample(sample_id) #=> %{coherence: %{value: 0.85}, ...}
```

**Queue-Level** (aggregate):
```elixir
# Mean agreement across all samples in queue
Anvil.Agreement.for_queue(queue_id) #=> %{
  coherence: %{mean: 0.72, stddev: 0.12, min: 0.45, max: 0.95},
  grounded: %{mean: 0.85, stddev: 0.08, min: 0.70, max: 1.0}
}
```

**Labeler-Level** (performance):
```elixir
# Agreement between specific labeler and consensus
Anvil.Agreement.for_labeler(labeler_id, queue_id) #=> %{
  mean_agreement_with_consensus: 0.78,
  samples_labeled: 150,
  dimensions: %{coherence: 0.82, grounded: 0.75, ...}
}
```

**Consensus Computation**:
- **Majority Vote**: For categorical fields, take mode (most common label)
- **Mean**: For continuous fields (Likert scales), take arithmetic mean
- **Adjudication**: For ties, escalate to expert labeler or mark as "disputed"

#### 5. Agreement Storage

**Option A: Denormalized Cache Table** (Recommended)

```sql
CREATE TABLE agreement_metrics (
  id UUID PRIMARY KEY,
  queue_id UUID REFERENCES queues(id),
  sample_id UUID REFERENCES samples(id),
  schema_version_id UUID REFERENCES schema_versions(id),
  dimension TEXT,  -- NULL for overall agreement
  metric TEXT,  -- cohen_kappa, fleiss_kappa, etc.
  value NUMERIC(5,4),  -- Agreement score (-1 to 1)
  n_raters INTEGER,
  n_labels INTEGER,
  interpretation TEXT,  -- "substantial", "moderate", etc.
  computed_at TIMESTAMPTZ,
  PRIMARY KEY (sample_id, dimension, schema_version_id)
);

CREATE INDEX idx_agreement_queue_dimension ON agreement_metrics(queue_id, dimension);
CREATE INDEX idx_agreement_value ON agreement_metrics(value);  -- For low-agreement queries
```

**Option B: Embedded in Labels Table** (Not Recommended)
- Storing agreement in labels.metadata creates denormalization hell
- Agreement is derived data, should be in separate table

**Cache Invalidation**:
- Recompute on every label submission affecting sample (online mode)
- Full recompute nightly via Oban job (batch mode)
- Invalidate on schema version change (new transform may alter labels)

#### 6. Missing Data Handling

**Partial Labels**:
```elixir
# Labeler A: %{coherence: true, grounded: true, balance: nil}
# Labeler B: %{coherence: true, grounded: false, balance: true}
# Labeler C: %{coherence: false, grounded: true, balance: true}

# Per-dimension agreement (excluding nil)
coherence: compute_agreement([true, true, false])  # n=3
grounded: compute_agreement([true, false, true])   # n=3
balance: compute_agreement([true, true])           # n=2 (missing A)
```

**Krippendorff's Alpha** handles missing data natively via coincidence matrix

**Minimum Rater Threshold**:
```elixir
config :anvil,
  min_raters_for_agreement: 2

# Skip agreement computation if fewer than 2 valid labels
if length(valid_labels) < 2 do
  {:error, :insufficient_labels}
end
```

## Consequences

### Positive

- **Automatic Quality Monitoring**: Real-time agreement alerts identify guideline ambiguities or labeler training needs before bulk labeling
- **Scientific Rigor**: Standard IRR metrics (Cohen's κ, Fleiss' κ, Krippendorff's α) satisfy publication requirements
- **Per-Dimension Insights**: Identifying low-agreement dimensions (e.g., "novelty" is ambiguous) enables targeted guideline improvements
- **Labeler Feedback**: Individual agreement scores support performance reviews and targeted training
- **Dataset Confidence**: High agreement thresholds (κ ≥ 0.8) provide statistical justification for downstream ML training
- **Missing Data Robustness**: Krippendorff's alpha gracefully handles incomplete labeling without discarding samples
- **Correctness**: Batch recompute ensures metrics remain accurate despite race conditions in online updates

### Negative

- **Computational Cost**: Fleiss' kappa on 100k samples with k=3 raters requires O(n) computation per sample; batch job may take minutes
- **Storage Overhead**: Denormalized agreement_metrics table scales with samples × dimensions; for 1M samples × 5 dimensions = 5M rows
- **Statistical Complexity**: Developers must understand kappa vs alpha vs ICC to debug metric selection logic
- **False Precision**: Agreement metrics assume independent raters; if labelers discuss samples, metrics are inflated
- **Threshold Tuning**: κ ≥ 0.8 is common but domain-specific; medical annotation may require κ ≥ 0.9
- **Ambiguity in Ties**: Consensus computation for majority vote ties requires adjudication workflow (not automated)

### Neutral

- **Metric Evolution**: Can add new metrics (ICC, weighted kappa) without breaking existing agreement_metrics rows (add new metric type)
- **Confidence Intervals**: Consider adding bootstrap confidence intervals for agreement scores (95% CI on kappa)
- **Subgroup Analysis**: Support filtering by labeler expertise level (novice vs expert agreement)
- **Longitudinal Tracking**: Track agreement trends over time to measure guideline improvement effectiveness
- **Export Integration**: Include agreement scores in dataset exports as quality metadata

## Implementation Notes

1. **Dependency Selection**:
   - Use `statistics` library for basic percent agreement, correlation
   - Implement Fleiss' kappa in-house (pure Elixir, ~50 LOC)
   - Use `Nx` for matrix operations in Krippendorff's alpha (efficient coincidence matrix)

2. **Telemetry Events**:
   ```elixir
   :telemetry.execute(
     [:anvil, :agreement, :computed],
     %{duration: duration_ms, sample_count: n},
     %{queue_id: queue_id, metric: :fleiss_kappa, mean_agreement: 0.75}
   )

   :telemetry.execute(
     [:anvil, :agreement, :low_score],
     %{value: 0.35},
     %{sample_id: sample_id, dimension: :novelty, threshold: 0.6}
   )
   ```

3. **Batch Job Optimization**:
   ```elixir
   # Stream samples in batches to avoid memory blowup
   defmodule Anvil.Jobs.AgreementRecompute do
     def perform(%{queue_id: queue_id}) do
       Sample
       |> where(queue_id: ^queue_id)
       |> Repo.stream(batch_size: 1000)
       |> Stream.chunk_every(100)
       |> Task.async_stream(&compute_batch_agreement/1, max_concurrency: 4)
       |> Stream.run()
     end
   end
   ```

4. **Agreement Dashboard**:
   - LiveView component showing per-dimension agreement over time
   - Histogram of sample-level agreement scores (identify outliers)
   - Labeler leaderboard ranked by mean agreement with consensus

5. **Consensus Export**:
   ```elixir
   # Export labels with consensus column
   Anvil.Export.to_csv(queue_id, %{
     include_consensus: true,
     consensus_method: :majority_vote
   })

   # CSV output:
   # sample_id, labeler_id, coherence, grounded, coherence_consensus, grounded_consensus, agreement_score
   # abc123, labeler1, true, true, true, true, 1.0
   # abc123, labeler2, true, false, true, true, 0.5
   # abc123, labeler3, true, true, true, true, 1.0
   ```

6. **Statistical Testing**:
   - Property test: agreement on identical labels should be 1.0
   - Known dataset test: compare against published kappa scores from literature
   - Regression test: freeze agreement values for test fixtures, alert on changes

7. **Performance Targets**:
   - Sample-level agreement: <100ms for k=3 raters, 5 dimensions
   - Queue-level agreement: <5s for 10k samples (with cached sample-level results)
   - Batch recompute: <10 minutes for 100k samples on 4-core machine
