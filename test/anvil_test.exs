defmodule AnvilTest do
  use Supertester.ExUnitFoundation, isolation: :full_isolation

  alias Anvil.{Schema, Queue}
  alias Anvil.Schema.Field

  describe "end-to-end workflow" do
    test "complete labeling workflow" do
      # 1. Define schema
      schema =
        Schema.new(
          name: "sentiment",
          fields: [
            %Field{
              name: "sentiment",
              type: :select,
              required: true,
              options: ["positive", "negative", "neutral"]
            },
            %Field{
              name: "confidence",
              type: :range,
              required: true,
              min: 1,
              max: 5
            }
          ]
        )

      # 2. Create queue
      {:ok, queue} =
        Anvil.create_queue(
          queue_id: "e2e_test_#{:rand.uniform(1_000_000)}",
          schema: schema,
          labels_per_sample: 2
        )

      # 3. Add samples
      samples = [
        %{id: "s1", text: "This is great!"},
        %{id: "s2", text: "Terrible experience."}
      ]

      assert :ok = Anvil.add_samples(queue, samples)

      # 4. Add labelers
      assert :ok = Anvil.add_labelers(queue, ["labeler1", "labeler2"])

      # 5. Get assignments
      {:ok, a1} = Anvil.get_next_assignment(queue, "labeler1")
      {:ok, a2} = Anvil.get_next_assignment(queue, "labeler2")

      assert a1.sample_id == "s1"
      assert a2.sample_id == "s1"

      # 6. Start assignments
      {:ok, a1} = Queue.start_assignment(queue, a1.id)
      {:ok, a2} = Queue.start_assignment(queue, a2.id)

      # 7. Submit labels
      {:ok, label1} =
        Anvil.submit_label(queue, a1.id, %{"sentiment" => "positive", "confidence" => 5})

      {:ok, label2} =
        Anvil.submit_label(queue, a2.id, %{"sentiment" => "positive", "confidence" => 4})

      assert label1.valid?
      assert label2.valid?

      # 8. Compute agreement
      {:ok, agreement} = Anvil.compute_agreement(queue)
      # Agreement should be between -1 and 1
      assert agreement >= -1.0
      assert agreement <= 1.0

      # 9. Export data
      csv_path = "/tmp/anvil_e2e_test_#{:rand.uniform(1_000_000)}.csv"
      assert :ok = Anvil.export(queue, format: :csv, path: csv_path)
      assert File.exists?(csv_path)

      jsonl_path = "/tmp/anvil_e2e_test_#{:rand.uniform(1_000_000)}.jsonl"
      assert :ok = Anvil.export(queue, format: :jsonl, path: jsonl_path)
      assert File.exists?(jsonl_path)

      # Cleanup
      File.rm(csv_path)
      File.rm(jsonl_path)
    end

    test "handles validation errors gracefully" do
      schema =
        Schema.new(
          name: "test",
          fields: [
            %Field{name: "category", type: :select, required: true, options: ["a", "b"]}
          ]
        )

      {:ok, queue} =
        Anvil.create_queue(
          queue_id: "validation_test_#{:rand.uniform(1_000_000)}",
          schema: schema
        )

      Anvil.add_samples(queue, [%{id: "s1"}])
      Anvil.add_labelers(queue, ["labeler1"])

      {:ok, assignment} = Anvil.get_next_assignment(queue, "labeler1")
      {:ok, assignment} = Queue.start_assignment(queue, assignment.id)

      # Submit invalid label
      result = Anvil.submit_label(queue, assignment.id, %{"category" => "invalid"})
      assert {:error, {:validation_failed, errors}} = result
      assert length(errors) > 0
    end
  end
end
