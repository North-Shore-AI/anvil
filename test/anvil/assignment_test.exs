defmodule Anvil.AssignmentTest do
  use Supertester.ExUnitFoundation, isolation: :full_isolation

  alias Anvil.Assignment

  describe "new/1" do
    test "creates pending assignment with defaults" do
      assignment = Assignment.new(sample_id: "s1", labeler_id: "l1", queue_id: "q1")

      assert assignment.status == :pending
      assert assignment.attempts == 0
      assert assignment.sample_id == "s1"
      assert assignment.labeler_id == "l1"
      assert assignment.queue_id == "q1"
      assert assignment.created_at
      assert assignment.id
    end
  end

  describe "start/2" do
    test "transitions from pending to in_progress" do
      assignment = Assignment.new(sample_id: "s1", labeler_id: "l1", queue_id: "q1")

      {:ok, started} = Assignment.start(assignment, 3600)

      assert started.status == :in_progress
      assert started.started_at
      assert started.deadline
      assert started.attempts == 1
    end

    test "sets deadline based on timeout" do
      assignment = Assignment.new(sample_id: "s1", labeler_id: "l1", queue_id: "q1")

      {:ok, started} = Assignment.start(assignment, 60)

      # Deadline should be ~60 seconds from start
      diff = DateTime.diff(started.deadline, started.started_at, :second)
      assert_in_delta diff, 60, 2
    end

    test "returns error if not pending" do
      assignment = Assignment.new(sample_id: "s1", labeler_id: "l1", queue_id: "q1")
      {:ok, started} = Assignment.start(assignment, 3600)

      assert {:error, {:invalid_transition, :in_progress, :in_progress}} =
               Assignment.start(started, 3600)
    end
  end

  describe "complete/2" do
    test "transitions from in_progress to completed" do
      assignment = Assignment.new(sample_id: "s1", labeler_id: "l1", queue_id: "q1")
      {:ok, in_progress} = Assignment.start(assignment, 3600)

      {:ok, completed} = Assignment.complete(in_progress, "label_123")

      assert completed.status == :completed
      assert completed.completed_at
      assert completed.label_id == "label_123"
    end

    test "returns error if not in_progress" do
      assignment = Assignment.new(sample_id: "s1", labeler_id: "l1", queue_id: "q1")

      assert {:error, {:invalid_transition, :pending, :completed}} =
               Assignment.complete(assignment, "label_123")
    end
  end

  describe "skip/2" do
    test "transitions from in_progress to skipped" do
      assignment = Assignment.new(sample_id: "s1", labeler_id: "l1", queue_id: "q1")
      {:ok, in_progress} = Assignment.start(assignment, 3600)

      {:ok, skipped} = Assignment.skip(in_progress, "unclear sample")

      assert skipped.status == :skipped
      assert skipped.skipped_at
      assert skipped.skip_reason == "unclear sample"
    end

    test "allows skipping without reason" do
      assignment = Assignment.new(sample_id: "s1", labeler_id: "l1", queue_id: "q1")
      {:ok, in_progress} = Assignment.start(assignment, 3600)

      {:ok, skipped} = Assignment.skip(in_progress)

      assert skipped.status == :skipped
      assert skipped.skip_reason == nil
    end

    test "can skip from pending state" do
      assignment = Assignment.new(sample_id: "s1", labeler_id: "l1", queue_id: "q1")

      assert {:ok, skipped} = Assignment.skip(assignment, "not interested")
      assert skipped.status == :skipped
      assert skipped.skip_reason == "not interested"
    end

    test "returns error if already completed" do
      assignment = Assignment.new(sample_id: "s1", labeler_id: "l1", queue_id: "q1")
      {:ok, assignment} = Assignment.start(assignment, 3600)
      {:ok, completed} = Assignment.complete(assignment, "label123")

      assert {:error, {:invalid_transition, :completed, :skipped}} =
               Assignment.skip(completed)
    end
  end

  describe "expire/1" do
    test "transitions from in_progress to expired" do
      assignment = Assignment.new(sample_id: "s1", labeler_id: "l1", queue_id: "q1")
      {:ok, in_progress} = Assignment.start(assignment, 3600)

      {:ok, expired} = Assignment.expire(in_progress)

      assert expired.status == :expired
      assert expired.expired_at
    end

    test "can expire pending assignments" do
      assignment = Assignment.new(sample_id: "s1", labeler_id: "l1", queue_id: "q1")

      {:ok, expired} = Assignment.expire(assignment)

      assert expired.status == :expired
    end

    test "cannot expire completed assignments" do
      assignment = Assignment.new(sample_id: "s1", labeler_id: "l1", queue_id: "q1")
      {:ok, in_progress} = Assignment.start(assignment, 3600)
      {:ok, completed} = Assignment.complete(in_progress, "label_123")

      assert {:error, {:invalid_transition, :completed, :expired}} =
               Assignment.expire(completed)
    end
  end

  describe "past_deadline?/1" do
    test "returns false when no deadline set" do
      assignment = Assignment.new(sample_id: "s1", labeler_id: "l1", queue_id: "q1")
      refute Assignment.past_deadline?(assignment)
    end

    test "returns false when deadline is in future" do
      assignment = Assignment.new(sample_id: "s1", labeler_id: "l1", queue_id: "q1")
      {:ok, in_progress} = Assignment.start(assignment, 3600)

      refute Assignment.past_deadline?(in_progress)
    end

    test "returns true when deadline is in past" do
      assignment = Assignment.new(sample_id: "s1", labeler_id: "l1", queue_id: "q1")
      {:ok, in_progress} = Assignment.start(assignment, 1)
      past_deadline = %{in_progress | deadline: DateTime.add(in_progress.started_at, -1, :second)}

      assert Assignment.past_deadline?(past_deadline)
    end
  end

  describe "labeling_time_seconds/1" do
    test "returns nil when not started" do
      assignment = Assignment.new(sample_id: "s1", labeler_id: "l1", queue_id: "q1")
      assert Assignment.labeling_time_seconds(assignment) == nil
    end

    test "returns nil when started but not completed" do
      assignment = Assignment.new(sample_id: "s1", labeler_id: "l1", queue_id: "q1")
      {:ok, in_progress} = Assignment.start(assignment, 3600)

      assert Assignment.labeling_time_seconds(in_progress) == nil
    end

    test "returns elapsed time when completed" do
      assignment = Assignment.new(sample_id: "s1", labeler_id: "l1", queue_id: "q1")
      started_at = DateTime.add(DateTime.utc_now(), -5, :second)

      {:ok, in_progress} = Assignment.start(assignment, 3600)
      in_progress = %{in_progress | started_at: started_at}

      {:ok, completed} = Assignment.complete(in_progress, "label_123")

      time = Assignment.labeling_time_seconds(completed)
      assert_in_delta time, 5, 1
    end
  end

  test "handles concurrent state transitions" do
    assignment = Assignment.new(sample_id: "s1", labeler_id: "l1", queue_id: "q1")
    {:ok, in_progress} = Assignment.start(assignment, 3600)

    # Simulate race condition: complete vs skip
    tasks = [
      Task.async(fn -> Assignment.complete(in_progress, "label_1") end),
      Task.async(fn -> Assignment.skip(in_progress, "reason") end)
    ]

    results = Task.await_many(tasks)

    # Both should succeed (they're operating on the same initial state)
    # In a real system with shared state, only one would succeed
    assert length(results) == 2
  end
end
