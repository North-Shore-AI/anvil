defmodule Anvil.Workers.TimeoutCheckerTest do
  use Supertester.ExUnitFoundation, isolation: :full_isolation
  use Oban.Testing, repo: Anvil.Repo

  alias Anvil.Repo
  alias Anvil.Schema.{Assignment, Queue, Labeler}
  alias Anvil.Workers.TimeoutChecker

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})

    # Create queue with temporary ID to satisfy foreign key constraint
    queue_id = Ecto.UUID.generate()

    # Create schema version first
    {:ok, schema_version} =
      Repo.insert(%Anvil.Schema.SchemaVersion{
        queue_id: queue_id,
        version_number: 1,
        schema_definition: %{"type" => "object"}
      })

    # Now create the queue with the schema version
    {:ok, queue} =
      Repo.insert(%Queue{
        id: queue_id,
        name: "test_queue_#{:erlang.unique_integer([:positive])}",
        schema_version_id: schema_version.id,
        policy: %{"type" => "round_robin"}
      })

    # Create test labeler
    {:ok, labeler} =
      Repo.insert(%Labeler{
        external_id: "labeler_1"
      })

    {:ok, queue_id: queue.id, labeler_id: labeler.id}
  end

  describe "perform/1" do
    test "finds and requeues timed out assignments", %{queue_id: queue_id, labeler_id: labeler_id} do
      # Create a reserved assignment that has timed out
      past_deadline =
        DateTime.add(DateTime.utc_now(), -3600, :second) |> DateTime.truncate(:second)

      sample_id = Ecto.UUID.generate()

      {:ok, assignment} =
        Repo.insert(%Assignment{
          queue_id: queue_id,
          labeler_id: labeler_id,
          sample_id: sample_id,
          status: :reserved,
          deadline: past_deadline,
          reserved_at: DateTime.add(past_deadline, -3600, :second) |> DateTime.truncate(:second)
        })

      # Perform the job
      assert :ok = perform_job(TimeoutChecker, %{})

      # Check assignment was marked as timed out and requeued
      updated = Repo.get!(Assignment, assignment.id)
      assert updated.status == :requeued
      assert updated.requeue_attempts == 1
    end

    test "ignores assignments that haven't timed out yet", %{
      queue_id: queue_id,
      labeler_id: labeler_id
    } do
      # Create a reserved assignment with future deadline
      future_deadline =
        DateTime.add(DateTime.utc_now(), 3600, :second) |> DateTime.truncate(:second)

      sample_id = Ecto.UUID.generate()

      {:ok, assignment} =
        Repo.insert(%Assignment{
          queue_id: queue_id,
          labeler_id: labeler_id,
          sample_id: sample_id,
          status: :reserved,
          deadline: future_deadline,
          reserved_at: DateTime.utc_now() |> DateTime.truncate(:second)
        })

      # Perform the job
      assert :ok = perform_job(TimeoutChecker, %{})

      # Check assignment status hasn't changed
      updated = Repo.get!(Assignment, assignment.id)
      assert updated.status == :reserved
    end

    test "ignores non-reserved assignments", %{queue_id: queue_id, labeler_id: labeler_id} do
      sample_id = Ecto.UUID.generate()

      # Create a pending assignment
      {:ok, assignment} =
        Repo.insert(%Assignment{
          queue_id: queue_id,
          labeler_id: labeler_id,
          sample_id: sample_id,
          status: :pending
        })

      # Perform the job
      assert :ok = perform_job(TimeoutChecker, %{})

      # Check assignment status hasn't changed
      updated = Repo.get!(Assignment, assignment.id)
      assert updated.status == :pending
    end

    test "processes multiple timed out assignments", %{queue_id: queue_id, labeler_id: labeler_id} do
      past_deadline =
        DateTime.add(DateTime.utc_now(), -3600, :second) |> DateTime.truncate(:second)

      # Create multiple timed out assignments
      sample_ids = for _ <- 1..5, do: Ecto.UUID.generate()

      assignments =
        for sample_id <- sample_ids do
          {:ok, assignment} =
            Repo.insert(%Assignment{
              queue_id: queue_id,
              labeler_id: labeler_id,
              sample_id: sample_id,
              status: :reserved,
              deadline: past_deadline,
              reserved_at:
                DateTime.add(past_deadline, -3600, :second) |> DateTime.truncate(:second)
            })

          assignment
        end

      # Perform the job
      assert :ok = perform_job(TimeoutChecker, %{})

      # Check all assignments were requeued
      for assignment <- assignments do
        updated = Repo.get!(Assignment, assignment.id)
        assert updated.status == :requeued
        assert updated.requeue_attempts == 1
      end
    end

    test "increments requeue_attempts counter", %{queue_id: queue_id, labeler_id: labeler_id} do
      past_deadline =
        DateTime.add(DateTime.utc_now(), -3600, :second) |> DateTime.truncate(:second)

      sample_id = Ecto.UUID.generate()

      {:ok, assignment} =
        Repo.insert(%Assignment{
          queue_id: queue_id,
          labeler_id: labeler_id,
          sample_id: sample_id,
          status: :reserved,
          deadline: past_deadline,
          reserved_at: DateTime.add(past_deadline, -3600, :second) |> DateTime.truncate(:second),
          requeue_attempts: 2
        })

      # Perform the job
      assert :ok = perform_job(TimeoutChecker, %{})

      # Check requeue_attempts was incremented
      updated = Repo.get!(Assignment, assignment.id)
      assert updated.requeue_attempts == 3
    end
  end

  describe "handle_timeout/1" do
    test "transitions assignment from reserved to timed_out to requeued", %{
      queue_id: queue_id,
      labeler_id: labeler_id
    } do
      past_deadline =
        DateTime.add(DateTime.utc_now(), -3600, :second) |> DateTime.truncate(:second)

      sample_id = Ecto.UUID.generate()

      {:ok, assignment} =
        Repo.insert(%Assignment{
          queue_id: queue_id,
          labeler_id: labeler_id,
          sample_id: sample_id,
          status: :reserved,
          deadline: past_deadline,
          reserved_at: DateTime.add(past_deadline, -3600, :second) |> DateTime.truncate(:second)
        })

      # Handle timeout
      assert {:ok, :requeued} = TimeoutChecker.handle_timeout(assignment)

      # Verify final state
      updated = Repo.get!(Assignment, assignment.id)
      assert updated.status == :requeued
      assert updated.requeue_attempts == 1
    end
  end

  describe "telemetry events" do
    test "emits started and completed events", %{queue_id: queue_id, labeler_id: labeler_id} do
      # Set up telemetry handler
      test_pid = self()
      events = [:started, :completed]

      for event <- events do
        :telemetry.attach(
          "test-#{event}",
          [:anvil, :workers, :timeout_checker, event],
          fn _event_name, measurements, metadata, _config ->
            send(test_pid, {:telemetry, event, measurements, metadata})
          end,
          nil
        )
      end

      # Create a timed out assignment
      past_deadline =
        DateTime.add(DateTime.utc_now(), -3600, :second) |> DateTime.truncate(:second)

      sample_id = Ecto.UUID.generate()

      {:ok, _assignment} =
        Repo.insert(%Assignment{
          queue_id: queue_id,
          labeler_id: labeler_id,
          sample_id: sample_id,
          status: :reserved,
          deadline: past_deadline,
          reserved_at: DateTime.add(past_deadline, -3600, :second) |> DateTime.truncate(:second)
        })

      # Perform the job
      perform_job(TimeoutChecker, %{})

      # Verify telemetry events
      assert_receive {:telemetry, :started, %{}, %{}}

      assert_receive {:telemetry, :completed, %{timed_out: 1, requeued: 1, failed: 0}, %{}}

      # Cleanup
      for event <- events do
        :telemetry.detach("test-#{event}")
      end
    end
  end
end
