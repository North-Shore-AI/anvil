defmodule Anvil.API.Router do
  @moduledoc """
  Plug router exposing `/v1` IR endpoints for assignments, labels,
  schemas, queues, samples, and datasets.
  """

  use Plug.Router

  alias Anvil.API.State
  alias Anvil.Auth.{Role, TenantContext}
  alias LabelingIR.{Dataset, Label, Sample, Schema}

  plug(:match)

  plug(Plug.Parsers,
    parsers: [:json],
    json_decoder: Jason,
    pass: ["application/json"]
  )

  plug(:dispatch)

  post "/v1/schemas" do
    with {:ok, tenant} <- require_tenant(conn),
         actor <- current_actor(conn, tenant),
         :ok <- authorize(actor, :manage_queue),
         {:ok, schema} <- decode_schema(conn.body_params, tenant),
         :ok <- TenantContext.ensure_tenant_isolation(tenant_ref(schema), tenant_ref(actor)),
         :ok <- State.put_schema(schema) do
      send_json(conn, 201, schema)
    else
      {:error, reason} -> send_error(conn, reason)
    end
  end

  get "/v1/schemas/:id" do
    tenant = tenant_header(conn)

    case State.get_schema(id, tenant) do
      {:ok, schema} -> send_json(conn, 200, schema)
      :error -> send_resp(conn, 404, "")
    end
  end

  post "/v1/queues" do
    with {:ok, tenant} <- require_tenant(conn),
         actor <- current_actor(conn, tenant),
         :ok <- authorize(actor, :manage_queue),
         %{"id" => id, "schema_id" => schema_id} = body <- conn.body_params,
         {:ok, schema} <- State.get_schema(schema_id, tenant),
         {:ok, component_module, metadata} <- queue_component(body, schema),
         queue = %{
           id: id,
           tenant_id: tenant,
           schema_id: schema_id,
           namespace: schema.namespace,
           component_module: component_module,
           metadata: metadata
         },
         :ok <- State.put_queue(queue) do
      send_json(conn, 201, queue)
    else
      {:error, :component_module_required} ->
        send_resp(conn, 422, Jason.encode!(%{error: "component_module_required"}))

      {:error, reason} ->
        send_error(conn, reason)

      _ ->
        send_error(conn, :invalid_payload)
    end
  end

  get "/v1/queues/:id" do
    tenant = tenant_header(conn)

    case State.get_queue(id, tenant) do
      {:ok, queue} ->
        stats =
          case tenant do
            nil ->
              %{}

            _ ->
              case State.queue_stats(id, tenant) do
                %{} = stat_map -> stat_map
                _ -> %{}
              end
          end

        send_json(conn, 200, Map.put(queue, :stats, stats))

      :error ->
        send_resp(conn, 404, "")
    end
  end

  post "/v1/samples" do
    with {:ok, tenant} <- require_tenant(conn),
         actor <- current_actor(conn, tenant),
         :ok <- authorize(actor, :request_assignment),
         {:ok, sample} <- decode_sample(conn.body_params, tenant),
         :ok <- TenantContext.ensure_tenant_isolation(tenant_ref(sample), tenant_ref(actor)),
         :ok <- State.put_sample(sample) do
      send_json(conn, 201, sample)
    else
      {:error, reason} -> send_error(conn, reason)
    end
  end

  get "/v1/samples/:id" do
    tenant = tenant_header(conn)

    case State.get_sample(id, tenant) do
      {:ok, sample} -> send_json(conn, 200, sample)
      :error -> send_resp(conn, 404, "")
    end
  end

  get "/v1/queues/:queue_id/assignments/next" do
    conn = fetch_query_params(conn)

    with {:ok, tenant} <- require_tenant(conn),
         actor <- current_actor(conn, tenant),
         :ok <- authorize(actor, :request_assignment),
         {:ok, assignment} <-
           State.next_assignment(queue_id, tenant, conn.params["user_id"] || "") do
      send_json(conn, 200, assignment)
    else
      {:error, :not_found} -> send_resp(conn, 404, "")
      {:error, :no_samples} -> send_resp(conn, 404, Jason.encode!(%{error: "no_samples"}))
      {:error, reason} -> send_error(conn, reason)
    end
  end

  post "/v1/labels" do
    with {:ok, tenant} <- require_tenant(conn),
         actor <- current_actor(conn, tenant),
         :ok <- authorize(actor, :submit_label),
         {:ok, label} <- decode_label(conn.body_params, tenant, actor),
         :ok <- TenantContext.ensure_tenant_isolation(tenant_ref(label), tenant_ref(actor)),
         {:ok, stored} <- State.put_label(label) do
      send_json(conn, 201, stored)
    else
      {:error, reason} -> send_error(conn, reason)
    end
  end

  get "/v1/datasets/:id" do
    tenant = tenant_header(conn)

    case State.get_dataset(id, tenant) do
      {:ok, dataset} -> send_json(conn, 200, dataset)
      :error -> send_resp(conn, 404, "")
    end
  end

  get "/v1/datasets/:id/slices/:name" do
    tenant = tenant_header(conn)

    case State.get_dataset_slice(id, name, tenant) do
      {:ok, slice} -> send_json(conn, 200, slice)
      :error -> send_resp(conn, 404, "")
    end
  end

  match _ do
    send_resp(conn, 404, "")
  end

  ## Helpers

  defp require_tenant(conn) do
    case Plug.Conn.get_req_header(conn, "x-tenant-id") do
      [tenant | _] when is_binary(tenant) and tenant != "" -> {:ok, tenant}
      _ -> {:error, :tenant_required}
    end
  end

  defp tenant_header(conn) do
    case Plug.Conn.get_req_header(conn, "x-tenant-id") do
      [tenant | _] when is_binary(tenant) and tenant != "" -> tenant
      _ -> nil
    end
  end

  defp tenant_ref(resource) do
    %{tenant_id: TenantContext.extract_tenant_id(resource)}
  end

  defp current_actor(conn, tenant) do
    %{
      id: Plug.Conn.get_req_header(conn, "x-user-id") |> List.first() || "anonymous",
      tenant_id: tenant,
      role: parse_role(Plug.Conn.get_req_header(conn, "x-user-role") |> List.first())
    }
  end

  defp parse_role(nil), do: :admin

  defp parse_role(role) when is_binary(role) do
    role_atom =
      role
      |> String.trim()
      |> String.to_atom()

    if Role.valid?(role_atom), do: role_atom, else: Role.default()
  rescue
    _ -> Role.default()
  end

  defp authorize(actor, permission) do
    if actor.role == :admin or Role.has_permission?(actor.role, permission) do
      :ok
    else
      {:error, :forbidden}
    end
  end

  defp queue_component(params, schema) do
    metadata = Map.get(params, "metadata", %{}) || %{}

    component_module =
      Map.get(params, "component_module") ||
        Map.get(metadata, "component_module") ||
        Map.get(metadata, :component_module) ||
        schema.component_module

    cond do
      is_nil(component_module) ->
        {:error, :component_module_required}

      true ->
        normalized_metadata =
          metadata
          |> Map.put_new("component_module", component_module)
          |> Map.put_new(:component_module, component_module)

        {:ok, component_module, normalized_metadata}
    end
  end

  defp decode_schema(params, tenant) do
    fields =
      params
      |> Map.get("fields", [])
      |> Enum.map(fn field ->
        %Schema.Field{
          name: field["name"],
          type: normalize_type(field["type"]),
          required: field["required"] || false,
          min: field["min"],
          max: field["max"],
          default: field["default"],
          options: field["options"],
          help: field["help"]
        }
      end)

    {:ok,
     %Schema{
       id: params["id"] || Ecto.UUID.generate(),
       tenant_id: tenant,
       namespace: Map.get(params, "namespace"),
       fields: fields,
       layout: Map.get(params, "layout"),
       component_module: Map.get(params, "component_module"),
       metadata: Map.get(params, "metadata", %{})
     }}
  end

  defp decode_sample(params, tenant) do
    with {:ok, created_at} <- parse_datetime(params["created_at"]) do
      {:ok,
       %Sample{
         id: params["id"] || Ecto.UUID.generate(),
         tenant_id: tenant,
         namespace: Map.get(params, "namespace"),
         pipeline_id: params["pipeline_id"],
         payload: Map.get(params, "payload", %{}),
         artifacts: Map.get(params, "artifacts", []),
         metadata: Map.get(params, "metadata", %{}),
         lineage_ref: Map.get(params, "lineage_ref"),
         created_at: created_at
       }}
    end
  end

  defp decode_label(params, tenant, actor) do
    with {:ok, created_at} <- parse_datetime(params["created_at"] || DateTime.utc_now()) do
      user_id = params["user_id"] || actor.id

      {:ok,
       %Label{
         id: params["id"] || Ecto.UUID.generate(),
         assignment_id: params["assignment_id"],
         sample_id: params["sample_id"],
         queue_id: params["queue_id"],
         tenant_id: tenant,
         namespace: Map.get(params, "namespace"),
         user_id: user_id,
         values: Map.get(params, "values", %{}),
         notes: Map.get(params, "notes"),
         time_spent_ms: params["time_spent_ms"] || 0,
         created_at: created_at,
         lineage_ref: Map.get(params, "lineage_ref"),
         metadata: Map.get(params, "metadata", %{})
       }}
    end
  end

  defp normalize_type(nil), do: nil
  defp normalize_type(type) when is_atom(type), do: type

  defp normalize_type(type) when is_binary(type) do
    try do
      String.to_existing_atom(type)
    rescue
      ArgumentError -> String.to_atom(type)
    end
  end

  defp parse_datetime(%DateTime{} = dt), do: {:ok, dt}

  defp parse_datetime(nil), do: {:ok, DateTime.utc_now()}

  defp parse_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, dt, _offset} -> {:ok, dt}
      _ -> {:error, :invalid_datetime}
    end
  end

  defp parse_datetime(value) do
    {:ok, value}
  end

  defp send_json(conn, status, %Dataset{} = dataset) do
    send_json(conn, status, Map.from_struct(dataset))
  end

  defp send_json(conn, status, data) do
    body = Jason.encode!(data)

    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> send_resp(status, body)
  end

  defp send_error(conn, :tenant_required),
    do: send_resp(conn, 422, Jason.encode!(%{error: "tenant_id_required"}))

  defp send_error(conn, :invalid_datetime),
    do: send_resp(conn, 422, Jason.encode!(%{error: "invalid_datetime"}))

  defp send_error(conn, :forbidden),
    do: send_resp(conn, 403, Jason.encode!(%{error: "forbidden"}))

  defp send_error(conn, _reason),
    do: send_resp(conn, 422, Jason.encode!(%{error: "invalid_payload"}))
end
