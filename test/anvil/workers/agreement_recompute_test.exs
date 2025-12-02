defmodule Anvil.Workers.AgreementRecomputeTest do
  use ExUnit.Case, async: false
  use Oban.Testing, repo: Anvil.Repo

  alias Anvil.Repo
  alias Anvil.Schema.{Assignment, Queue, Labeler, Label, SchemaVersion}
  alias Anvil.Workers.AgreementRecompute

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)

    # Create queue with temporary ID to satisfy foreign key constraint
    queue_id = Ecto.UUID.generate()

    # Create schema version first
    {:ok, schema_version} =
      Repo.insert(%SchemaVersion{
        queue_id: queue_id,
        version_number: 1,
        schema_definition: %{
          "type" => "object",
          "properties" => %{
            "rating" => %{"type" => "integer"}
          }
        }
      })

    # Now create the queue with the schema version
    {:ok, queue} =
      Repo.insert(%Queue{
        id: queue_id,
        name: "test_queue_#{:erlang.unique_integer([:positive])}",
        schema_version_id: schema_version.id,
        policy: %{"type" => "round_robin"}
      })

    # Create test labelers
    {:ok, labeler1} =
      Repo.insert(%Labeler{
        external_id: "labeler_1"
      })

    {:ok, labeler2} =
      Repo.insert(%Labeler{
        external_id: "labeler_2"
      })

    {:ok,
     queue_id: queue.id,
     schema_version_id: schema_version.id,
     labeler1_id: labeler1.id,
     labeler2_id: labeler2.id}
  end

  describe "perform/1" do
    test "recomputes agreement for samples with multiple labels", %{
      queue_id: queue_id,
      schema_version_id: schema_version_id,
      labeler1_id: labeler1_id,
      labeler2_id: labeler2_id
    } do
      # Create a sample with 2 labels
      sample_id = Ecto.UUID.generate()

      {:ok, assignment1} =
        Repo.insert(%Assignment{
          queue_id: queue_id,
          labeler_id: labeler1_id,
          sample_id: sample_id,
          status: :completed
        })

      {:ok, assignment2} =
        Repo.insert(%Assignment{
          queue_id: queue_id,
          labeler_id: labeler2_id,
          sample_id: sample_id,
          status: :completed
        })

      {:ok, _label1} =
        Repo.insert(%Label{
          assignment_id: assignment1.id,
          labeler_id: labeler1_id,
          schema_version_id: schema_version_id,
          payload: %{"rating" => 5},
          submitted_at: DateTime.utc_now() |> DateTime.truncate(:second)
        })

      {:ok, _label2} =
        Repo.insert(%Label{
          assignment_id: assignment2.id,
          labeler_id: labeler2_id,
          schema_version_id: schema_version_id,
          payload: %{"rating" => 5},
          submitted_at: DateTime.utc_now() |> DateTime.truncate(:second)
        })

      # Perform the job
      assert :ok = perform_job(AgreementRecompute, %{"queue_id" => queue_id})
    end

    test "processes all queues when queue_id is not specified", %{
      queue_id: queue_id,
      schema_version_id: schema_version_id,
      labeler1_id: labeler1_id,
      labeler2_id: labeler2_id
    } do
      # Create a sample with 2 labels
      sample_id = Ecto.UUID.generate()

      {:ok, assignment1} =
        Repo.insert(%Assignment{
          queue_id: queue_id,
          labeler_id: labeler1_id,
          sample_id: sample_id,
          status: :completed
        })

      {:ok, assignment2} =
        Repo.insert(%Assignment{
          queue_id: queue_id,
          labeler_id: labeler2_id,
          sample_id: sample_id,
          status: :completed
        })

      {:ok, _label1} =
        Repo.insert(%Label{
          assignment_id: assignment1.id,
          labeler_id: labeler1_id,
          schema_version_id: schema_version_id,
          payload: %{"rating" => 4},
          submitted_at: DateTime.utc_now() |> DateTime.truncate(:second)
        })

      {:ok, _label2} =
        Repo.insert(%Label{
          assignment_id: assignment2.id,
          labeler_id: labeler2_id,
          schema_version_id: schema_version_id,
          payload: %{"rating" => 4},
          submitted_at: DateTime.utc_now() |> DateTime.truncate(:second)
        })

      # Perform the job without queue_id
      assert :ok = perform_job(AgreementRecompute, %{})
    end

    test "ignores samples with only one label", %{
      queue_id: queue_id,
      schema_version_id: schema_version_id,
      labeler1_id: labeler1_id
    } do
      # Create a sample with only 1 label
      sample_id = Ecto.UUID.generate()

      {:ok, assignment} =
        Repo.insert(%Assignment{
          queue_id: queue_id,
          labeler_id: labeler1_id,
          sample_id: sample_id,
          status: :completed
        })

      {:ok, _label} =
        Repo.insert(%Label{
          assignment_id: assignment.id,
          labeler_id: labeler1_id,
          schema_version_id: schema_version_id,
          payload: %{"rating" => 3},
          submitted_at: DateTime.utc_now() |> DateTime.truncate(:second)
        })

      # Perform the job - should complete without error
      assert :ok = perform_job(AgreementRecompute, %{"queue_id" => queue_id})
    end

    test "processes samples in batches", %{
      queue_id: queue_id,
      schema_version_id: schema_version_id,
      labeler1_id: labeler1_id,
      labeler2_id: labeler2_id
    } do
      # Create 5 samples with 2 labels each
      for _ <- 1..5 do
        sample_id = Ecto.UUID.generate()

        {:ok, assignment1} =
          Repo.insert(%Assignment{
            queue_id: queue_id,
            labeler_id: labeler1_id,
            sample_id: sample_id,
            status: :completed
          })

        {:ok, assignment2} =
          Repo.insert(%Assignment{
            queue_id: queue_id,
            labeler_id: labeler2_id,
            sample_id: sample_id,
            status: :completed
          })

        {:ok, _label1} =
          Repo.insert(%Label{
            assignment_id: assignment1.id,
            labeler_id: labeler1_id,
            schema_version_id: schema_version_id,
            payload: %{"rating" => 5},
            submitted_at: DateTime.utc_now() |> DateTime.truncate(:second)
          })

        {:ok, _label2} =
          Repo.insert(%Label{
            assignment_id: assignment2.id,
            labeler_id: labeler2_id,
            schema_version_id: schema_version_id,
            payload: %{"rating" => 4},
            submitted_at: DateTime.utc_now() |> DateTime.truncate(:second)
          })
      end

      # Perform the job with small batch size
      assert :ok = perform_job(AgreementRecompute, %{"queue_id" => queue_id, "batch_size" => 2})
    end
  end

  describe "enqueue/2" do
    test "enqueues a job with queue_id" do
      queue_id = Ecto.UUID.generate()

      assert {:ok, %Oban.Job{} = job} = AgreementRecompute.enqueue(queue_id)
      assert job.args["queue_id"] == queue_id
      assert job.args["batch_size"] == 100
      assert job.queue == "agreement"
    end

    test "enqueues a job with custom batch_size" do
      queue_id = Ecto.UUID.generate()

      assert {:ok, %Oban.Job{} = job} = AgreementRecompute.enqueue(queue_id, batch_size: 50)
      assert job.args["batch_size"] == 50
    end

    test "prevents duplicate jobs within uniqueness period" do
      queue_id = Ecto.UUID.generate()

      # First enqueue
      assert {:ok, %Oban.Job{} = job1} = AgreementRecompute.enqueue(queue_id)

      # Second enqueue should return existing job or conflict
      result = AgreementRecompute.enqueue(queue_id)

      case result do
        {:ok, %Oban.Job{} = job2} ->
          # If it returns a job, it should be the same one
          assert job1.id == job2.id

        {:error, changeset} ->
          # Or it should return a uniqueness error
          assert changeset.errors[:unique] != nil
      end
    end
  end

  describe "telemetry events" do
    test "emits started and completed events", %{
      queue_id: queue_id,
      schema_version_id: schema_version_id,
      labeler1_id: labeler1_id,
      labeler2_id: labeler2_id
    } do
      # Set up telemetry handler
      test_pid = self()
      events = [:started, :completed]

      for event <- events do
        :telemetry.attach(
          "test-agreement-#{event}",
          [:anvil, :workers, :agreement_recompute, event],
          fn _event_name, measurements, metadata, _config ->
            send(test_pid, {:telemetry, event, measurements, metadata})
          end,
          nil
        )
      end

      # Create a sample with 2 labels
      sample_id = Ecto.UUID.generate()

      {:ok, assignment1} =
        Repo.insert(%Assignment{
          queue_id: queue_id,
          labeler_id: labeler1_id,
          sample_id: sample_id,
          status: :completed
        })

      {:ok, assignment2} =
        Repo.insert(%Assignment{
          queue_id: queue_id,
          labeler_id: labeler2_id,
          sample_id: sample_id,
          status: :completed
        })

      {:ok, _label1} =
        Repo.insert(%Label{
          assignment_id: assignment1.id,
          labeler_id: labeler1_id,
          schema_version_id: schema_version_id,
          payload: %{"rating" => 5},
          submitted_at: DateTime.utc_now() |> DateTime.truncate(:second)
        })

      {:ok, _label2} =
        Repo.insert(%Label{
          assignment_id: assignment2.id,
          labeler_id: labeler2_id,
          schema_version_id: schema_version_id,
          payload: %{"rating" => 5},
          submitted_at: DateTime.utc_now() |> DateTime.truncate(:second)
        })

      # Perform the job
      perform_job(AgreementRecompute, %{"queue_id" => queue_id})

      # Verify telemetry events
      assert_receive {:telemetry, :started, %{}, %{queue_id: ^queue_id}}
      assert_receive {:telemetry, :completed, %{samples_processed: _}, %{queue_id: ^queue_id}}

      # Cleanup
      for event <- events do
        :telemetry.detach("test-agreement-#{event}")
      end
    end
  end
end
