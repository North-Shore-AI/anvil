defmodule Anvil.QueueTest do
  use Supertester.ExUnitFoundation, isolation: :full_isolation

  alias Anvil.{Queue, Schema}
  alias Anvil.Schema.Field

  setup do
    schema =
      Schema.new(
        name: "test_schema",
        fields: [
          %Field{name: "category", type: :select, required: true, options: ["a", "b", "c"]}
        ]
      )

    {:ok, queue} =
      Queue.start_link(
        queue_id: "test_queue_#{:rand.uniform(1_000_000)}",
        schema: schema
      )

    %{queue: queue, schema: schema}
  end

  describe "add_samples/2" do
    test "adds samples to the queue", %{queue: queue} do
      samples = [
        %{id: "s1", data: "sample 1"},
        %{id: "s2", data: "sample 2"}
      ]

      assert :ok = Queue.add_samples(queue, samples)
    end
  end

  describe "add_labelers/2" do
    test "adds labelers to the queue", %{queue: queue} do
      labelers = ["labeler1", "labeler2", "labeler3"]
      assert :ok = Queue.add_labelers(queue, labelers)
    end
  end

  describe "get_next_assignment/2" do
    test "returns assignment for labeler", %{queue: queue} do
      samples = [%{id: "s1", data: "sample 1"}]
      Queue.add_samples(queue, samples)
      Queue.add_labelers(queue, ["labeler1"])

      assert {:ok, assignment} = Queue.get_next_assignment(queue, "labeler1")
      assert assignment.sample_id == "s1"
      assert assignment.labeler_id == "labeler1"
      assert assignment.status == :pending
    end

    test "returns error when no samples available", %{queue: queue} do
      Queue.add_labelers(queue, ["labeler1"])

      assert {:error, :no_samples_available} = Queue.get_next_assignment(queue, "labeler1")
    end

    test "does not assign same sample to same labeler twice", %{queue: queue} do
      samples = [%{id: "s1", data: "sample 1"}]
      Queue.add_samples(queue, samples)
      Queue.add_labelers(queue, ["labeler1"])

      {:ok, _assignment1} = Queue.get_next_assignment(queue, "labeler1")
      assert {:error, :no_samples_available} = Queue.get_next_assignment(queue, "labeler1")
    end

    test "assigns samples according to availability", %{schema: schema} do
      # With multiple labelers and samples, assignments are distributed
      {:ok, queue} =
        Queue.start_link(
          queue_id: "rr_test_#{:rand.uniform(1_000_000)}",
          schema: schema,
          labels_per_sample: 2
        )

      samples = [
        %{id: "s1", data: "sample 1"},
        %{id: "s2", data: "sample 2"}
      ]

      Queue.add_samples(queue, samples)
      Queue.add_labelers(queue, ["labeler1", "labeler2"])

      {:ok, a1} = Queue.get_next_assignment(queue, "labeler1")
      {:ok, a2} = Queue.get_next_assignment(queue, "labeler2")

      # Both labelers can get assignments
      assert a1.sample_id in ["s1", "s2"]
      assert a2.sample_id in ["s1", "s2"]
    end
  end

  describe "start_assignment/2" do
    test "transitions assignment to in_progress", %{queue: queue} do
      samples = [%{id: "s1", data: "sample 1"}]
      Queue.add_samples(queue, samples)
      Queue.add_labelers(queue, ["labeler1"])

      {:ok, assignment} = Queue.get_next_assignment(queue, "labeler1")
      assert assignment.status == :pending

      {:ok, started} = Queue.start_assignment(queue, assignment.id)
      assert started.status == :in_progress
      assert started.started_at
      assert started.deadline
    end
  end

  describe "submit_label/3" do
    test "submits valid label and completes assignment", %{queue: queue} do
      samples = [%{id: "s1", data: "sample 1"}]
      Queue.add_samples(queue, samples)
      Queue.add_labelers(queue, ["labeler1"])

      {:ok, assignment} = Queue.get_next_assignment(queue, "labeler1")
      {:ok, assignment} = Queue.start_assignment(queue, assignment.id)

      values = %{"category" => "a"}
      {:ok, label} = Queue.submit_label(queue, assignment.id, values)

      assert label.values == values
      assert label.valid? == true
      assert label.assignment_id == assignment.id
    end

    test "rejects invalid label", %{queue: queue} do
      samples = [%{id: "s1", data: "sample 1"}]
      Queue.add_samples(queue, samples)
      Queue.add_labelers(queue, ["labeler1"])

      {:ok, assignment} = Queue.get_next_assignment(queue, "labeler1")
      {:ok, assignment} = Queue.start_assignment(queue, assignment.id)

      values = %{"category" => "invalid"}

      assert {:error, {:validation_failed, _errors}} =
               Queue.submit_label(queue, assignment.id, values)
    end
  end

  describe "skip_assignment/3" do
    test "skips assignment with reason", %{queue: queue} do
      samples = [%{id: "s1", data: "sample 1"}]
      Queue.add_samples(queue, samples)
      Queue.add_labelers(queue, ["labeler1"])

      {:ok, assignment} = Queue.get_next_assignment(queue, "labeler1")
      {:ok, assignment} = Queue.start_assignment(queue, assignment.id)

      {:ok, skipped} = Queue.skip_assignment(queue, assignment.id, reason: "unclear sample")
      assert skipped.status == :skipped
      assert skipped.skip_reason == "unclear sample"
    end
  end

  describe "get_labels/2" do
    test "returns all labels", %{queue: queue} do
      samples = [%{id: "s1", data: "sample 1"}]
      Queue.add_samples(queue, samples)
      Queue.add_labelers(queue, ["labeler1"])

      {:ok, assignment} = Queue.get_next_assignment(queue, "labeler1")
      {:ok, assignment} = Queue.start_assignment(queue, assignment.id)
      {:ok, _label} = Queue.submit_label(queue, assignment.id, %{"category" => "a"})

      labels = Queue.get_labels(queue)
      assert length(labels) == 1
    end

    test "filters labels by sample_id", %{queue: queue} do
      samples = [%{id: "s1", data: "sample 1"}, %{id: "s2", data: "sample 2"}]
      Queue.add_samples(queue, samples)
      Queue.add_labelers(queue, ["labeler1", "labeler2"])

      {:ok, a1} = Queue.get_next_assignment(queue, "labeler1")
      {:ok, a1} = Queue.start_assignment(queue, a1.id)
      {:ok, _} = Queue.submit_label(queue, a1.id, %{"category" => "a"})

      {:ok, a2} = Queue.get_next_assignment(queue, "labeler2")
      {:ok, a2} = Queue.start_assignment(queue, a2.id)
      {:ok, _} = Queue.submit_label(queue, a2.id, %{"category" => "b"})

      labels = Queue.get_labels(queue, sample_id: "s1")
      assert length(labels) == 1
      assert hd(labels).sample_id == "s1"
    end
  end

  describe "labels_per_sample configuration" do
    test "allows multiple labelers to label same sample", %{schema: schema} do
      {:ok, queue} =
        Queue.start_link(
          queue_id: "multi_label_queue_#{:rand.uniform(1_000_000)}",
          schema: schema,
          labels_per_sample: 3
        )

      samples = [%{id: "s1", data: "sample 1"}]
      Queue.add_samples(queue, samples)
      Queue.add_labelers(queue, ["l1", "l2", "l3"])

      {:ok, a1} = Queue.get_next_assignment(queue, "l1")
      {:ok, a2} = Queue.get_next_assignment(queue, "l2")
      {:ok, a3} = Queue.get_next_assignment(queue, "l3")

      assert a1.sample_id == "s1"
      assert a2.sample_id == "s1"
      assert a3.sample_id == "s1"
    end

    test "stops assigning after enough labels collected", %{schema: schema} do
      {:ok, queue} =
        Queue.start_link(
          queue_id: "limited_labels_queue_#{:rand.uniform(1_000_000)}",
          schema: schema,
          labels_per_sample: 2
        )

      samples = [%{id: "s1", data: "sample 1"}]
      Queue.add_samples(queue, samples)
      Queue.add_labelers(queue, ["l1", "l2", "l3"])

      {:ok, a1} = Queue.get_next_assignment(queue, "l1")
      {:ok, a1} = Queue.start_assignment(queue, a1.id)
      {:ok, _} = Queue.submit_label(queue, a1.id, %{"category" => "a"})

      {:ok, a2} = Queue.get_next_assignment(queue, "l2")
      {:ok, a2} = Queue.start_assignment(queue, a2.id)
      {:ok, _} = Queue.submit_label(queue, a2.id, %{"category" => "a"})

      # Third labeler should not get assignment
      assert {:error, :no_samples_available} = Queue.get_next_assignment(queue, "l3")
    end
  end
end
