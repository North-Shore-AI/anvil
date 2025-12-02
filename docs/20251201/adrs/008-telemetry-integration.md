# ADR-008: Telemetry Integration and Observability

## Status
Accepted

## Context

Production labeling systems require comprehensive observability for:

**Operational Monitoring**:
- Assignment dispatch latency (SLA: p99 < 100ms)
- Label submission throughput (labels/hour per queue)
- Agreement recomputation duration (detect performance regressions)
- Export job completion times (identify bottlenecks)

**Quality Metrics**:
- Inter-rater agreement trends (alert on sudden drops)
- Per-labeler agreement scores (identify training needs)
- Label rejection rates (flag problematic samples)
- Schema validation failure rates (detect UI bugs)

**Business Insights**:
- Active labelers per queue (capacity planning)
- Labels completed per day (project progress tracking)
- Cost per label (labeler compensation modeling)
- Time-to-completion per sample type (improve estimates)

**Debugging & Incident Response**:
- Distributed traces for slow exports
- Error rates by queue/labeler/policy
- Timeout sweep statistics (detect assignment policy issues)
- Authentication failure rates (identify IdP problems)

The BEAM ecosystem provides excellent observability primitives:
- **:telemetry** - Event emission standard (used across Phoenix, Ecto, Oban)
- **TelemetryMetrics** - Metric aggregation (counters, distributions, summaries)
- **TelemetryMetricsStatsd** - StatsD exporter (for Datadog, Grafana)
- **OpenTelemetry** - Distributed tracing (OTLP protocol)

Current Anvil v0.1 has no instrumentation:
- Cannot measure assignment latency or throughput
- No visibility into agreement computation performance
- No alerts for quality degradation
- No integration with NSAI Foundation metrics infrastructure

Without telemetry, teams rely on manual database queries and cannot detect issues until users complain.

## Decision

We will implement comprehensive :telemetry instrumentation with metric aggregation, StatsD export, and integration with NSAI Foundation/AITrace systems.

### 1. Core Telemetry Events

**Event Naming Convention**: `[:anvil, domain, action, lifecycle]`
- **domain**: queue, assignment, label, agreement, export, auth, policy
- **action**: created, dispatched, submitted, computed, completed
- **lifecycle**: start, stop, exception (for duration measurements)

**Event Catalog**:

#### Queue Events

```elixir
# Queue created
:telemetry.execute(
  [:anvil, :queue, :created],
  %{},  # No measurements (count event)
  %{queue_id: id, tenant_id: tenant, policy_type: "weighted_expertise"}
)

# Queue paused/resumed
:telemetry.execute([:anvil, :queue, :status_changed], %{},
  %{queue_id: id, from_status: :active, to_status: :paused}
)
```

#### Assignment Events

```elixir
# Assignment dispatch (with duration)
:telemetry.span(
  [:anvil, :assignment, :dispatch],
  %{queue_id: queue_id, labeler_id: labeler_id},
  fn ->
    result = Policy.select_assignment(queue_id, labeler_id)
    {result, %{policy_type: "round_robin", retry_count: 0}}
  end
)

# Emits:
# - [:anvil, :assignment, :dispatch, :start] with %{system_time: t0}
# - [:anvil, :assignment, :dispatch, :stop] with %{duration: duration_ns}
# - [:anvil, :assignment, :dispatch, :exception] if error (with kind, reason, stacktrace)

# Assignment timed out (from Oban sweep)
:telemetry.execute([:anvil, :assignment, :timed_out], %{count: 15},
  %{queue_id: id, requeued: 12, escalated: 3}
)
```

#### Label Events

```elixir
# Label submission
:telemetry.span(
  [:anvil, :label, :submit],
  %{assignment_id: id, labeler_id: labeler_id},
  fn ->
    result = Label.submit(assignment_id, payload)
    {result, %{schema_version_id: schema_v2, validation_errors: 0}}
  end
)

# Label validation failed
:telemetry.execute([:anvil, :label, :validation_failed], %{},
  %{
    assignment_id: id,
    schema_version_id: schema_v2,
    errors: [%{field: "coherence", message: "is required"}]
  }
)
```

#### Agreement Events

