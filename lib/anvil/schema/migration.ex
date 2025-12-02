defmodule Anvil.Schema.Migration do
  @moduledoc """
  Forward-only migrations between schema versions.

  Provides utilities for migrating labels from one schema version to another
  using transform callbacks.
  """

  alias Anvil.Schema.{SchemaVersion, Label}
  alias Anvil.Repo

  @doc """
  Transform callback behaviour for schema migrations.

  Transform modules must implement forward/3 to convert labels from one version to another.
  """
  @callback transform(old_label :: map(), from_version :: integer(), to_version :: integer()) ::
              {:ok, new_label :: map()} | {:error, :incompatible}

  @doc """
  Migrates labels from one schema version to another.

  ## Options

    * `:batch_size` - Number of labels to process per batch (default: 100)
    * `:dry_run` - If true, only validates transformations without creating new labels
    * `:transformer` - Module implementing transform/3 callback

  ## Examples

      iex> migrate_labels(labels, 1, 2, MyApp.Transforms.V1ToV2)
      {:ok, %{migrated: 150, failed: 0}}

      iex> migrate_labels(labels, 1, 2, MyApp.Transforms.V1ToV2, dry_run: true)
      {:ok, %{valid: 150, invalid: 0}}

  """
  @spec migrate_labels(
          [Label.t()],
          non_neg_integer(),
          non_neg_integer(),
          module(),
          keyword()
        ) ::
          {:ok, map()} | {:error, term()}
  def migrate_labels(labels, from_version, to_version, transformer, opts \\ []) do
    dry_run = Keyword.get(opts, :dry_run, false)
    batch_size = Keyword.get(opts, :batch_size, 100)

    results =
      labels
      |> Stream.chunk_every(batch_size)
      |> Enum.reduce(%{migrated: 0, failed: 0, errors: []}, fn batch, acc ->
        batch_results = process_batch(batch, from_version, to_version, transformer, dry_run)
        merge_results(acc, batch_results)
      end)

    {:ok, results}
  end

  defp process_batch(batch, from_version, to_version, transformer, dry_run) do
    Enum.reduce(batch, %{migrated: 0, failed: 0, errors: []}, fn label, acc ->
      case transformer.transform(label.payload, from_version, to_version) do
        {:ok, new_payload} ->
          if dry_run do
            %{acc | migrated: acc.migrated + 1}
          else
            case create_migrated_label(label, new_payload, to_version) do
              {:ok, _new_label} ->
                %{acc | migrated: acc.migrated + 1}

              {:error, reason} ->
                %{
                  acc
                  | failed: acc.failed + 1,
                    errors: [{label.id, reason} | acc.errors]
                }
            end
          end

        {:error, :incompatible} ->
          %{
            acc
            | failed: acc.failed + 1,
              errors: [{label.id, :incompatible_schema} | acc.errors]
          }
      end
    end)
  end

  defp create_migrated_label(old_label, new_payload, to_version) do
    # Find the target schema version
    case Repo.get_by(SchemaVersion,
           queue_id: get_queue_id(old_label),
           version_number: to_version
         ) do
      nil ->
        {:error, :schema_version_not_found}

      schema_version ->
        new_label = %Label{
          assignment_id: old_label.assignment_id,
          labeler_id: old_label.labeler_id,
          schema_version_id: schema_version.id,
          payload: new_payload,
          submitted_at: old_label.submitted_at
        }

        Repo.insert(new_label)
    end
  end

  defp get_queue_id(label) do
    # This would need to fetch the queue_id from the assignment
    # For now, we'll need to preload this relationship
    case label do
      %{assignment: %{queue_id: queue_id}} -> queue_id
      _ -> nil
    end
  end

  defp merge_results(acc, batch_results) do
    %{
      migrated: acc.migrated + batch_results.migrated,
      failed: acc.failed + batch_results.failed,
      errors: acc.errors ++ batch_results.errors
    }
  end

  @doc """
  Validates that a label payload conforms to a schema version.

  Returns {:ok, payload} if valid, {:error, errors} if invalid.
  """
  @spec validate_against_schema(map(), SchemaVersion.t()) ::
          {:ok, map()} | {:error, [term()]}
  def validate_against_schema(label_values, schema_version) do
    # Simple validation - check that all required fields are present
    # In a real implementation, this would use the schema_definition
    # to perform comprehensive validation

    case schema_version.schema_definition do
      %{"required" => required_fields} ->
        missing_fields =
          required_fields
          |> Enum.reject(&Map.has_key?(label_values, &1))

        if Enum.empty?(missing_fields) do
          {:ok, label_values}
        else
          {:error, [{:required_fields_missing, missing_fields}]}
        end

      _ ->
        # No required fields specified, accept payload
        {:ok, label_values}
    end
  end

  @doc """
  Freezes a schema version when the first label is submitted.

  This is typically called automatically via a database trigger or
  application hook.
  """
  @spec freeze_schema_version(binary()) :: {:ok, SchemaVersion.t()} | {:error, term()}
  def freeze_schema_version(schema_version_id) do
    case Repo.get(SchemaVersion, schema_version_id) do
      nil ->
        {:error, :not_found}

      schema_version ->
        if schema_version.frozen_at do
          {:ok, schema_version}
        else
          schema_version
          |> SchemaVersion.freeze()
          |> Repo.update()
        end
    end
  end
end
