defmodule Anvil.ExportTest do
  use Supertester.ExUnitFoundation, isolation: :full_isolation

  alias Anvil.{Queue, Schema, Export}
  alias Anvil.Schema.Field

  setup do
    schema =
      Schema.new(
        name: "test_schema",
        fields: [
          %Field{name: "category", type: :select, required: true, options: ["a", "b", "c"]},
          %Field{name: "score", type: :range, required: true, min: 1, max: 5}
        ]
      )

    {:ok, queue} =
      Queue.start_link(
        queue_id: "export_test_queue_#{:rand.uniform(1_000_000)}",
        schema: schema,
        labels_per_sample: 2
      )

    # Add samples and collect labels
    samples = [
      %{id: "s1", text: "sample 1"},
      %{id: "s2", text: "sample 2"}
    ]

    Queue.add_samples(queue, samples)
    Queue.add_labelers(queue, ["l1", "l2"])

    {:ok, a1} = Queue.get_next_assignment(queue, "l1")
    {:ok, a1} = Queue.start_assignment(queue, a1.id)
    {:ok, _} = Queue.submit_label(queue, a1.id, %{"category" => "a", "score" => 4})

    {:ok, a2} = Queue.get_next_assignment(queue, "l2")
    {:ok, a2} = Queue.start_assignment(queue, a2.id)
    {:ok, _} = Queue.submit_label(queue, a2.id, %{"category" => "b", "score" => 3})

    %{queue: queue, schema: schema}
  end

  describe "CSV export" do
    test "exports labels to CSV", %{queue: queue} do
      path = "/tmp/anvil_test_export_#{:rand.uniform(1_000_000)}.csv"

      assert :ok = Export.export(queue, format: :csv, path: path)
      assert File.exists?(path)

      content = File.read!(path)
      lines = String.split(content, "\n", trim: true)

      # Header + 2 labels
      assert length(lines) == 3

      # Check header
      header = hd(lines)
      assert header =~ "sample_id"
      assert header =~ "labeler_id"
      assert header =~ "category"
      assert header =~ "score"

      # Cleanup
      File.rm(path)
    end

    test "includes metadata when requested", %{queue: queue} do
      path = "/tmp/anvil_test_export_#{:rand.uniform(1_000_000)}.csv"

      assert :ok =
               Export.export(queue, format: :csv, path: path, include_metadata: true)

      content = File.read!(path)
      header = content |> String.split("\n") |> hd()

      assert header =~ "labeling_time_seconds"
      assert header =~ "created_at"
      assert header =~ "valid"

      File.rm(path)
    end

    test "filters labels when filter provided", %{queue: queue} do
      path = "/tmp/anvil_test_export_#{:rand.uniform(1_000_000)}.csv"

      assert :ok =
               Export.export(queue,
                 format: :csv,
                 path: path,
                 filter: fn label -> label.values["category"] == "a" end
               )

      content = File.read!(path)
      lines = String.split(content, "\n", trim: true)

      # Header + 1 filtered label
      assert length(lines) == 2

      File.rm(path)
    end
  end

  describe "JSONL export" do
    test "exports labels to JSONL", %{queue: queue} do
      path = "/tmp/anvil_test_export_#{:rand.uniform(1_000_000)}.jsonl"

      assert :ok = Export.export(queue, format: :jsonl, path: path)
      assert File.exists?(path)

      content = File.read!(path)
      lines = String.split(content, "\n", trim: true)

      # 2 labels
      assert length(lines) == 2

      # Parse first line
      first = Jason.decode!(hd(lines))
      assert Map.has_key?(first, "sample_id")
      assert Map.has_key?(first, "labeler_id")
      assert Map.has_key?(first, "values")

      File.rm(path)
    end

    test "includes metadata in JSONL", %{queue: queue} do
      path = "/tmp/anvil_test_export_#{:rand.uniform(1_000_000)}.jsonl"

      assert :ok =
               Export.export(queue, format: :jsonl, path: path, include_metadata: true)

      content = File.read!(path)
      first_line = hd(String.split(content, "\n", trim: true))
      data = Jason.decode!(first_line)

      assert Map.has_key?(data, "labeling_time_seconds")
      assert Map.has_key?(data, "created_at")
      assert Map.has_key?(data, "valid")

      File.rm(path)
    end
  end

  describe "error handling" do
    test "returns error for unsupported format", %{queue: queue} do
      assert {:error, {:unsupported_format, :xml}} =
               Export.export(queue, format: :xml, path: "/tmp/test.xml")
    end
  end
end