```elixir
# Agreement computation (sample-level)
:telemetry.span(
  [:anvil, :agreement, :compute],
  %{sample_id: id, queue_id: queue_id},
  fn ->
    result = Agreement.for_sample(sample_id)
    {result, %{metric: :fleiss_kappa, n_raters: 3, dimensions: 5}}
  end
)

# Low agreement detected
:telemetry.execute([:anvil, :agreement, :low_score], %{value: 0.38},
  %{sample_id: id, dimension: "novelty", threshold: 0.6}
)

# Agreement batch recompute (queue-level)
:telemetry.span(
  [:anvil, :agreement, :batch_recompute],
  %{queue_id: id},
  fn ->
    result = Agreement.recompute_all(queue_id)
    {result, %{samples_processed: 1500, duration_ms: 45000}}
  end
)
```

#### Export Events

```elixir
# Export started/completed
:telemetry.span(
  [:anvil, :export, :generate],
  %{queue_id: id, format: :csv},
  fn ->
    result = Export.to_csv(queue_id, opts)
    {result, %{row_count: 5000, file_size_bytes: 1_200_000}}
  end
)

# Export progress (streamed during long exports)
:telemetry.execute([:anvil, :export, :progress], %{rows_processed: 10000},
  %{export_id: id, total_rows: 50000, progress_pct: 20.0}
)

# PII detected in export
:telemetry.execute([:anvil, :export, :pii_detected], %{},
  %{export_id: id, field: "notes", pattern: "email"}
)
```

#### Auth Events

```elixir
# Authentication
:telemetry.execute([:anvil, :auth, :login_success], %{},
  %{labeler_id: id, provider: "oidc", tenant_id: tenant}
)

:telemetry.execute([:anvil, :auth, :login_failed], %{},
  %{reason: "invalid_token", provider: "oidc"}
)

# Authorization
:telemetry.execute([:anvil, :auth, :access_granted], %{},
  %{labeler_id: id, action: :request_assignment, resource_id: queue_id}
)

:telemetry.execute([:anvil, :auth, :access_denied], %{},
  %{labeler_id: id, action: :export_data, reason: :not_member}
)
```

#### Policy Events

```elixir
# Policy selection
:telemetry.span(
  [:anvil, :policy, :select_assignment],
  %{policy_type: "weighted_expertise", queue_id: queue_id},
  fn ->
    result = Policy.WeightedExpertise.select_assignment(queue_id, labeler_id)
    {result, %{eligible_samples: 50, selected_sample_difficulty: "complex"}}
  end
)

# Assignment requeued
:telemetry.execute([:anvil, :policy, :requeue], %{},
  %{assignment_id: id, reason: :timeout, attempt: 2}
)
```

### 2. Metric Definitions (TelemetryMetrics)

```elixir
defmodule Anvil.Telemetry do
  use Supervisor
  import Telemetry.Metrics

  def start_link(arg) do
    Supervisor.start_link(__MODULE__, arg, name: __MODULE__)
  end

  def init(_arg) do
    children = [
      # Metrics reporter (StatsD, Prometheus, etc.)
      {TelemetryMetricsStatsd, metrics: metrics(), port: 8125}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end

  def metrics do
    [
      # Counters
      counter("anvil.queue.created.count"),
      counter("anvil.label.submit.count",
        tags: [:queue_id, :schema_version_id],
        tag_values: &extract_metadata/1
      ),
      counter("anvil.assignment.timed_out.count", tags: [:queue_id]),

      # Distributions (histograms)
      distribution("anvil.assignment.dispatch.duration",
        unit: {:native, :millisecond},
        tags: [:policy_type],
        reporter_options: [buckets: [10, 50, 100, 250, 500, 1000]]
      ),
      distribution("anvil.label.submit.duration",
        unit: {:native, :millisecond},
        tags: [:queue_id],
        reporter_options: [buckets: [25, 50, 100, 250, 500]]
      ),
      distribution("anvil.agreement.compute.duration",
        unit: {:native, :millisecond},
        tags: [:metric],
        reporter_options: [buckets: [10, 25, 50, 100, 250, 500]]
      ),
      distribution("anvil.export.generate.duration",
        unit: {:native, :second},
        tags: [:format],
        reporter_options: [buckets: [1, 5, 10, 30, 60, 300]]
      ),

      # Summaries (percentiles)
      summary("anvil.agreement.low_score.value",
        tags: [:dimension],
        reporter_options: [percentiles: [0.5, 0.9, 0.95, 0.99]]
      ),

      # Last value (gauges)
      last_value("anvil.export.progress.progress_pct", tags: [:export_id]),
      last_value("anvil.queue.active_labelers.count", tags: [:queue_id])
    ]
  end

  defp extract_metadata(metadata) do
    metadata
    |> Map.take([:queue_id, :schema_version_id, :policy_type, :format, :dimension, :metric])
    |> Map.new(fn {k, v} -> {k, to_string(v)} end)
  end
end
```

