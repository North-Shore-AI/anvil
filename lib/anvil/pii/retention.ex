defmodule Anvil.PII.Retention do
  @moduledoc """
  Retention policy enforcement for PII fields.

  This module provides functions for identifying expired labels and applying
  retention actions (soft delete, hard delete, or field-level redaction).

  ## Retention Actions

  - `:soft_delete` - Tombstone: keep metadata, strip payload
  - `:hard_delete` - Permanent deletion (breaks reproducibility)
  - `:field_redaction` - Redact only expired fields, keep unexpired

  ## Examples

      iex> schema_def = %{
      ...>   fields: [
      ...>     %{name: "notes", pii: :possible, retention_days: 90}
      ...>   ]
      ...> }
      iex> label = %{submitted_at: ~U[2024-01-01 00:00:00Z], payload: %{"notes" => "test"}}
      iex> now = ~U[2025-01-01 00:00:00Z]
      iex> Anvil.PII.Retention.has_expired_fields?(schema_def, label, now)
      true
  """

  import Ecto.Query
  alias Anvil.Repo
  alias Anvil.Schema.{Label, SchemaVersion}

  @type retention_action :: :soft_delete | :hard_delete | :field_redaction

  @doc """
  Finds labels with expired PII fields based on retention policies.

  Returns a list of labels where at least one field has exceeded its retention period.

  ## Options

  - `:now` - Current time for expiration check (default: DateTime.utc_now())
  - `:queue_id` - Filter by specific queue
  - `:limit` - Limit number of results

  ## Examples

      iex> labels = Anvil.PII.Retention.find_expired_labels()
      [%Label{...}, ...]
  """
  @spec find_expired_labels(keyword()) :: [Label.t()]
  def find_expired_labels(opts \\ []) do
    now = Keyword.get(opts, :now, DateTime.utc_now())
    queue_id = Keyword.get(opts, :queue_id)
    limit = Keyword.get(opts, :limit)

    query =
      from(l in Label,
        join: sv in SchemaVersion,
        on: l.schema_version_id == sv.id,
        where: not is_nil(l.submitted_at),
        where: is_nil(l.deleted_at),
        select: %{
          id: l.id,
          assignment_id: l.assignment_id,
          labeler_id: l.labeler_id,
          schema_version_id: l.schema_version_id,
          payload: l.payload,
          submitted_at: l.submitted_at,
          schema_definition: sv.schema_definition
        }
      )

    query =
      if queue_id do
        from([l, sv] in query,
          where: sv.queue_id == ^queue_id
        )
      else
        query
      end

    query =
      if limit do
        from(q in query, limit: ^limit)
      else
        query
      end

    # Post-filter in application code since we need to evaluate field-level retention
    # This is less efficient but necessary for complex retention logic
    query
    |> Repo.all()
    |> Enum.filter(fn label ->
      has_expired_fields?(label.schema_definition, label, now)
    end)
    |> then(fn results ->
      # Convert back to Label structs
      Enum.map(results, fn result ->
        %Label{
          id: result.id,
          assignment_id: result.assignment_id,
          labeler_id: result.labeler_id,
          schema_version_id: result.schema_version_id,
          payload: result.payload,
          submitted_at: result.submitted_at
        }
      end)
    end)
  end

  @doc """
  Checks if a label has any expired fields based on schema definition.

  ## Examples

      iex> schema_def = %{fields: [%{name: "notes", metadata: %{retention_days: 90}}]}
      iex> label = %{submitted_at: ~U[2024-01-01 00:00:00Z], payload: %{"notes" => "test"}}
      iex> now = ~U[2025-01-01 00:00:00Z]
      iex> Anvil.PII.Retention.has_expired_fields?(schema_def, label, now)
      true
  """
  @spec has_expired_fields?(map(), map(), DateTime.t()) :: boolean()
  def has_expired_fields?(schema_definition, label, now \\ DateTime.utc_now()) do
    field_metadata_map = extract_field_metadata(schema_definition)

    Enum.any?(Map.keys(label.payload || %{}), fn field_name ->
      field_metadata = Map.get(field_metadata_map, field_name, %{})
      Anvil.PII.expired?(field_metadata, label.submitted_at, now)
    end)
  end

  @doc """
  Applies retention action to a label.

  ## Parameters

  - `label` - The label to process
  - `action` - Retention action to apply (`:soft_delete`, `:hard_delete`, `:field_redaction`)
  - `schema_definition` - Schema definition with field metadata
  - `opts` - Additional options

  ## Returns

  `{:ok, label}` on success, `{:error, reason}` on failure.
  """
  @spec apply_retention_action(Label.t(), retention_action(), map(), keyword()) ::
          {:ok, Label.t()} | {:error, term()}
  def apply_retention_action(label, action, schema_definition, opts \\ [])

  def apply_retention_action(label, :hard_delete, _schema_definition, _opts) do
    case Repo.delete(label) do
      {:ok, _deleted} -> {:ok, label}
      {:error, reason} -> {:error, reason}
    end
  end

  def apply_retention_action(label, :soft_delete, _schema_definition, _opts) do
    now = DateTime.utc_now()

    label
    |> Ecto.Changeset.change(%{
      payload: %{},
      deleted_at: now
    })
    |> Repo.update()
  end

  def apply_retention_action(label, :field_redaction, schema_definition, opts) do
    now = Keyword.get(opts, :now, DateTime.utc_now())
    field_metadata_map = extract_field_metadata(schema_definition)

    redacted_payload =
      Enum.reduce(label.payload || %{}, %{}, fn {field_name, value}, acc ->
        field_metadata = Map.get(field_metadata_map, field_name, %{})

        if Anvil.PII.expired?(field_metadata, label.submitted_at, now) do
          # Field is expired, redact it
          acc
        else
          # Field is not expired, keep it
          Map.put(acc, field_name, value)
        end
      end)

    label
    |> Ecto.Changeset.change(%{payload: redacted_payload})
    |> Repo.update()
  end

  @doc """
  Processes a batch of expired labels with the specified retention action.

  Returns `{:ok, count}` where count is the number of labels processed.

  ## Options

  - `:dry_run` - If true, only counts labels without processing (default: false)
  - `:now` - Current time for expiration check (default: DateTime.utc_now())
  - `:action` - Retention action to apply (default: `:field_redaction`)

  ## Examples

      iex> Anvil.PII.Retention.process_expired_labels(queue_id: queue_id, dry_run: true)
      {:ok, 42}

      iex> Anvil.PII.Retention.process_expired_labels(action: :soft_delete)
      {:ok, 15}
  """
  @spec process_expired_labels(keyword()) :: {:ok, non_neg_integer()} | {:error, term()}
  def process_expired_labels(opts \\ []) do
    dry_run = Keyword.get(opts, :dry_run, false)
    action = Keyword.get(opts, :action, :field_redaction)

    expired_labels = find_expired_labels(opts)

    if dry_run do
      {:ok, length(expired_labels)}
    else
      results =
        Enum.map(expired_labels, fn label ->
          # Load full label with schema version
          label_with_schema =
            Repo.get(Label, label.id)
            |> Repo.preload(schema_version: :queue)

          schema_definition = label_with_schema.schema_version.schema_definition

          apply_retention_action(label_with_schema, action, schema_definition, opts)
        end)

      # Count successes
      success_count =
        Enum.count(results, fn
          {:ok, _} -> true
          {:error, _} -> false
        end)

      {:ok, success_count}
    end
  end

  @doc """
  Extracts field metadata from schema definition.

  Returns a map of field names to metadata maps.

  ## Examples

      iex> schema_def = %{
      ...>   fields: [
      ...>     %{name: "notes", metadata: %{pii: :possible, retention_days: 90}}
      ...>   ]
      ...> }
      iex> Anvil.PII.Retention.extract_field_metadata(schema_def)
      %{"notes" => %{pii: :possible, retention_days: 90}}
  """
  @spec extract_field_metadata(map()) :: map()
  def extract_field_metadata(schema_definition) do
    fields = Map.get(schema_definition, :fields, [])

    Enum.reduce(fields, %{}, fn field, acc ->
      field_name = field_name(field)
      metadata = Map.get(field, :metadata, %{})
      Map.put(acc, field_name, metadata)
    end)
  end

  defp field_name(%{name: name}), do: name
  defp field_name(%{"name" => name}), do: name
  defp field_name(_), do: nil
end
