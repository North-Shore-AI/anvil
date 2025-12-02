defmodule Anvil.Telemetry.Alerts do
  @moduledoc """
  Alerting hooks for critical Anvil telemetry events.

  Provides configurable alerting for:
  - Low agreement scores (quality degradation)
  - Queue backup (throughput issues)
  - Export failures (operational issues)
  - Assignment timeout spikes (policy issues)

  ## Usage

  Attach alerting handlers in your application supervisor:

      def start(_type, _args) do
        children = [
          # ... other children
        ]

        # Attach alert handlers after supervisor starts
        :ok = Anvil.Telemetry.Alerts.attach_handlers()

        Supervisor.start_link(children, strategy: :one_for_one)
      end

  ## Configuration

      config :anvil, :alerts,
        enabled: true,
        low_agreement_threshold: 0.4,
        queue_backup_threshold: 100,
        timeout_spike_threshold: 50,
        timeout_spike_window: :hour,
        handlers: [
          log: true,
          slack: [enabled: false, webhook_url: nil],
          pagerduty: [enabled: false, api_key: nil]
        ]
  """

  require Logger

  @doc """
  Attaches telemetry handlers for alerting.

  Call this once during application startup, typically in Application.start/2.
  """
  @spec attach_handlers() :: :ok
  def attach_handlers do
    config = get_alert_config()

    if config.enabled do
      :telemetry.attach_many(
        "anvil-alerting",
        [
          [:anvil, :agreement, :low_score],
          [:anvil, :assignment, :timed_out],
          [:anvil, :export, :failed],
          [:anvil, :label, :validation_failed]
        ],
        &handle_alert_event/4,
        config
      )

      Logger.info("[Anvil.Telemetry.Alerts] Alert handlers attached")
    else
      Logger.info("[Anvil.Telemetry.Alerts] Alerting disabled by configuration")
    end

    :ok
  end

  @doc """
  Detaches telemetry handlers for alerting.
  """
  @spec detach_handlers() :: :ok | {:error, :not_found}
  def detach_handlers do
    :telemetry.detach("anvil-alerting")
  end

  # Event Handlers

  @doc false
  def handle_alert_event(event, measurements, metadata, config) do
    case event do
      [:anvil, :agreement, :low_score] ->
        handle_low_agreement(measurements, metadata, config)

      [:anvil, :assignment, :timed_out] ->
        handle_timeout_spike(measurements, metadata, config)

      [:anvil, :export, :failed] ->
        handle_export_failure(measurements, metadata, config)

      [:anvil, :label, :validation_failed] ->
        handle_validation_failure(measurements, metadata, config)

      _ ->
        :ok
    end
  end

  # Alert Handlers

  defp handle_low_agreement(measurements, metadata, config) do
    score = measurements.value
    threshold = config.low_agreement_threshold

    if score < threshold do
      send_alert(
        :critical,
        "Low Agreement Score Detected",
        """
        Inter-rater agreement below threshold #{threshold}.

        Current Score: #{Float.round(score, 3)}
        Dimension: #{metadata[:dimension] || "overall"}
        Metric: #{metadata[:metric] || "auto"}
        Sample ID: #{metadata[:sample_id]}

        This may indicate:
        - Ambiguous labeling guidelines
        - Insufficient labeler training
        - Complex/edge-case sample
        - Schema design issues

        Recommended Actions:
        1. Review labeling guidelines for this dimension
        2. Examine the specific sample for clarity
        3. Provide additional training to labelers
        4. Consider expert review of disagreements
        """,
        metadata,
        config
      )
    end
  end

  defp handle_timeout_spike(measurements, metadata, config) do
    count = measurements.count
    threshold = config.timeout_spike_threshold

    if count >= threshold do
      send_alert(
        :warning,
        "Assignment Timeout Spike",
        """
        High assignment timeout rate detected.

        Timeout Count: #{count} assignments (#{metadata[:requeued] || 0} requeued, #{metadata[:escalated] || 0} escalated)
        Queue ID: #{metadata[:queue_id]}
        Threshold: #{threshold} per #{config.timeout_spike_window}

        This may indicate:
        - Assignment timeout too short
        - Samples too complex
        - Labeler availability issues
        - System performance problems

        Recommended Actions:
        1. Review assignment timeout configuration
        2. Analyze sample complexity distribution
        3. Check labeler engagement metrics
        4. Monitor system performance
        """,
        metadata,
        config
      )
    end
  end

  defp handle_export_failure(_measurements, metadata, config) do
    send_alert(
      :error,
      "Export Failure",
      """
      Export generation failed.

      Export ID: #{metadata[:export_id]}
      Queue ID: #{metadata[:queue_id]}
      Format: #{metadata[:format]}
      Reason: #{inspect(metadata[:reason])}

      This requires immediate attention:
      1. Check export logs for detailed error
      2. Verify storage availability and permissions
      3. Check database connectivity
      4. Monitor disk space

      Exports are critical for downstream ML pipelines.
      """,
      metadata,
      config
    )
  end

  defp handle_validation_failure(measurements, metadata, config) do
    error_count = measurements.error_count

    # Only alert if we see many validation failures (potential schema issue)
    if error_count >= 5 do
      send_alert(
        :warning,
        "High Validation Error Count",
        """
        Label submission had #{error_count} validation errors.

        Assignment ID: #{metadata[:assignment_id]}
        Queue ID: #{metadata[:queue_id]}
        Errors: #{inspect(metadata[:errors])}

        Multiple validation errors may indicate:
        - Schema/UI mismatch
        - Incomplete form submission
        - Labeler confusion
        - Bug in validation logic

        Recommended Actions:
        1. Review validation errors for patterns
        2. Check UI/schema consistency
        3. Verify labeler training on new fields
        """,
        metadata,
        config
      )
    end
  end

  # Alert Dispatch

  defp send_alert(severity, title, message, metadata, config) do
    alert = %{
      severity: severity,
      title: title,
      message: String.trim(message),
      metadata: metadata,
      timestamp: DateTime.utc_now()
    }

    # Log alert
    if get_in(config.handlers, [:log]) do
      log_alert(alert)
    end

    # Send to Slack
    if get_in(config.handlers, [:slack, :enabled]) do
      send_slack_alert(alert, config.handlers.slack)
    end

    # Send to PagerDuty
    if get_in(config.handlers, [:pagerduty, :enabled]) do
      send_pagerduty_alert(alert, config.handlers.pagerduty)
    end

    :ok
  end

  defp log_alert(alert) do
    log_fn =
      case alert.severity do
        :critical -> &Logger.error/1
        :error -> &Logger.error/1
        :warning -> &Logger.warning/1
      end

    log_fn.("[Anvil Alert] [#{alert.severity}] #{alert.title}\n#{alert.message}")
  end

  defp send_slack_alert(alert, slack_config) do
    webhook_url = slack_config[:webhook_url]

    if webhook_url do
      # Format Slack message
      payload = %{
        text: "*[Anvil Alert] #{alert.title}*",
        attachments: [
          %{
            color: severity_color(alert.severity),
            text: alert.message,
            fields: [
              %{title: "Severity", value: to_string(alert.severity), short: true},
              %{
                title: "Timestamp",
                value: Calendar.strftime(alert.timestamp, "%Y-%m-%d %H:%M:%S UTC"),
                short: true
              }
            ],
            footer: "Anvil Telemetry Alerts"
          }
        ]
      }

      # Send to Slack (would use HTTPoison or similar in production)
      # HTTPoison.post(webhook_url, Jason.encode!(payload), [{"Content-Type", "application/json"}])
      Logger.debug("[Anvil.Telemetry.Alerts] Would send to Slack: #{inspect(payload)}")
    end

    :ok
  end

  defp send_pagerduty_alert(alert, pagerduty_config) do
    api_key = pagerduty_config[:api_key]
    routing_key = pagerduty_config[:routing_key]

    if api_key && routing_key do
      # Format PagerDuty event
      event = %{
        routing_key: routing_key,
        event_action: "trigger",
        payload: %{
          summary: alert.title,
          severity: pagerduty_severity(alert.severity),
          source: "anvil-telemetry",
          custom_details: %{
            message: alert.message,
            metadata: alert.metadata
          }
        }
      }

      # Send to PagerDuty (would use HTTPoison or similar in production)
      # HTTPoison.post("https://events.pagerduty.com/v2/enqueue", Jason.encode!(event), ...)
      Logger.debug("[Anvil.Telemetry.Alerts] Would send to PagerDuty: #{inspect(event)}")
    end

    :ok
  end

  # Helpers

  defp get_alert_config do
    defaults = %{
      enabled: true,
      low_agreement_threshold: 0.4,
      queue_backup_threshold: 100,
      timeout_spike_threshold: 50,
      timeout_spike_window: :hour,
      handlers: %{
        log: true,
        slack: %{enabled: false, webhook_url: nil},
        pagerduty: %{enabled: false, api_key: nil, routing_key: nil}
      }
    }

    config = Application.get_env(:anvil, :alerts, [])
    deep_merge(defaults, Map.new(config))
  end

  defp deep_merge(left, right) do
    Map.merge(left, right, fn
      _key, left_val, right_val when is_map(left_val) and is_map(right_val) ->
        deep_merge(left_val, right_val)

      _key, _left_val, right_val ->
        right_val
    end)
  end

  defp severity_color(:critical), do: "danger"
  defp severity_color(:error), do: "danger"
  defp severity_color(:warning), do: "warning"

  defp pagerduty_severity(:critical), do: "critical"
  defp pagerduty_severity(:error), do: "error"
  defp pagerduty_severity(:warning), do: "warning"
end