**StatsD Metrics Output** (for Datadog/Grafana):
```
anvil.queue.created.count:1|c
anvil.label.submit.count:1|c|#queue_id:abc123,schema_version_id:v2
anvil.assignment.dispatch.duration:45|ms|#policy_type:weighted_expertise
anvil.agreement.low_score.value:0.38|g|#dimension:novelty
```

### 3. OpenTelemetry Distributed Tracing

**Integration with NSAI Foundation**:

```elixir
# config/config.exs
config :opentelemetry,
  processors: [
    otel_batch_processor: %{
      exporter: {:otel_exporter_otlp, %{endpoints: ["http://foundation:4318"]}}
    }
  ]

# Instrument critical paths with spans
defmodule Anvil.Export.CSV do
  require OpenTelemetry.Tracer, as: Tracer

  def to_format(queue_id, opts) do
    Tracer.with_span "anvil.export.csv", %{queue_id: queue_id} do
      Tracer.set_attributes(%{format: "csv", redaction_mode: opts[:redaction_mode]})

      Tracer.with_span "fetch_labels" do
        labels = stream_labels(queue_id, opts)
        Tracer.set_attribute(:label_count, Enum.count(labels))
        labels
      end

      Tracer.with_span "write_csv" do
        write_csv(labels, output_path)
      end

      Tracer.with_span "compute_hash" do
        hash = compute_export_hash(output_path)
        Tracer.set_attribute(:sha256, hash)
      end
    end
  end
end
```

**Trace Propagation** (for cross-service calls):
```elixir
# Propagate trace context when calling Forge
defmodule Anvil.ForgeBridge do
  def fetch_sample(sample_id) do
    # Extract current trace context
    trace_id = OpenTelemetry.Tracer.current_span_ctx()

    # HTTP request with W3C trace headers
    HTTPoison.get("#{forge_url}/samples/#{sample_id}",
      headers: [
        {"traceparent", encode_trace_parent(trace_id)},
        {"tracestate", encode_trace_state()}
      ]
    )
  end
end
```

### 4. Foundation/AITrace Integration

**NSAI Foundation** provides centralized metrics ingestion for the monorepo:

```elixir
# Foundation expects events in specific format
defmodule Anvil.Foundation do
  @doc """
  Emit events compatible with Foundation metrics collection.
  """
  def emit_metric(name, value, tags) do
    :telemetry.execute(
      [:foundation, :metric],
      %{value: value},
      %{
        metric_name: "anvil.#{name}",
        tags: tags,
        timestamp: System.system_time(:millisecond)
      }
    )
  end
end

# Attach Foundation handlers to Anvil events
:telemetry.attach_many(
  "anvil-foundation-integration",
  [
    [:anvil, :label, :submit, :stop],
    [:anvil, :agreement, :low_score],
    [:anvil, :export, :generate, :stop]
  ],
  &Anvil.Foundation.handle_event/4,
  nil
)
```

**AITrace Integration** (for ML pipeline lineage):

```elixir
defmodule Anvil.AITrace do
  @doc """
  Register dataset export in AITrace for lineage tracking.
  """
  def register_export(export_manifest) do
    AITrace.create_artifact(%{
      type: "dataset",
      name: "anvil_export_#{export_manifest.export_id}",
      version: export_manifest.schema_version_id,
      metadata: %{
        queue_id: export_manifest.queue_id,
        row_count: export_manifest.row_count,
        sha256: export_manifest.sha256_hash,
        format: export_manifest.format
      },
      lineage: %{
        upstream: [
          %{type: "queue", id: export_manifest.queue_id},
          %{type: "schema_version", id: export_manifest.schema_version_id}
        ]
      }
    })
  end
end

# Automatically register on export completion
:telemetry.attach(
  "anvil-aitrace-export",
  [:anvil, :export, :generate, :stop],
  &Anvil.AITrace.handle_export_complete/4,
  nil
)
```

