defmodule Anvil.Storage.PostgresTest do
  # Use async: false to avoid sandbox ownership conflicts
  use ExUnit.Case, async: false

  alias Anvil.Storage.Postgres
  alias Anvil.{Assignment, Label}

  # Use Ecto sandbox for isolation
  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Anvil.Repo)
    {:ok, state} = Postgres.init(repo: Anvil.Repo)

    # Create required foreign key records
    labeler_id = Ecto.UUID.generate()

    {:ok, _labeler} =
      Anvil.Repo.insert(%Anvil.Schema.Labeler{
        id: labeler_id,
        external_id: "test_labeler"
      })

    schema_version_id = Ecto.UUID.generate()
    queue_id = Ecto.UUID.generate()

    {:ok, _schema_version} =
      Anvil.Repo.insert(%Anvil.Schema.SchemaVersion{
        id: schema_version_id,
        queue_id: queue_id,
        version_number: 1,
        schema_definition: %{}
      })

    {:ok, _queue} =
      Anvil.Repo.insert(%Anvil.Schema.Queue{
        id: queue_id,
        name: "test_queue",
        schema_version_id: schema_version_id,
        policy: %{}
      })

    {:ok,
     state: state,
     queue_id: queue_id,
     labeler_id: labeler_id,
     schema_version_id: schema_version_id}
  end

  describe "put_sample/2" do
    test "persists sample reference to database", %{state: state} do
      sample = %{id: Ecto.UUID.generate(), metadata: %{source: "test"}}

      assert {:ok, _state} = Postgres.put_sample(state, sample)

      # Verify sample was persisted
      {:ok, retrieved, _state} = Postgres.get_sample(state, sample.id)
      assert retrieved.id == sample.id
      # Ecto converts map keys to strings
      assert retrieved.metadata == %{"source" => "test"}
    end

    test "handles duplicate sample inserts gracefully", %{state: state} do
      sample = %{id: Ecto.UUID.generate(), metadata: %{}}

      {:ok, state} = Postgres.put_sample(state, sample)
      {:ok, _state} = Postgres.put_sample(state, sample)

      # Should not error on duplicate
      {:ok, samples, _state} = Postgres.list_samples(state, sample_ids: [sample.id])
      assert length(samples) == 1
    end
  end

  describe "list_samples/2" do
    test "returns samples matching filters", %{state: state} do
      sample1 = %{id: Ecto.UUID.generate(), metadata: %{}}
      sample2 = %{id: Ecto.UUID.generate(), metadata: %{}}
      sample3 = %{id: Ecto.UUID.generate(), metadata: %{}}

      {:ok, state} = Postgres.put_sample(state, sample1)
      {:ok, state} = Postgres.put_sample(state, sample2)
      {:ok, state} = Postgres.put_sample(state, sample3)

      {:ok, samples, _state} = Postgres.list_samples(state, sample_ids: [sample1.id, sample2.id])
      assert length(samples) == 2

      sample_ids = Enum.map(samples, & &1.id)
      assert sample1.id in sample_ids
      assert sample2.id in sample_ids
    end

    test "returns empty list when no samples match", %{state: state} do
      {:ok, samples, _state} = Postgres.list_samples(state, sample_ids: [Ecto.UUID.generate()])
      assert samples == []
    end
  end

  describe "put_assignment/2" do
    test "persists assignment to database", %{
      state: state,
      queue_id: queue_id,
      labeler_id: labeler_id
    } do
      sample_id = Ecto.UUID.generate()

      assignment =
        Assignment.new(
          queue_id: queue_id,
          sample_id: sample_id,
          labeler_id: labeler_id
        )

      assert {:ok, _state} = Postgres.put_assignment(state, assignment)

      # Verify assignment was persisted
      {:ok, retrieved, _state} = Postgres.get_assignment(state, assignment.id)
      assert retrieved.id == assignment.id
      assert retrieved.queue_id == queue_id
      assert retrieved.sample_id == sample_id
      assert retrieved.labeler_id == labeler_id
    end

    test "updates existing assignment", %{
      state: state,
      queue_id: queue_id,
      labeler_id: labeler_id
    } do
      assignment =
        Assignment.new(
          queue_id: queue_id,
          sample_id: Ecto.UUID.generate(),
          labeler_id: labeler_id
        )

      {:ok, state} = Postgres.put_assignment(state, assignment)

      # Start the assignment
      {:ok, updated_assignment} = Assignment.start(assignment, 3600)
      {:ok, _state} = Postgres.put_assignment(state, updated_assignment)

      {:ok, retrieved, _state} = Postgres.get_assignment(state, assignment.id)
      assert retrieved.status == :in_progress
    end
  end

  describe "list_assignments/2" do
    test "filters by queue_id", %{state: state, queue_id: queue_id, labeler_id: labeler_id} do
      # Create another queue for testing
      schema_version_id2 = Ecto.UUID.generate()
      queue_id2 = Ecto.UUID.generate()

      {:ok, _schema_version} =
        Anvil.Repo.insert(%Anvil.Schema.SchemaVersion{
          id: schema_version_id2,
          queue_id: queue_id2,
          version_number: 1,
          schema_definition: %{}
        })

      {:ok, _queue} =
        Anvil.Repo.insert(%Anvil.Schema.Queue{
          id: queue_id2,
          name: "test_queue2",
          schema_version_id: schema_version_id2,
          policy: %{}
        })

      assignment1 =
        Assignment.new(
          queue_id: queue_id,
          sample_id: Ecto.UUID.generate(),
          labeler_id: labeler_id
        )

      assignment2 =
        Assignment.new(
          queue_id: queue_id2,
          sample_id: Ecto.UUID.generate(),
          labeler_id: labeler_id
        )

      {:ok, state} = Postgres.put_assignment(state, assignment1)
      {:ok, state} = Postgres.put_assignment(state, assignment2)

      {:ok, assignments, _state} = Postgres.list_assignments(state, queue_id: queue_id)
      assert length(assignments) == 1
      assert hd(assignments).queue_id == queue_id
    end

    test "filters by labeler_id", %{state: state, queue_id: queue_id, labeler_id: labeler_id} do
      # Create another labeler for testing
      labeler_id2 = Ecto.UUID.generate()

      {:ok, _labeler} =
        Anvil.Repo.insert(%Anvil.Schema.Labeler{
          id: labeler_id2,
          external_id: "test_labeler2"
        })

      assignment1 =
        Assignment.new(
          queue_id: queue_id,
          sample_id: Ecto.UUID.generate(),
          labeler_id: labeler_id
        )

      assignment2 =
        Assignment.new(
          queue_id: queue_id,
          sample_id: Ecto.UUID.generate(),
          labeler_id: labeler_id2
        )

      {:ok, state} = Postgres.put_assignment(state, assignment1)
      {:ok, state} = Postgres.put_assignment(state, assignment2)

      {:ok, assignments, _state} = Postgres.list_assignments(state, labeler_id: labeler_id)
      assert length(assignments) == 1
      assert hd(assignments).labeler_id == labeler_id
    end

    test "filters by status", %{state: state, queue_id: queue_id, labeler_id: labeler_id} do
      pending =
        Assignment.new(
          queue_id: queue_id,
          sample_id: Ecto.UUID.generate(),
          labeler_id: labeler_id
        )

      in_progress =
        Assignment.new(
          queue_id: queue_id,
          sample_id: Ecto.UUID.generate(),
          labeler_id: labeler_id
        )

      {:ok, in_progress} = Assignment.start(in_progress, 3600)

      {:ok, state} = Postgres.put_assignment(state, pending)
      {:ok, state} = Postgres.put_assignment(state, in_progress)

      {:ok, assignments, _state} = Postgres.list_assignments(state, status: :pending)
      assert length(assignments) == 1
      assert hd(assignments).status == :pending
    end
  end

  describe "put_label/2" do
    test "persists label to database", %{state: state, queue_id: queue_id, labeler_id: labeler_id} do
      assignment =
        Assignment.new(
          queue_id: queue_id,
          sample_id: Ecto.UUID.generate(),
          labeler_id: labeler_id
        )

      {:ok, state} = Postgres.put_assignment(state, assignment)

      label =
        Label.new(
          assignment_id: assignment.id,
          sample_id: assignment.sample_id,
          labeler_id: assignment.labeler_id,
          values: %{rating: 5, comment: "Good"}
        )

      assert {:ok, _state} = Postgres.put_label(state, label)

      # Verify label was persisted
      {:ok, retrieved, _state} = Postgres.get_label(state, label.id)
      assert retrieved.id == label.id
      assert retrieved.assignment_id == assignment.id
    end
  end

  describe "list_labels/2" do
    test "filters by assignment_id", %{state: state, queue_id: queue_id, labeler_id: labeler_id} do
      assignment1 =
        Assignment.new(
          queue_id: queue_id,
          sample_id: Ecto.UUID.generate(),
          labeler_id: labeler_id
        )

      assignment2 =
        Assignment.new(
          queue_id: queue_id,
          sample_id: Ecto.UUID.generate(),
          labeler_id: labeler_id
        )

      {:ok, state} = Postgres.put_assignment(state, assignment1)
      {:ok, state} = Postgres.put_assignment(state, assignment2)

      label1 =
        Label.new(
          assignment_id: assignment1.id,
          sample_id: assignment1.sample_id,
          labeler_id: assignment1.labeler_id,
          values: %{rating: 5}
        )

      label2 =
        Label.new(
          assignment_id: assignment2.id,
          sample_id: assignment2.sample_id,
          labeler_id: assignment2.labeler_id,
          values: %{rating: 3}
        )

      {:ok, state} = Postgres.put_label(state, label1)
      {:ok, state} = Postgres.put_label(state, label2)

      {:ok, labels, _state} = Postgres.list_labels(state, assignment_id: assignment1.id)
      assert length(labels) == 1
      assert hd(labels).assignment_id == assignment1.id
    end

    test "filters by labeler_id", %{state: state, queue_id: queue_id, labeler_id: labeler_id} do
      # Create another labeler for testing
      labeler_id2 = Ecto.UUID.generate()

      {:ok, _labeler} =
        Anvil.Repo.insert(%Anvil.Schema.Labeler{
          id: labeler_id2,
          external_id: "test_labeler3"
        })

      assignment1 =
        Assignment.new(
          queue_id: queue_id,
          sample_id: Ecto.UUID.generate(),
          labeler_id: labeler_id
        )

      assignment2 =
        Assignment.new(
          queue_id: queue_id,
          sample_id: Ecto.UUID.generate(),
          labeler_id: labeler_id2
        )

      {:ok, state} = Postgres.put_assignment(state, assignment1)
      {:ok, state} = Postgres.put_assignment(state, assignment2)

      label1 =
        Label.new(
          assignment_id: assignment1.id,
          sample_id: assignment1.sample_id,
          labeler_id: labeler_id,
          values: %{rating: 5}
        )

      label2 =
        Label.new(
          assignment_id: assignment2.id,
          sample_id: assignment2.sample_id,
          labeler_id: labeler_id2,
          values: %{rating: 3}
        )

      {:ok, state} = Postgres.put_label(state, label1)
      {:ok, state} = Postgres.put_label(state, label2)

      {:ok, labels, _state} = Postgres.list_labels(state, labeler_id: labeler_id)
      assert length(labels) == 1
      assert hd(labels).labeler_id == labeler_id
    end
  end
end
