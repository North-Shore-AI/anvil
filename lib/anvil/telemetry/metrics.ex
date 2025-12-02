defmodule Anvil.Telemetry.Metrics do
  @moduledoc """
  TelemetryMetrics definitions for Anvil.

  Defines counters, distributions, and summaries for monitoring labeling operations.
  Compatible with TelemetryMetricsStatsd, Prometheus, and other exporters.

  ## Metric Categories

  - **Counters**: Total counts (queues created, labels submitted, assignments)
  - **Distributions**: Latency histograms (assignment dispatch, agreement compute)
  - **Summaries**: Percentiles (agreement scores)
  - **Last Values**: Current state (export progress, queue depth)

  ## Usage

  In your application supervisor:

      children = [
        # Other children...
        {TelemetryMetricsStatsd, metrics: Anvil.Telemetry.Metrics.metrics(), port: 8125}
      ]

  Or with Prometheus:

      children = [
        {TelemetryMetricsPrometheus, metrics: Anvil.Telemetry.Metrics.metrics()}
      ]
  """

  import Telemetry.Metrics

  @doc """
  Returns all metric definitions for Anvil.
  """
  @spec metrics() :: [Telemetry.Metrics.t()]
  def metrics do
    [
      # Queue metrics
      counter("anvil.queue.created.count",
        description: "Total number of queues created",
        tags: [:policy_type]
      ),
      counter("anvil.queue.status_changed.count",
        description: "Total number of queue status changes",
        tags: [:queue_id, :from_status, :to_status]
      ),

      # Assignment metrics
      counter("anvil.assignment.created.count",
        description: "Total number of assignments created",
        tags: [:queue_id, :labeler_id]
      ),
      counter("anvil.assignment.completed.count",
        description: "Total number of assignments completed",
        tags: [:queue_id]
      ),
      counter("anvil.assignment.expired.count",
        description: "Total number of assignments expired",
        tags: [:queue_id]
      ),
      counter("anvil.assignment.timed_out.count",
        description: "Total number of assignments timed out (batch)",
        tags: [:queue_id]
      ),
      distribution("anvil.assignment.dispatch.duration",
        description: "Assignment dispatch latency",
        unit: {:native, :millisecond},
        tags: [:queue_id, :policy_type],
        reporter_options: [buckets: [10, 25, 50, 100, 250, 500, 1000]]
      ),

      # Label metrics
      counter("anvil.label.submit.count",
        description: "Total number of labels submitted",
        tags: [:queue_id, :labeler_id]
      ),
      counter("anvil.label.validation_failed.count",
        description: "Total number of label validation failures",
        tags: [:queue_id]
      ),
      distribution("anvil.label.submit.duration",
        description: "Label submission duration",
        unit: {:native, :millisecond},
        tags: [:queue_id],
        reporter_options: [buckets: [25, 50, 100, 250, 500, 1000]]
      ),
      summary("anvil.label.validation_failed.error_count",
        description: "Number of validation errors per failed submission",
        tags: [:queue_id]
      ),

      # Agreement metrics
      counter("anvil.agreement.compute.count",
        description: "Total number of agreement computations",
        tags: [:metric, :dimension]
      ),
      counter("anvil.agreement.low_score.count",
        description: "Total number of low agreement score detections",
        tags: [:dimension]
      ),
      distribution("anvil.agreement.compute.duration",
        description: "Agreement computation duration",
        unit: {:native, :millisecond},
        tags: [:metric, :dimension],
        reporter_options: [buckets: [10, 25, 50, 100, 250, 500, 1000]]
      ),
      distribution("anvil.agreement.batch_recompute.duration",
        description: "Batch agreement recomputation duration",
        unit: {:native, :second},
        tags: [:queue_id],
        reporter_options: [buckets: [1, 5, 10, 30, 60, 300, 600]]
      ),
      summary("anvil.agreement.low_score.value",
        description: "Agreement score percentiles",
        tags: [:dimension],
        reporter_options: [percentiles: [0.5, 0.9, 0.95, 0.99]]
      ),

      # Export metrics
      counter("anvil.export.generate.count",
        description: "Total number of exports generated",
        tags: [:format, :queue_id]
      ),
      counter("anvil.export.completed.count",
        description: "Total number of exports completed",
        tags: [:format]
      ),
      counter("anvil.export.failed.count",
        description: "Total number of export failures",
        tags: [:format, :reason]
      ),
      distribution("anvil.export.generate.duration",
        description: "Export generation duration",
        unit: {:native, :second},
        tags: [:format, :queue_id],
        reporter_options: [buckets: [1, 5, 10, 30, 60, 300, 600]]
      ),
      last_value("anvil.export.progress.rows_processed",
        description: "Current export progress (rows processed)",
        tags: [:export_id]
      ),

      # Storage metrics
      counter("anvil.storage.query.count",
        description: "Total number of storage queries",
        tags: [:operation]
      ),
      distribution("anvil.storage.query.duration",
        description: "Storage query duration",
        unit: {:native, :millisecond},
        tags: [:operation],
        reporter_options: [buckets: [1, 5, 10, 25, 50, 100, 250, 500]]
      ),

      # Schema metrics
      counter("anvil.schema.validation.count",
        description: "Total number of schema validations",
        tags: [:schema_id, :valid?]
      ),
      counter("anvil.schema.migration.count",
        description: "Total number of schema migrations",
        tags: [:from_version, :to_version]
      )
    ]
  end

  @doc """
  Returns core metrics for basic monitoring (subset of all metrics).

  Use this for minimal overhead monitoring or when cardinality is a concern.
  """
  @spec core_metrics() :: [Telemetry.Metrics.t()]
  def core_metrics do
    [
      # Essential counters
      counter("anvil.label.submit.count",
        description: "Total number of labels submitted",
        tags: [:queue_id]
      ),
      counter("anvil.assignment.completed.count",
        description: "Total number of assignments completed",
        tags: [:queue_id]
      ),
      counter("anvil.assignment.expired.count",
        description: "Total number of assignments expired",
        tags: [:queue_id]
      ),

      # Essential latency metrics
      distribution("anvil.assignment.dispatch.duration",
        description: "Assignment dispatch latency",
        unit: {:native, :millisecond},
        tags: [:policy_type],
        reporter_options: [buckets: [10, 50, 100, 250, 500, 1000]]
      ),
      distribution("anvil.agreement.compute.duration",
        description: "Agreement computation duration",
        unit: {:native, :millisecond},
        tags: [:metric],
        reporter_options: [buckets: [10, 50, 100, 250, 500, 1000]]
      ),

      # Quality metrics
      summary("anvil.agreement.low_score.value",
        description: "Agreement score percentiles",
        tags: [:dimension],
        reporter_options: [percentiles: [0.5, 0.95, 0.99]]
      )
    ]
  end

  @doc """
  Extracts metadata tags from telemetry metadata map.

  Filters to only include known tag keys to prevent cardinality explosion.
  """
  @spec extract_tags(map()) :: map()
  def extract_tags(metadata) do
    allowed_keys = [
      :queue_id,
      :labeler_id,
      :assignment_id,
      :export_id,
      :schema_id,
      :policy_type,
      :format,
      :metric,
      :dimension,
      :operation,
      :from_status,
      :to_status,
      :from_version,
      :to_version,
      :valid?,
      :reason
    ]

    metadata
    |> Map.take(allowed_keys)
    |> Map.new(fn {k, v} -> {k, to_string(v)} end)
  end
end
