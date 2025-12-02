defmodule Anvil.Agreement do
  @moduledoc """
  Inter-rater agreement metrics for measuring labeler consistency.

  Automatically selects the appropriate metric based on the data.
  """

  alias Anvil.Agreement.{Cohen, Fleiss, Krippendorff}
  alias Anvil.Telemetry

  @doc """
  Computes agreement metric, automatically selecting the appropriate algorithm.

  ## Options

    * `:metric` - Force a specific metric (:cohen, :fleiss, :krippendorff)
    * `:field` - Field name to compute agreement for (default: uses all fields)

  """
  @spec compute([Anvil.Label.t()], keyword()) :: {:ok, float()} | {:error, term()}
  def compute(labels, opts \\ []) do
    field = Keyword.get(opts, :field)
    metric = Keyword.get(opts, :metric)

    # Wrap computation in telemetry span
    Telemetry.span_agreement_compute(
      %{
        metric: metric || :auto,
        dimension: field,
        n_raters: labels |> Enum.map(& &1.labeler_id) |> Enum.uniq() |> length()
      },
      fn ->
        computed_result =
          cond do
            metric == :cohen -> Cohen.compute(labels, opts)
            metric == :fleiss -> Fleiss.compute(labels, opts)
            metric == :krippendorff -> Krippendorff.compute(labels, opts)
            true -> auto_select(labels, opts)
          end

        # Check for low agreement score
        case computed_result do
          {:ok, score} when score < 0.6 ->
            Telemetry.emit_low_agreement_score(score, %{
              dimension: field,
              threshold: 0.6,
              metric: metric || :auto
            })

          _ ->
            :ok
        end

        {computed_result, %{}}
      end
    )
  end

  @doc """
  Computes agreement for a specific dimension/field.

  ## Examples

      iex> labels = [
      ...>   %{labeler_id: "l1", values: %{"coherence" => 4, "grounded" => 3}},
      ...>   %{labeler_id: "l2", values: %{"coherence" => 4, "grounded" => 5}}
      ...> ]
      iex> Agreement.compute_for_field(labels, "coherence")
      {:ok, 1.0}  # Perfect agreement on coherence

  """
  @spec compute_for_field([map()], String.t(), keyword()) :: {:ok, float()} | {:error, term()}
  def compute_for_field(labels, field_name, opts \\ []) do
    # Extract field values from each label, preserving sample_id
    field_labels =
      labels
      |> Enum.map(fn label ->
        value = get_in(label, [Access.key(:values, %{}), field_name])

        %{
          sample_id: label[:sample_id],
          labeler_id: label[:labeler_id],
          values: %{field_name => value}
        }
      end)
      |> Enum.reject(fn label -> is_nil(get_in(label, [:values, field_name])) end)

    if length(field_labels) < 2 do
      {:error, :insufficient_labels}
    else
      compute(field_labels, Keyword.put(opts, :field, field_name))
    end
  end

  @doc """
  Computes agreement for all dimensions in the schema.

  Returns a map with per-dimension agreement scores.

  ## Examples

      iex> labels = [...]
      iex> schema = %{fields: ["coherence", "grounded", "balance"]}
      iex> Agreement.compute_all_dimensions(labels, schema)
      %{
        coherence: {:ok, 0.72},
        grounded: {:ok, 0.85},
        balance: {:ok, 0.45}
      }

  """
  @spec compute_all_dimensions([map()], map(), keyword()) :: map()
  def compute_all_dimensions(labels, schema, opts \\ []) do
    fields = Map.get(schema, :fields, [])

    for field <- fields, into: %{} do
      {String.to_atom(field), compute_for_field(labels, field, opts)}
    end
  end

  @doc """
  Returns a comprehensive agreement summary with per-dimension breakdown.

  ## Examples

      iex> labels = [...]
      iex> schema = %{fields: ["coherence", "grounded"]}
      iex> Agreement.summary(labels, schema)
      %{
        overall: {:ok, 0.78},
        by_dimension: %{
          coherence: {:ok, 0.72},
          grounded: {:ok, 0.85}
        },
        sample_count: 50,
        labeler_count: 3
      }

  """
  @spec summary([map()], map(), keyword()) :: map()
  def summary(labels, schema, opts \\ []) do
    %{
      overall: compute(labels, opts),
      by_dimension: compute_all_dimensions(labels, schema, opts),
      sample_count: labels |> Enum.map(& &1[:assignment_id]) |> Enum.uniq() |> length(),
      labeler_count: labels |> Enum.map(& &1[:labeler_id]) |> Enum.uniq() |> length()
    }
  end

  @doc """
  Batch recomputes agreement for all samples in a queue.

  This is useful for full recalculation after schema migrations or data changes.

  ## Options

    * `:batch_size` - Number of samples to process per batch (default: 100)
    * `:metric` - Force a specific metric for all computations

  """
  @spec recompute_all(binary(), keyword()) :: {:ok, map()} | {:error, term()}
  def recompute_all(queue_id, _opts \\ []) do
    # Wrap batch recomputation in telemetry span
    Telemetry.span_agreement_batch_recompute(
      %{queue_id: queue_id},
      fn ->
        # This would need to fetch labels from storage and recompute
        # For now, return a placeholder
        computed_result = {:ok, %{queue_id: queue_id, status: :not_implemented}}
        {computed_result, %{samples_processed: 0}}
      end
    )
  end

  defp auto_select(labels, opts) do
    labelers = labels |> Enum.map(& &1.labeler_id) |> Enum.uniq()

    cond do
      length(labelers) == 2 -> Cohen.compute(labels, opts)
      length(labelers) > 2 -> Fleiss.compute(labels, opts)
      true -> {:error, :insufficient_raters}
    end
  end
end
