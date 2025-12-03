defmodule Anvil.API.V1RouterTest do
  use Supertester.ExUnitFoundation, isolation: :full_isolation
  import Plug.Test
  import Plug.Conn

  alias Anvil.API.Router
  alias Anvil.API.State
  alias LabelingIR.{Assignment, Dataset, Sample, Schema}

  @opts Router.init([])

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Anvil.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Anvil.Repo, {:shared, self()})
    :ok
  end

  test "creates schema/queue/sample and serves AssignmentIR over /v1" do
    uniq = System.unique_integer([:positive])

    schema_body = %{
      "id" => "schema_news_#{uniq}",
      "tenant_id" => "tenant_acme",
      "namespace" => "news",
      "fields" => [
        %{"name" => "quality", "type" => "scale", "min" => 1, "max" => 5, "required" => true}
      ],
      "component_module" => "Acme.NewsComponent",
      "metadata" => %{"layout" => "simple"}
    }

    conn =
      conn(:post, "/v1/schemas", Jason.encode!(schema_body))
      |> put_req_header("content-type", "application/json")
      |> put_req_header("x-tenant-id", "tenant_acme")
      |> Router.call(@opts)

    assert conn.status == 201
    schema_id = schema_body["id"]
    assert %{"id" => ^schema_id} = Jason.decode!(conn.resp_body)

    queue_body = %{
      "id" => "queue_news_#{uniq}",
      "tenant_id" => "tenant_acme",
      "schema_id" => schema_id,
      "component_module" => "Acme.NewsComponent",
      "metadata" => %{"priority" => "normal"}
    }

    conn =
      conn(:post, "/v1/queues", Jason.encode!(queue_body))
      |> put_req_header("content-type", "application/json")
      |> put_req_header("x-tenant-id", "tenant_acme")
      |> Router.call(@opts)

    assert conn.status == 201

    sample_body = %{
      "id" => "sample-#{uniq}",
      "tenant_id" => "tenant_acme",
      "namespace" => "news",
      "pipeline_id" => "pipe1",
      "payload" => %{"headline" => "Hello"},
      "artifacts" => [],
      "metadata" => %{},
      "lineage_ref" => %{"trace" => "s1"},
      "created_at" => "2025-01-01T00:00:00Z"
    }

    conn =
      conn(:post, "/v1/samples", Jason.encode!(sample_body))
      |> put_req_header("content-type", "application/json")
      |> put_req_header("x-tenant-id", "tenant_acme")
      |> Router.call(@opts)

    assert conn.status == 201
    sample_id = sample_body["id"]

    conn =
      conn(:get, "/v1/queues/#{queue_body["id"]}/assignments/next?user_id=user-1")
      |> put_req_header("x-tenant-id", "tenant_acme")
      |> Router.call(@opts)

    assert conn.status == 200
    body = Jason.decode!(conn.resp_body)
    assert body["tenant_id"] == "tenant_acme"
    assert body["queue_id"] == queue_body["id"]
    assert body["namespace"] == "news"
    assert %{"id" => ^sample_id, "lineage_ref" => %{"trace" => "s1"}} = body["sample"]
    assert %{"id" => ^schema_id, "component_module" => "Acme.NewsComponent"} = body["schema"]
    assert get_in(body, ["metadata", "component_module"]) == "Acme.NewsComponent"
  end

  test "accepts LabelIR writes and returns stored label" do
    uniq = System.unique_integer([:positive])

    # Seed store with assignment so the label endpoint can validate references
    sample = %Sample{
      id: "sample-#{uniq}",
      tenant_id: "tenant_acme",
      namespace: "news",
      pipeline_id: "pipe2",
      payload: %{},
      artifacts: [],
      metadata: %{},
      lineage_ref: %{trace: "s2"},
      created_at: ~U[2025-01-02 00:00:00Z]
    }

    schema = %Schema{
      id: "schema_label_#{uniq}",
      tenant_id: "tenant_acme",
      namespace: "news",
      fields: [%Schema.Field{name: "judgment", type: :text}],
      metadata: %{}
    }

    assignment = %Assignment{
      id: "asst-#{uniq}",
      queue_id: "queue_news_#{uniq}",
      tenant_id: "tenant_acme",
      namespace: "news",
      sample: sample,
      schema: schema,
      existing_labels: [],
      metadata: %{"component_module" => "Acme.NewsComponent"}
    }

    State.put_assignment(assignment)

    label_body = %{
      "assignment_id" => assignment.id,
      "queue_id" => assignment.queue_id,
      "sample_id" => sample.id,
      "tenant_id" => "tenant_acme",
      "namespace" => "news",
      "user_id" => "user-7",
      "values" => %{"judgment" => "looks good"},
      "notes" => "ok",
      "time_spent_ms" => 1200,
      "lineage_ref" => %{"trace" => "lbl-1"},
      "metadata" => %{"source" => "ui"}
    }

    conn =
      conn(:post, "/v1/labels", Jason.encode!(label_body))
      |> put_req_header("content-type", "application/json")
      |> put_req_header("x-tenant-id", "tenant_acme")
      |> Router.call(@opts)

    assert conn.status == 201
    resp = Jason.decode!(conn.resp_body)
    assert resp["id"]
    assert resp["tenant_id"] == "tenant_acme"
    assert resp["lineage_ref"] == %{"trace" => "lbl-1"}
  end

  test "tolerates unknown fields on label payload for compatibility" do
    uniq = System.unique_integer([:positive])

    assignment = %Assignment{
      id: "compat-asst-#{uniq}",
      queue_id: "queue_news_#{uniq}",
      tenant_id: "tenant_acme",
      sample: %Sample{
        id: "compat-sample-#{uniq}",
        tenant_id: "tenant_acme",
        pipeline_id: "pipe3",
        payload: %{},
        artifacts: [],
        metadata: %{},
        created_at: DateTime.utc_now()
      },
      schema: %Schema{
        id: "schema-compat-#{uniq}",
        tenant_id: "tenant_acme",
        fields: [%Schema.Field{name: "score", type: :scale}]
      },
      existing_labels: [],
      metadata: %{}
    }

    State.put_assignment(assignment)

    label_body = %{
      "assignment_id" => assignment.id,
      "queue_id" => assignment.queue_id,
      "sample_id" => assignment.sample.id,
      "tenant_id" => "tenant_acme",
      "user_id" => "user-compat",
      "values" => %{"score" => 5},
      "time_spent_ms" => 100,
      "unknown_key" => "ignore me"
    }

    conn =
      conn(:post, "/v1/labels", Jason.encode!(label_body))
      |> put_req_header("content-type", "application/json")
      |> put_req_header("x-tenant-id", "tenant_acme")
      |> Router.call(@opts)

    assert conn.status == 201
    body = Jason.decode!(conn.resp_body)
    refute Map.has_key?(body, "unknown_key")
  end

  test "serves DatasetIR slices by id" do
    uniq = System.unique_integer([:positive])

    dataset = %Dataset{
      id: "ds#{uniq}",
      tenant_id: "tenant_acme",
      namespace: "news",
      version: "v1",
      slices: [%{name: "validation", sample_ids: ["sample-#{uniq}"], filter: %{}}],
      source_refs: [],
      metadata: %{},
      lineage_ref: %{trace: "ds-trace"},
      created_at: ~U[2025-01-03 00:00:00Z]
    }

    State.put_dataset(dataset)

    conn =
      conn(:get, "/v1/datasets/#{dataset.id}")
      |> put_req_header("x-tenant-id", "tenant_acme")
      |> Router.call(@opts)

    assert conn.status == 200
    body = Jason.decode!(conn.resp_body)
    assert body["id"] == dataset.id
    assert body["namespace"] == "news"
    assert [%{"name" => "validation"}] = body["slices"]
  end
end
