defmodule Anvil.Workers.RetentionSweepTest do
  use Supertester.ExUnitFoundation, isolation: :full_isolation
  use Oban.Testing, repo: Anvil.Repo

  alias Anvil.Repo
  alias Anvil.Schema.AuditLog
  alias Anvil.Workers.RetentionSweep

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})

    :ok
  end

  describe "perform/1" do
    test "deletes audit logs older than retention period" do
      # Create old audit logs (older than 7 years)
      old_date = DateTime.add(DateTime.utc_now(), -2556, :day) |> DateTime.truncate(:second)

      {:ok, old_log1} =
        Repo.insert(%AuditLog{
          entity_type: :queue,
          entity_id: Ecto.UUID.generate(),
          action: :created,
          occurred_at: old_date,
          metadata: %{}
        })

      {:ok, old_log2} =
        Repo.insert(%AuditLog{
          entity_type: :assignment,
          entity_id: Ecto.UUID.generate(),
          action: :updated,
          occurred_at: old_date,
          metadata: %{}
        })

      # Create recent audit log
      {:ok, recent_log} =
        Repo.insert(%AuditLog{
          entity_type: :label,
          entity_id: Ecto.UUID.generate(),
          action: :created,
          occurred_at: DateTime.utc_now() |> DateTime.truncate(:second),
          metadata: %{}
        })

      # Perform the job with default retention (2555 days)
      assert :ok = perform_job(RetentionSweep, %{})

      # Verify old logs were deleted
      assert Repo.get(AuditLog, old_log1.id) == nil
      assert Repo.get(AuditLog, old_log2.id) == nil

      # Verify recent log still exists
      assert Repo.get(AuditLog, recent_log.id) != nil
    end

    test "respects custom retention period" do
      # Create audit log that's 30 days old
      old_date = DateTime.add(DateTime.utc_now(), -31, :day) |> DateTime.truncate(:second)

      {:ok, old_log} =
        Repo.insert(%AuditLog{
          entity_type: :queue,
          entity_id: Ecto.UUID.generate(),
          action: :created,
          occurred_at: old_date,
          metadata: %{}
        })

      # Create recent audit log (29 days old)
      recent_date = DateTime.add(DateTime.utc_now(), -29, :day) |> DateTime.truncate(:second)

      {:ok, recent_log} =
        Repo.insert(%AuditLog{
          entity_type: :assignment,
          entity_id: Ecto.UUID.generate(),
          action: :updated,
          occurred_at: recent_date,
          metadata: %{}
        })

      # Perform the job with 30-day retention
      assert :ok = perform_job(RetentionSweep, %{"retention_days" => 30})

      # Verify old log was deleted
      assert Repo.get(AuditLog, old_log.id) == nil

      # Verify recent log still exists
      assert Repo.get(AuditLog, recent_log.id) != nil
    end

    test "dry run mode counts without deleting" do
      # Create old audit logs
      old_date = DateTime.add(DateTime.utc_now(), -2556, :day) |> DateTime.truncate(:second)

      {:ok, old_log} =
        Repo.insert(%AuditLog{
          entity_type: :queue,
          entity_id: Ecto.UUID.generate(),
          action: :created,
          occurred_at: old_date,
          metadata: %{}
        })

      # Perform the job in dry run mode
      assert :ok = perform_job(RetentionSweep, %{"dry_run" => true})

      # Verify log still exists
      assert Repo.get(AuditLog, old_log.id) != nil
    end

    test "handles empty result set gracefully" do
      # No audit logs in database
      # Perform the job
      assert :ok = perform_job(RetentionSweep, %{})
    end
  end

  describe "delete_old_audit_logs/2" do
    test "deletes logs older than cutoff" do
      old_date = DateTime.add(DateTime.utc_now(), -100, :day) |> DateTime.truncate(:second)

      {:ok, old_log} =
        Repo.insert(%AuditLog{
          entity_type: :queue,
          entity_id: Ecto.UUID.generate(),
          action: :created,
          occurred_at: old_date,
          metadata: %{}
        })

      cutoff = DateTime.add(DateTime.utc_now(), -50, :day)

      {count, _} = RetentionSweep.delete_old_audit_logs(cutoff)

      assert count == 1
      assert Repo.get(AuditLog, old_log.id) == nil
    end

    test "dry run returns count without deleting" do
      old_date = DateTime.add(DateTime.utc_now(), -100, :day) |> DateTime.truncate(:second)

      {:ok, old_log} =
        Repo.insert(%AuditLog{
          entity_type: :queue,
          entity_id: Ecto.UUID.generate(),
          action: :created,
          occurred_at: old_date,
          metadata: %{}
        })

      cutoff = DateTime.add(DateTime.utc_now(), -50, :day)

      {count, _} = RetentionSweep.delete_old_audit_logs(cutoff, true)

      assert count == 1
      assert Repo.get(AuditLog, old_log.id) != nil
    end

    test "returns zero count when no logs to delete" do
      cutoff = DateTime.add(DateTime.utc_now(), -50, :day)

      {count, _} = RetentionSweep.delete_old_audit_logs(cutoff)

      assert count == 0
    end
  end

  describe "enqueue/1" do
    test "enqueues a job with default retention" do
      assert {:ok, %Oban.Job{} = job} = RetentionSweep.enqueue()
      assert job.args["retention_days"] == 2555
      assert job.args["dry_run"] == false
      assert job.queue == "maintenance"
    end

    test "enqueues a job with custom retention" do
      assert {:ok, %Oban.Job{} = job} = RetentionSweep.enqueue(retention_days: 90)
      assert job.args["retention_days"] == 90
    end

    test "enqueues a job in dry run mode" do
      assert {:ok, %Oban.Job{} = job} = RetentionSweep.enqueue(dry_run: true)
      assert job.args["dry_run"] == true
    end
  end

  describe "telemetry events" do
    test "emits started and completed events" do
      # Set up telemetry handler
      test_pid = self()
      events = [:started, :completed]

      for event <- events do
        :telemetry.attach(
          "test-retention-#{event}",
          [:anvil, :workers, :retention_sweep, event],
          fn _event_name, measurements, metadata, _config ->
            send(test_pid, {:telemetry, event, measurements, metadata})
          end,
          nil
        )
      end

      # Create an old audit log
      old_date = DateTime.add(DateTime.utc_now(), -2556, :day) |> DateTime.truncate(:second)

      {:ok, _old_log} =
        Repo.insert(%AuditLog{
          entity_type: :queue,
          entity_id: Ecto.UUID.generate(),
          action: :created,
          occurred_at: old_date,
          metadata: %{}
        })

      # Perform the job
      perform_job(RetentionSweep, %{})

      # Verify telemetry events
      assert_receive {:telemetry, :started, %{}, %{retention_days: 2555, dry_run: false}}

      assert_receive {:telemetry, :completed, %{audit_logs_deleted: 1},
                      %{retention_days: 2555, dry_run: false}}

      # Cleanup
      for event <- events do
        :telemetry.detach("test-retention-#{event}")
      end
    end
  end
end
