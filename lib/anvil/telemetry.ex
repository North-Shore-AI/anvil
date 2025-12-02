defmodule Anvil.Telemetry do
  @moduledoc """
  Telemetry integration for Anvil labeling system.

  Provides instrumentation for all core operations following the event naming convention:
  `[:anvil, domain, action, lifecycle?]`

  ## Event Categories

  - **Queue Events**: queue creation, status changes
  - **Assignment Events**: dispatch, timeout, completion
  - **Label Events**: submission, validation
  - **Agreement Events**: computation, low score detection
  - **Export Events**: generation, progress tracking
  - **Storage Events**: query timing

  ## Usage

  ### Emitting Events

      # Count event
      Anvil.Telemetry.emit_queue_created(queue_id, metadata)

      # Duration event (using span)
      Anvil.Telemetry.span(:assignment_dispatch, metadata, fn ->
        result = perform_dispatch()
        {result, additional_metadata}
      end)

  ### Attaching Handlers

      :telemetry.attach(
        "my-handler",
        [:anvil, :label, :submit, :stop],
        &MyModule.handle_event/4,
        nil
      )

  ### Testing

      import Telemetry.Test

      test "emits telemetry event" do
        attach_telemetry_handler([:anvil, :queue, :created])

        Anvil.Telemetry.emit_queue_created(queue_id, %{})

        assert_received {:telemetry, [:anvil, :queue, :created], %{}, %{queue_id: ^queue_id}}
      end
  """

  # Queue Events

  @doc """
  Emits a queue created event.
  """
  @spec emit_queue_created(binary(), map()) :: :ok
  def emit_queue_created(queue_id, metadata) do
    :telemetry.execute(
      [:anvil, :queue, :created],
      %{},
      Map.merge(metadata, %{queue_id: queue_id})
    )
  end

  @doc """
  Emits a queue status changed event.
  """
  @spec emit_queue_status_changed(binary(), atom(), atom(), map()) :: :ok
  def emit_queue_status_changed(queue_id, from_status, to_status, metadata) do
    :telemetry.execute(
      [:anvil, :queue, :status_changed],
      %{},
      Map.merge(metadata, %{
        queue_id: queue_id,
        from_status: from_status,
        to_status: to_status
      })
    )
  end

  # Assignment Events

  @doc """
  Wraps assignment dispatch in a telemetry span.

  Returns `{result, metadata}` tuple from the function.
  """
  @spec span_assignment_dispatch(map(), (-> {any(), map()})) :: any()
  def span_assignment_dispatch(metadata, fun) do
    :telemetry.span(
      [:anvil, :assignment, :dispatch],
      metadata,
      fun
    )
  end

  @doc """
  Emits an assignment created event.
  """
  @spec emit_assignment_created(binary(), map()) :: :ok
  def emit_assignment_created(assignment_id, metadata) do
    :telemetry.execute(
      [:anvil, :assignment, :created],
      %{},
      Map.merge(metadata, %{assignment_id: assignment_id})
    )
  end

  @doc """
  Emits an assignment completed event.
  """
  @spec emit_assignment_completed(binary(), map()) :: :ok
  def emit_assignment_completed(assignment_id, metadata) do
    :telemetry.execute(
      [:anvil, :assignment, :completed],
      %{},
      Map.merge(metadata, %{assignment_id: assignment_id})
    )
  end

  @doc """
  Emits an assignment expired event.
  """
  @spec emit_assignment_expired(binary(), map()) :: :ok
  def emit_assignment_expired(assignment_id, metadata) do
    :telemetry.execute(
      [:anvil, :assignment, :expired],
      %{},
      Map.merge(metadata, %{assignment_id: assignment_id})
    )
  end

  @doc """
  Emits an assignment timeout event (batch).
  """
  @spec emit_assignment_timed_out(integer(), map()) :: :ok
  def emit_assignment_timed_out(count, metadata) do
    :telemetry.execute(
      [:anvil, :assignment, :timed_out],
      %{count: count},
      metadata
    )
  end

  # Label Events

  @doc """
  Wraps label submission in a telemetry span.
  """
  @spec span_label_submit(map(), (-> {any(), map()})) :: any()
  def span_label_submit(metadata, fun) do
    :telemetry.span(
      [:anvil, :label, :submit],
      metadata,
      fun
    )
  end

  @doc """
  Emits a label validation failed event.
  """
  @spec emit_label_validation_failed(binary(), list(), map()) :: :ok
  def emit_label_validation_failed(assignment_id, errors, metadata) do
    :telemetry.execute(
      [:anvil, :label, :validation_failed],
      %{error_count: length(errors)},
      Map.merge(metadata, %{
        assignment_id: assignment_id,
        errors: errors
      })
    )
  end

  # Agreement Events

  @doc """
  Wraps agreement computation in a telemetry span.
  """
  @spec span_agreement_compute(map(), (-> {any(), map()})) :: any()
  def span_agreement_compute(metadata, fun) do
    :telemetry.span(
      [:anvil, :agreement, :compute],
      metadata,
      fun
    )
  end

  @doc """
  Emits a low agreement score event.
  """
  @spec emit_low_agreement_score(float(), map()) :: :ok
  def emit_low_agreement_score(score, metadata) do
    :telemetry.execute(
      [:anvil, :agreement, :low_score],
      %{value: score},
      metadata
    )
  end

  @doc """
  Wraps batch agreement recomputation in a telemetry span.
  """
  @spec span_agreement_batch_recompute(map(), (-> {any(), map()})) :: any()
  def span_agreement_batch_recompute(metadata, fun) do
    :telemetry.span(
      [:anvil, :agreement, :batch_recompute],
      metadata,
      fun
    )
  end

  # Export Events

  @doc """
  Wraps export generation in a telemetry span.
  """
  @spec span_export_generate(map(), (-> {any(), map()})) :: any()
  def span_export_generate(metadata, fun) do
    :telemetry.span(
      [:anvil, :export, :generate],
      metadata,
      fun
    )
  end

  @doc """
  Emits an export progress event.
  """
  @spec emit_export_progress(integer(), map()) :: :ok
  def emit_export_progress(rows_processed, metadata) do
    :telemetry.execute(
      [:anvil, :export, :progress],
      %{rows_processed: rows_processed},
      metadata
    )
  end

  @doc """
  Emits an export completed event.
  """
  @spec emit_export_completed(binary(), map()) :: :ok
  def emit_export_completed(export_id, metadata) do
    :telemetry.execute(
      [:anvil, :export, :completed],
      %{},
      Map.merge(metadata, %{export_id: export_id})
    )
  end

  @doc """
  Emits an export failed event.
  """
  @spec emit_export_failed(binary(), term(), map()) :: :ok
  def emit_export_failed(export_id, reason, metadata) do
    :telemetry.execute(
      [:anvil, :export, :failed],
      %{},
      Map.merge(metadata, %{
        export_id: export_id,
        reason: reason
      })
    )
  end

  # Storage Events

  @doc """
  Wraps storage query in a telemetry span.
  """
  @spec span_storage_query(binary(), map(), (-> {any(), map()})) :: any()
  def span_storage_query(operation, metadata, fun) do
    :telemetry.span(
      [:anvil, :storage, :query],
      Map.merge(metadata, %{operation: operation}),
      fun
    )
  end

  # Schema Migration Events

  @doc """
  Emits a schema validation event.
  """
  @spec emit_schema_validation(binary(), boolean(), map()) :: :ok
  def emit_schema_validation(schema_id, valid?, metadata) do
    :telemetry.execute(
      [:anvil, :schema, :validation],
      %{valid: if(valid?, do: 1, else: 0)},
      Map.merge(metadata, %{schema_id: schema_id, valid?: valid?})
    )
  end

  @doc """
  Emits a schema migration event.
  """
  @spec emit_schema_migration(binary(), binary(), map()) :: :ok
  def emit_schema_migration(from_version, to_version, metadata) do
    :telemetry.execute(
      [:anvil, :schema, :migration],
      %{},
      Map.merge(metadata, %{
        from_version: from_version,
        to_version: to_version
      })
    )
  end

  # Generic span helper

  @doc """
  Generic telemetry span wrapper.

  The function must return a `{result, metadata}` tuple where metadata will be
  merged with the initial metadata for the stop/exception events.

  ## Examples

      Anvil.Telemetry.span(:my_operation, %{queue_id: id}, fn ->
        result = do_work()
        {result, %{work_count: 42}}
      end)

  This emits:
  - `[:anvil, :my_operation, :start]` with initial metadata
  - `[:anvil, :my_operation, :stop]` with duration and merged metadata
  - `[:anvil, :my_operation, :exception]` if an error occurs
  """
  @spec span(atom(), map(), (-> {any(), map()})) :: any()
  def span(operation, metadata, fun) do
    :telemetry.span(
      [:anvil, operation],
      metadata,
      fun
    )
  end
end
