defmodule Anvil.API.State do
  @moduledoc """
  Repo-backed persistence for the `/v1` IR API.

  Uses dedicated tables to store the LabelingIR structs while enforcing
  tenant scoping.
  """

  alias Anvil.API.{
    AssignmentRecord,
    DatasetRecord,
    LabelRecord,
    QueueRecord,
    SampleRecord,
    SchemaRecord
  }

  alias Anvil.Repo
  alias LabelingIR.{Assignment, Dataset, Label, Sample, Schema}

  import Ecto.Query

  @spec reset!() :: :ok
  def reset! do
    Repo.transaction(fn ->
      Repo.delete_all(LabelRecord)
      Repo.delete_all(AssignmentRecord)
      Repo.delete_all(SampleRecord)
      Repo.delete_all(DatasetRecord)
      Repo.delete_all(QueueRecord)
      Repo.delete_all(SchemaRecord)
    end)

    :ok
  end

  @spec put_schema(Schema.t()) :: :ok | {:error, term()}
  def put_schema(%Schema{} = schema) do
    attrs = %{
      id: schema.id,
      tenant_id: schema.tenant_id,
      namespace: schema.namespace,
      fields: encode_fields(schema.fields),
      layout: schema.layout,
      component_module: schema.component_module,
      metadata: schema.metadata || %{}
    }

    %SchemaRecord{}
    |> SchemaRecord.changeset(attrs)
    |> upsert()
  end

  @spec get_schema(String.t(), String.t() | nil) :: {:ok, Schema.t()} | :error
  def get_schema(id, tenant_id \\ nil) do
    case Repo.get(SchemaRecord, id) do
      %SchemaRecord{tenant_id: ^tenant_id} = record when not is_nil(tenant_id) ->
        {:ok, decode_schema(record)}

      %SchemaRecord{} = record when is_nil(tenant_id) ->
        {:ok, decode_schema(record)}

      %SchemaRecord{} ->
        :error

      _ ->
        :error
    end
  end

  @spec put_queue(map()) :: :ok | {:error, term()}
  def put_queue(queue) do
    metadata =
      queue.metadata
      |> Map.put_new("component_module", queue.component_module)
      |> Map.put_new(:component_module, queue.component_module)

    attrs = %{
      id: queue.id,
      tenant_id: queue.tenant_id,
      schema_id: queue.schema_id,
      namespace: queue.namespace,
      component_module: queue.component_module,
      metadata: metadata
    }

    %QueueRecord{}
    |> QueueRecord.changeset(attrs)
    |> upsert()
  end

  @spec get_queue(String.t(), String.t() | nil) :: {:ok, map()} | :error
  def get_queue(id, tenant_id \\ nil) do
    case Repo.get(QueueRecord, id) do
      %QueueRecord{tenant_id: ^tenant_id} = record when not is_nil(tenant_id) ->
        {:ok, decode_queue(record)}

      %QueueRecord{} = record when is_nil(tenant_id) ->
        {:ok, decode_queue(record)}

      %QueueRecord{} ->
        :error

      _ ->
        :error
    end
  end

  @spec put_sample(Sample.t()) :: :ok | {:error, term()}
  def put_sample(%Sample{} = sample) do
    attrs = %{
      id: sample.id,
      tenant_id: sample.tenant_id,
      namespace: sample.namespace,
      pipeline_id: sample.pipeline_id,
      payload: sample.payload,
      artifacts: sample.artifacts || [],
      metadata: sample.metadata || %{},
      lineage_ref: sample.lineage_ref,
      created_at: sample.created_at |> normalize_datetime()
    }

    %SampleRecord{}
    |> SampleRecord.changeset(attrs)
    |> upsert()
  end

  @spec get_sample(String.t(), String.t() | nil) :: {:ok, Sample.t()} | :error
  def get_sample(id, tenant_id \\ nil) do
    case Repo.get(SampleRecord, id) do
      %SampleRecord{tenant_id: ^tenant_id} = record when not is_nil(tenant_id) ->
        {:ok, decode_sample(record)}

      %SampleRecord{} = record when is_nil(tenant_id) ->
        {:ok, decode_sample(record)}

      %SampleRecord{} ->
        :error

      _ ->
        :error
    end
  end

  @spec put_assignment(Assignment.t()) :: :ok | {:error, term()}
  def put_assignment(%Assignment{} = assignment) do
    :ok = put_schema(assignment.schema)
    :ok = put_sample(assignment.sample)
    :ok = ensure_queue_for_assignment(assignment)

    attrs = %{
      id: assignment.id,
      queue_id: assignment.queue_id,
      schema_id: assignment.schema.id,
      sample_id: assignment.sample.id,
      tenant_id: assignment.tenant_id,
      namespace: assignment.namespace || assignment.sample.namespace,
      expires_at: assignment.expires_at && normalize_datetime(assignment.expires_at),
      metadata: assignment.metadata || %{}
    }

    %AssignmentRecord{}
    |> AssignmentRecord.changeset(attrs)
    |> upsert()
  end

  @spec next_assignment(String.t(), String.t(), String.t()) ::
          {:ok, Assignment.t()} | {:error, :not_found | :no_samples}
  def next_assignment(queue_id, tenant_id, _user_id) do
    with {:ok, queue} <- get_queue(queue_id, tenant_id),
         {:ok, schema} <- get_schema(queue.schema_id, tenant_id),
         {:ok, sample} <- pick_sample(queue, tenant_id) do
      component_module =
        queue.component_module ||
          schema.component_module ||
          get_in(queue.metadata, ["component_module"]) ||
          get_in(queue.metadata, [:component_module])

      metadata =
        queue.metadata
        |> Map.put_new("component_module", component_module)
        |> Map.put_new(:component_module, component_module)

      assignment = %Assignment{
        id: Ecto.UUID.generate(),
        queue_id: queue_id,
        tenant_id: tenant_id,
        namespace: sample.namespace || schema.namespace,
        sample: sample,
        schema: schema,
        existing_labels: [],
        metadata: metadata
      }

      :ok = put_assignment(assignment)
      {:ok, assignment}
    else
      {:error, reason} -> {:error, reason}
      :error -> {:error, :not_found}
    end
  end

  @spec put_label(Label.t()) :: {:ok, Label.t()} | {:error, term()}
  def put_label(%Label{} = label) do
    with {:ok, assignment} <-
           Repo.get(AssignmentRecord, label.assignment_id) |> ensure_tenant(label.tenant_id),
         {:ok, _} <- get_queue(label.queue_id, label.tenant_id),
         {:ok, _} <- get_sample(label.sample_id, label.tenant_id) do
      attrs = %{
        id: label.id || Ecto.UUID.generate(),
        assignment_id: assignment.id,
        queue_id: label.queue_id,
        sample_id: label.sample_id,
        tenant_id: label.tenant_id,
        namespace: label.namespace,
        user_id: label.user_id,
        values: label.values || %{},
        notes: label.notes,
        time_spent_ms: label.time_spent_ms || 0,
        lineage_ref: label.lineage_ref,
        metadata: label.metadata || %{},
        created_at: normalize_datetime(label.created_at)
      }

      %LabelRecord{}
      |> LabelRecord.changeset(attrs)
      |> upsert()
      |> case do
        :ok -> {:ok, %{label | id: attrs.id}}
        {:error, reason} -> {:error, reason}
      end
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :not_found}
    end
  end

  @spec put_dataset(Dataset.t()) :: :ok | {:error, term()}
  def put_dataset(%Dataset{} = dataset) do
    attrs = %{
      id: dataset.id,
      tenant_id: dataset.tenant_id,
      namespace: dataset.namespace,
      version: dataset.version,
      slices: dataset.slices || [],
      source_refs: dataset.source_refs || [],
      metadata: dataset.metadata || %{},
      lineage_ref: dataset.lineage_ref,
      created_at: normalize_datetime(dataset.created_at)
    }

    %DatasetRecord{}
    |> DatasetRecord.changeset(attrs)
    |> upsert()
  end

  @spec get_dataset(String.t(), String.t() | nil) :: {:ok, Dataset.t()} | :error
  def get_dataset(id, tenant_id \\ nil) do
    case Repo.get(DatasetRecord, id) do
      %DatasetRecord{tenant_id: ^tenant_id} = record when not is_nil(tenant_id) ->
        {:ok, decode_dataset(record)}

      %DatasetRecord{} = record when is_nil(tenant_id) ->
        {:ok, decode_dataset(record)}

      %DatasetRecord{} ->
        :error

      _ ->
        :error
    end
  end

  @spec get_dataset_slice(String.t(), String.t(), String.t() | nil) :: {:ok, map()} | :error
  def get_dataset_slice(id, slice_name, tenant_id \\ nil) do
    with {:ok, dataset} <- get_dataset(id, tenant_id),
         %{} = slice <- Enum.find(dataset.slices, &match_slice?(&1, slice_name)) do
      {:ok, slice}
    else
      _ -> :error
    end
  end

  @spec queue_stats(String.t(), String.t()) :: map() | :error
  def queue_stats(queue_id, tenant_id) do
    with {:ok, _queue} <- get_queue(queue_id, tenant_id) do
      total_assignments =
        from(a in AssignmentRecord, where: a.queue_id == ^queue_id and a.tenant_id == ^tenant_id)
        |> Repo.aggregate(:count, :id)

      total_labels =
        from(l in LabelRecord, where: l.queue_id == ^queue_id and l.tenant_id == ^tenant_id)
        |> Repo.aggregate(:count, :id)

      %{
        total_assignments: total_assignments,
        labeled: total_labels,
        remaining: max(total_assignments - total_labels, 0)
      }
    else
      _ -> :error
    end
  end

  ## Helpers

  defp pick_sample(queue, tenant_id) do
    query =
      from(s in SampleRecord,
        where: s.tenant_id == ^tenant_id,
        order_by: [asc: s.inserted_at],
        limit: 1
      )

    query =
      if queue.namespace do
        from(s in query, where: is_nil(s.namespace) or s.namespace == ^queue.namespace)
      else
        query
      end

    case Repo.one(query) do
      nil -> {:error, :no_samples}
      %SampleRecord{} = record -> {:ok, decode_sample(record)}
    end
  end

  defp decode_schema(%SchemaRecord{} = record) do
    %Schema{
      id: record.id,
      tenant_id: record.tenant_id,
      namespace: record.namespace,
      fields: decode_fields(record.fields || []),
      layout: record.layout,
      component_module: record.component_module,
      metadata: record.metadata || %{}
    }
  end

  defp decode_queue(%QueueRecord{} = record) do
    %{
      id: record.id,
      tenant_id: record.tenant_id,
      schema_id: record.schema_id,
      namespace: record.namespace,
      component_module: record.component_module,
      metadata: record.metadata || %{}
    }
  end

  defp decode_sample(%SampleRecord{} = record) do
    %Sample{
      id: record.id,
      tenant_id: record.tenant_id,
      namespace: record.namespace,
      pipeline_id: record.pipeline_id,
      payload: record.payload || %{},
      artifacts: record.artifacts || [],
      metadata: record.metadata || %{},
      lineage_ref: record.lineage_ref,
      created_at: record.created_at
    }
  end

  defp decode_dataset(%DatasetRecord{} = record) do
    %Dataset{
      id: record.id,
      tenant_id: record.tenant_id,
      namespace: record.namespace,
      version: record.version,
      slices: record.slices || [],
      source_refs: record.source_refs || [],
      metadata: record.metadata || %{},
      lineage_ref: record.lineage_ref,
      created_at: record.created_at
    }
  end

  defp encode_fields(fields) when is_list(fields) do
    Enum.map(fields, &Map.from_struct/1)
  end

  defp decode_fields(fields) do
    Enum.map(fields, fn field ->
      attrs =
        field
        |> normalize_keys()
        |> Map.take([:name, :type, :required, :min, :max, :default, :options, :help])

      struct(LabelingIR.Schema.Field, attrs)
    end)
  end

  defp normalize_keys(map) when is_map(map) do
    Map.new(map, fn {k, v} -> {normalize_key(k), v} end)
  end

  defp normalize_key(k) when is_atom(k), do: k
  defp normalize_key(k) when is_binary(k), do: String.to_atom(k)

  defp upsert(changeset) do
    case Repo.insert(changeset,
           on_conflict: {:replace_all_except, [:id, :inserted_at]},
           conflict_target: :id
         ) do
      {:ok, _record} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp normalize_datetime(%DateTime{} = dt), do: DateTime.truncate(dt, :second)
  defp normalize_datetime(%NaiveDateTime{} = ndt), do: ndt
  defp normalize_datetime(nil), do: nil
  defp normalize_datetime(other), do: other

  defp match_slice?(slice, name) do
    Map.get(slice, :name) == name || Map.get(slice, "name") == name
  end

  defp ensure_tenant(%{tenant_id: tenant_id} = resource, tenant_id), do: {:ok, resource}
  defp ensure_tenant(_, _), do: {:error, :tenant_mismatch}

  defp ensure_queue_for_assignment(%Assignment{} = assignment) do
    case get_queue(assignment.queue_id, assignment.tenant_id) do
      {:ok, _queue} ->
        :ok

      :error ->
        component_module =
          get_in(assignment.metadata, ["component_module"]) ||
            get_in(assignment.metadata, [:component_module]) ||
            assignment.schema.component_module ||
            "Ingot.Components.DefaultComponent"

        attrs = %{
          id: assignment.queue_id,
          tenant_id: assignment.tenant_id,
          schema_id: assignment.schema.id,
          namespace: assignment.namespace || assignment.sample.namespace,
          component_module: component_module,
          metadata: %{"component_module" => component_module}
        }

        put_queue(attrs)
    end
  end
end
