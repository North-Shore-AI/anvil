defmodule Anvil.TelemetryTest do
  use Supertester.ExUnitFoundation, isolation: :full_isolation

  alias Anvil.Telemetry

  setup do
    # Attach a test handler to capture telemetry events
    test_pid = self()

    handler_id = "test-#{System.unique_integer([:positive])}"

    :telemetry.attach_many(
      handler_id,
      [
        [:anvil, :queue, :created],
        [:anvil, :queue, :status_changed],
        [:anvil, :assignment, :dispatch, :start],
        [:anvil, :assignment, :dispatch, :stop],
        [:anvil, :assignment, :dispatch, :exception],
        [:anvil, :assignment, :created],
        [:anvil, :assignment, :completed],
        [:anvil, :assignment, :expired],
        [:anvil, :assignment, :timed_out],
        [:anvil, :label, :submit, :start],
        [:anvil, :label, :submit, :stop],
        [:anvil, :label, :submit, :exception],
        [:anvil, :label, :validation_failed],
        [:anvil, :agreement, :compute, :start],
        [:anvil, :agreement, :compute, :stop],
        [:anvil, :agreement, :low_score],
        [:anvil, :agreement, :batch_recompute, :start],
        [:anvil, :agreement, :batch_recompute, :stop],
        [:anvil, :export, :generate, :start],
        [:anvil, :export, :generate, :stop],
        [:anvil, :export, :progress],
        [:anvil, :export, :completed],
        [:anvil, :export, :failed],
        [:anvil, :storage, :query, :start],
        [:anvil, :storage, :query, :stop],
        [:anvil, :schema, :validation],
        [:anvil, :schema, :migration],
        [:anvil, :custom_operation, :start],
        [:anvil, :custom_operation, :stop],
        [:anvil, :custom_operation, :exception]
      ],
      fn event, measurements, metadata, _config ->
        send(test_pid, {:telemetry_event, event, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    :ok
  end

  describe "queue events" do
    test "emit_queue_created/2 emits event with metadata" do
      queue_id = "queue-123"
      metadata = %{policy_type: :round_robin, tenant_id: "tenant-1"}

      Telemetry.emit_queue_created(queue_id, metadata)

      assert_receive {:telemetry_event, [:anvil, :queue, :created], %{}, received_metadata}
      assert received_metadata.queue_id == queue_id
      assert received_metadata.policy_type == :round_robin
      assert received_metadata.tenant_id == "tenant-1"
    end

    test "emit_queue_status_changed/4 emits event with status transition" do
      queue_id = "queue-123"
      Telemetry.emit_queue_status_changed(queue_id, :active, :paused, %{})

      assert_receive {:telemetry_event, [:anvil, :queue, :status_changed], %{}, metadata}
      assert metadata.queue_id == queue_id
      assert metadata.from_status == :active
      assert metadata.to_status == :paused
    end
  end

  describe "assignment events" do
    test "span_assignment_dispatch/2 emits start and stop events" do
      metadata = %{queue_id: "queue-1", labeler_id: "labeler-1"}

      result =
        Telemetry.span_assignment_dispatch(metadata, fn ->
          # Simulate some work without using Process.sleep
          _work = Enum.reduce(1..100, 0, fn x, acc -> acc + x end)
          {{:ok, %{policy_type: "round_robin"}}, %{policy_type: "round_robin"}}
        end)

      assert result == {:ok, %{policy_type: "round_robin"}}

      assert_receive {:telemetry_event, [:anvil, :assignment, :dispatch, :start], measurements,
                      start_metadata}

      assert is_integer(measurements.system_time)
      assert start_metadata.queue_id == "queue-1"
      assert start_metadata.labeler_id == "labeler-1"

      assert_receive {:telemetry_event, [:anvil, :assignment, :dispatch, :stop], measurements,
                      stop_metadata}

      assert is_integer(measurements.duration)
      assert measurements.duration > 0
      assert stop_metadata.policy_type == "round_robin"
    end

    test "span_assignment_dispatch/2 emits exception event on error" do
      metadata = %{queue_id: "queue-1"}

      assert_raise RuntimeError, "test error", fn ->
        Telemetry.span_assignment_dispatch(metadata, fn ->
          raise "test error"
        end)
      end

      assert_receive {:telemetry_event, [:anvil, :assignment, :dispatch, :start], _, _}

      assert_receive {:telemetry_event, [:anvil, :assignment, :dispatch, :exception],
                      measurements, exception_metadata}

      assert measurements.duration > 0
      assert exception_metadata.kind == :error
      assert match?(%RuntimeError{}, exception_metadata.reason)
    end

    test "emit_assignment_created/2 emits event" do
      Telemetry.emit_assignment_created("assign-1", %{queue_id: "queue-1"})

      assert_receive {:telemetry_event, [:anvil, :assignment, :created], %{}, metadata}
      assert metadata.assignment_id == "assign-1"
      assert metadata.queue_id == "queue-1"
    end

    test "emit_assignment_completed/2 emits event" do
      Telemetry.emit_assignment_completed("assign-1", %{queue_id: "queue-1"})

      assert_receive {:telemetry_event, [:anvil, :assignment, :completed], %{}, metadata}
      assert metadata.assignment_id == "assign-1"
    end

    test "emit_assignment_expired/2 emits event" do
      Telemetry.emit_assignment_expired("assign-1", %{queue_id: "queue-1"})

      assert_receive {:telemetry_event, [:anvil, :assignment, :expired], %{}, metadata}
      assert metadata.assignment_id == "assign-1"
    end

    test "emit_assignment_timed_out/2 emits batch timeout event" do
      Telemetry.emit_assignment_timed_out(15, %{queue_id: "queue-1", requeued: 12, escalated: 3})

      assert_receive {:telemetry_event, [:anvil, :assignment, :timed_out], measurements, metadata}
      assert measurements.count == 15
      assert metadata.requeued == 12
      assert metadata.escalated == 3
    end
  end

  describe "label events" do
    test "span_label_submit/2 emits start and stop events" do
      metadata = %{assignment_id: "assign-1", labeler_id: "labeler-1"}

      result =
        Telemetry.span_label_submit(metadata, fn ->
          {{:ok, %{schema_version_id: "v2", validation_errors: 0}},
           %{schema_version_id: "v2", validation_errors: 0}}
        end)

      assert result == {:ok, %{schema_version_id: "v2", validation_errors: 0}}

      assert_receive {:telemetry_event, [:anvil, :label, :submit, :start], _, start_metadata}
      assert start_metadata.assignment_id == "assign-1"

      assert_receive {:telemetry_event, [:anvil, :label, :submit, :stop], measurements,
                      stop_metadata}

      assert is_integer(measurements.duration)
      assert stop_metadata.schema_version_id == "v2"
    end

    test "emit_label_validation_failed/3 emits event with errors" do
      errors = [%{field: "coherence", message: "is required"}]

      Telemetry.emit_label_validation_failed("assign-1", errors, %{
        schema_version_id: "v2"
      })

      assert_receive {:telemetry_event, [:anvil, :label, :validation_failed], measurements,
                      metadata}

      assert measurements.error_count == 1
      assert metadata.assignment_id == "assign-1"
      assert metadata.errors == errors
    end
  end

  describe "agreement events" do
    test "span_agreement_compute/2 emits start and stop events" do
      metadata = %{sample_id: "sample-1", queue_id: "queue-1"}

      result =
        Telemetry.span_agreement_compute(metadata, fn ->
          {{:ok, 0.75}, %{metric: :fleiss_kappa, n_raters: 3, dimensions: 5}}
        end)

      assert result == {:ok, 0.75}

      assert_receive {:telemetry_event, [:anvil, :agreement, :compute, :start], _, _}

      assert_receive {:telemetry_event, [:anvil, :agreement, :compute, :stop], measurements,
                      stop_metadata}

      assert is_integer(measurements.duration)
      assert stop_metadata.metric == :fleiss_kappa
      assert stop_metadata.n_raters == 3
    end

    test "emit_low_agreement_score/2 emits event" do
      Telemetry.emit_low_agreement_score(0.38, %{
        sample_id: "sample-1",
        dimension: "novelty",
        threshold: 0.6
      })

      assert_receive {:telemetry_event, [:anvil, :agreement, :low_score], measurements, metadata}
      assert measurements.value == 0.38
      assert metadata.dimension == "novelty"
      assert metadata.threshold == 0.6
    end

    test "span_agreement_batch_recompute/2 emits start and stop events" do
      metadata = %{queue_id: "queue-1"}

      result =
        Telemetry.span_agreement_batch_recompute(metadata, fn ->
          {{:ok, %{samples_processed: 1500, duration_ms: 45000}}, %{samples_processed: 1500}}
        end)

      assert result == {:ok, %{samples_processed: 1500, duration_ms: 45000}}

      assert_receive {:telemetry_event, [:anvil, :agreement, :batch_recompute, :start], _, _}

      assert_receive {:telemetry_event, [:anvil, :agreement, :batch_recompute, :stop],
                      measurements, stop_metadata}

      assert is_integer(measurements.duration)
      assert stop_metadata.samples_processed == 1500
    end
  end

  describe "export events" do
    test "span_export_generate/2 emits start and stop events" do
      metadata = %{queue_id: "queue-1", format: :csv}

      result =
        Telemetry.span_export_generate(metadata, fn ->
          {{:ok, %{row_count: 5000, file_size_bytes: 1_200_000}}, %{row_count: 5000}}
        end)

      assert result == {:ok, %{row_count: 5000, file_size_bytes: 1_200_000}}

      assert_receive {:telemetry_event, [:anvil, :export, :generate, :start], _, start_metadata}
      assert start_metadata.format == :csv

      assert_receive {:telemetry_event, [:anvil, :export, :generate, :stop], measurements,
                      stop_metadata}

      assert is_integer(measurements.duration)
      assert stop_metadata.row_count == 5000
    end

    test "emit_export_progress/2 emits progress event" do
      Telemetry.emit_export_progress(10000, %{
        export_id: "export-1",
        total_rows: 50000,
        progress_pct: 20.0
      })

      assert_receive {:telemetry_event, [:anvil, :export, :progress], measurements, metadata}
      assert measurements.rows_processed == 10000
      assert metadata.export_id == "export-1"
      assert metadata.progress_pct == 20.0
    end

    test "emit_export_completed/2 emits event" do
      Telemetry.emit_export_completed("export-1", %{format: :csv, row_count: 5000})

      assert_receive {:telemetry_event, [:anvil, :export, :completed], %{}, metadata}
      assert metadata.export_id == "export-1"
      assert metadata.format == :csv
    end

    test "emit_export_failed/3 emits event with reason" do
      Telemetry.emit_export_failed("export-1", :disk_full, %{format: :csv})

      assert_receive {:telemetry_event, [:anvil, :export, :failed], %{}, metadata}
      assert metadata.export_id == "export-1"
      assert metadata.reason == :disk_full
    end
  end

  describe "storage events" do
    test "span_storage_query/3 emits start and stop events" do
      metadata = %{repo: Anvil.Repo}

      result =
        Telemetry.span_storage_query("list_labels", metadata, fn ->
          {{:ok, []}, %{row_count: 100}}
        end)

      assert result == {:ok, []}

      assert_receive {:telemetry_event, [:anvil, :storage, :query, :start], _, start_metadata}
      assert start_metadata.operation == "list_labels"

      assert_receive {:telemetry_event, [:anvil, :storage, :query, :stop], measurements,
                      stop_metadata}

      assert is_integer(measurements.duration)
      assert stop_metadata.row_count == 100
    end
  end

  describe "schema events" do
    test "emit_schema_validation/3 emits event" do
      Telemetry.emit_schema_validation("schema-1", true, %{field_count: 5})

      assert_receive {:telemetry_event, [:anvil, :schema, :validation], measurements, metadata}
      assert measurements.valid == 1
      assert metadata.schema_id == "schema-1"
      assert metadata.valid? == true
    end

    test "emit_schema_migration/3 emits event" do
      Telemetry.emit_schema_migration("v1", "v2", %{queue_id: "queue-1"})

      assert_receive {:telemetry_event, [:anvil, :schema, :migration], %{}, metadata}
      assert metadata.from_version == "v1"
      assert metadata.to_version == "v2"
    end
  end

  describe "generic span/3" do
    test "spans custom operations" do
      result =
        Telemetry.span(:custom_operation, %{queue_id: "queue-1"}, fn ->
          {{:ok, %{work_count: 42}}, %{work_count: 42}}
        end)

      assert result == {:ok, %{work_count: 42}}

      assert_receive {:telemetry_event, [:anvil, :custom_operation, :start], _, start_metadata}
      assert start_metadata.queue_id == "queue-1"

      assert_receive {:telemetry_event, [:anvil, :custom_operation, :stop], measurements,
                      stop_metadata}

      assert is_integer(measurements.duration)
      assert stop_metadata.work_count == 42
    end
  end
end