### 5. Live Dashboard Integration

**Phoenix LiveDashboard** provides real-time metrics UI:

```elixir
# lib/anvil_web/router.ex
import Phoenix.LiveDashboard.Router

scope "/" do
  pipe_through :browser

  live_dashboard "/dashboard",
    metrics: Anvil.Telemetry,
    additional_pages: [
      anvil_metrics: Anvil.LiveDashboard.MetricsPage
    ]
end
```

**Custom Metrics Page**:

```elixir
defmodule Anvil.LiveDashboard.MetricsPage do
  use Phoenix.LiveDashboard.PageBuilder

  @impl true
  def menu_link(_, _) do
    {:ok, "Anvil Metrics"}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div>
      <h2>Queue Activity</h2>
      <%= live_table(
        @socket,
        rows: fetch_queue_stats(),
        dom_id: "queue-stats-table",
        title: "Active Queues"
      ) %>

      <h2>Agreement Scores</h2>
      <%= live_chart(
        @socket,
        chart: fetch_agreement_chart(),
        title: "Inter-Rater Agreement Trend"
      ) %>
    </div>
    """
  end

  defp fetch_queue_stats do
    # Query Postgres for current queue statistics
    Anvil.Queues.list_active_queues()
    |> Enum.map(fn queue ->
      %{
        name: queue.name,
        pending_assignments: count_pending(queue.id),
        active_labelers: count_active_labelers(queue.id),
        labels_today: count_labels_today(queue.id)
      }
    end)
  end
end
```

### 6. Alerting Rules

**Metric-Based Alerts** (integrate with PagerDuty, Slack):

```elixir
defmodule Anvil.Alerts do
  @doc """
  Define alerting thresholds for critical metrics.
  """
  def alert_rules do
    [
      # Assignment dispatch latency
      %{
        metric: "anvil.assignment.dispatch.duration",
        threshold: %{p99: 500},  # ms
        severity: :warning,
        message: "Assignment dispatch p99 latency exceeds 500ms"
      },

      # Low agreement score
      %{
        event: [:anvil, :agreement, :low_score],
        condition: fn %{value: v} -> v < 0.4 end,
        severity: :critical,
        message: "Inter-rater agreement below 0.4 (indicates guideline ambiguity)"
      },

      # Export failures
      %{
        metric: "anvil.export.generate.exception.count",
        threshold: %{count: 3, window: :hour},
        severity: :error,
        message: "3+ export failures in last hour"
      },

      # Timeout spike
      %{
        metric: "anvil.assignment.timed_out.count",
        threshold: %{count: 50, window: :hour},
        severity: :warning,
        message: "High assignment timeout rate (50+ in last hour)"
      }
    ]
  end
end

# Alert handler
:telemetry.attach(
  "anvil-alerting",
  [:anvil, :agreement, :low_score],
  fn event, measurements, metadata, _config ->
    alert = Enum.find(Anvil.Alerts.alert_rules(), &match_event?(&1, event))

    if alert && alert.condition.(measurements) do
      send_alert(alert.severity, alert.message, metadata)
    end
  end,
  nil
)

defp send_alert(severity, message, metadata) do
  # Integration with alerting system
  Slack.send_message("#anvil-alerts", "[#{severity}] #{message}")
  Logger.error("[Alert] #{message}", metadata)
end
```

## Consequences

### Positive

- **Proactive Monitoring**: Real-time metrics enable detection of quality degradation before manual review
- **Performance Optimization**: Duration metrics identify bottlenecks (slow queries, inefficient policies)
- **Capacity Planning**: Throughput metrics (labels/hour) inform labeler staffing decisions
- **Incident Response**: Distributed traces enable root cause analysis of export failures, timeout spikes
- **Integration**: Foundation/AITrace integration provides unified observability across NSAI platform
- **Standardization**: :telemetry aligns with Phoenix, Ecto, Oban patterns; familiar to Elixir developers
- **Flexibility**: Multiple exporters (StatsD, Prometheus, OTLP) support diverse monitoring stacks

### Negative

- **Performance Overhead**: Telemetry event emission adds ~1-10μs per event; negligible for most operations but measurable at high scale
- **Cardinality Risk**: High-cardinality tags (e.g., tagging by labeler_id) can overwhelm metrics backends; requires careful tag selection
- **Alert Fatigue**: Overly sensitive thresholds produce noisy alerts; requires tuning based on baseline metrics
- **Storage Cost**: Retaining metrics/traces indefinitely incurs storage cost; need retention policies
- **Complexity**: Multiple observability systems (StatsD, OpenTelemetry, Foundation) increase operational burden

### Neutral

- **Sampling**: For high-volume events (label submissions), consider sampling (e.g., emit 1/100 events) to reduce overhead
- **Custom Metrics**: Teams may want domain-specific metrics (e.g., medical label accuracy); provide extension points
- **Metric Deprecation**: As system evolves, retire unused metrics to reduce cardinality
- **Dashboard Curation**: Avoid "dashboard sprawl"; maintain core set of actionable dashboards

## Implementation Notes

1. **Telemetry Attachment Strategy**:
   ```elixir
   # Attach handlers in application.ex supervision tree
   defmodule Anvil.Application do
     def start(_type, _args) do
       children = [
         Anvil.Repo,
         Anvil.Telemetry,  # Metrics reporter
         {Phoenix.PubSub, name: Anvil.PubSub}
       ]

       # Attach telemetry handlers after supervisor starts
       :ok = Anvil.Telemetry.attach_handlers()

       Supervisor.start_link(children, strategy: :one_for_one)
     end
   end
   ```

2. **Testing Telemetry Events**:
   ```elixir
   defmodule Anvil.LabelTest do
     use Anvil.DataCase
     import Telemetry.Test

     test "emits telemetry event on label submission" do
       attach_telemetry_handler([:anvil, :label, :submit, :stop])

       Label.submit(assignment_id, payload)

       assert_received {:telemetry, [:anvil, :label, :submit, :stop], %{duration: _}, metadata}
       assert metadata.assignment_id == assignment_id
     end
   end
   ```

3. **Metric Cardinality Management**:
   - **High Cardinality** (avoid): labeler_id, sample_id, assignment_id
   - **Medium Cardinality** (use sparingly): queue_id (~100s), tenant_id (~10s)
   - **Low Cardinality** (safe): policy_type, format, metric, dimension

4. **Performance Targets**:
   - Telemetry event emission: <10μs per event
   - Metrics aggregation: <1ms per metric update
   - StatsD export batch: <100ms for 1000 metrics
   - OpenTelemetry span creation: <50μs per span

5. **Telemetry Naming Convention**:
   - Use snake_case for event names (`:anvil, :label, :submit`)
   - Suffix duration events with `.duration` in metrics (for clarity)
   - Use consistent tag names across events (queue_id, not queueId)

6. **Retention Policies**:
   - Raw metrics: 7 days (for debugging recent issues)
   - Aggregated metrics: 90 days (for trend analysis)
   - Traces: 30 days (for incident investigation)
   - Long-term archival: Downsample to 1-hour buckets, retain 2 years

7. **Grafana Dashboard Example**:
   ```json
   {
     "dashboard": {
       "title": "Anvil Queue Health",
       "panels": [
         {
           "title": "Assignment Dispatch Latency (p99)",
           "targets": [{
             "expr": "anvil.assignment.dispatch.duration.p99",
             "legendFormat": "{{policy_type}}"
           }]
         },
         {
           "title": "Labels Submitted per Hour",
           "targets": [{
             "expr": "rate(anvil.label.submit.count[1h])",
             "legendFormat": "{{queue_id}}"
           }]
         },
         {
           "title": "Agreement Score Distribution",
           "targets": [{
             "expr": "histogram_quantile(0.5, anvil.agreement.low_score.value)",
             "legendFormat": "{{dimension}}"
           }]
         }
       ]
     }
   }
   ```

8. **Event Sampling Configuration**:
   ```elixir
   # config/runtime.exs
   config :anvil, :telemetry,
     sampling: %{
       # Sample 10% of label submit events in production
       [:anvil, :label, :submit] => 0.1,
       # Always emit critical events
       [:anvil, :agreement, :low_score] => 1.0,
       [:anvil, :auth, :access_denied] => 1.0
     }

   # Sampling wrapper
   defmodule Anvil.Telemetry.Sampler do
     def execute(event, measurements, metadata) do
       sample_rate = get_sample_rate(event)

       if :rand.uniform() < sample_rate do
         :telemetry.execute(event, measurements, metadata)
       end
     end
   end
   ```
