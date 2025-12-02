defmodule Anvil.Agreement.Cohen do
  @moduledoc """
  Cohen's kappa for measuring agreement between two raters.

  κ = (p_o - p_e) / (1 - p_e)

  where:
  - p_o = observed agreement
  - p_e = expected agreement by chance
  """

  @doc """
  Computes Cohen's kappa for two raters.

  ## Options

    * `:field` - Field name to compute agreement for (default: first field in values)

  """
  @spec compute([Anvil.Label.t()], keyword()) :: {:ok, float()} | {:error, term()}
  def compute(labels, opts \\ []) do
    labelers = labels |> Enum.map(& &1.labeler_id) |> Enum.uniq()

    if length(labelers) != 2 do
      {:error, :requires_exactly_two_raters}
    else
      field = Keyword.get(opts, :field)
      do_compute(labels, labelers, field)
    end
  end

  defp do_compute(labels, [labeler1, labeler2], field) do
    labels1 = Enum.filter(labels, &(&1.labeler_id == labeler1))
    labels2 = Enum.filter(labels, &(&1.labeler_id == labeler2))

    # Get common samples
    samples1 = MapSet.new(labels1, & &1.sample_id)
    samples2 = MapSet.new(labels2, & &1.sample_id)
    common_samples = MapSet.intersection(samples1, samples2) |> MapSet.to_list()

    if Enum.empty?(common_samples) do
      {:error, :no_common_samples}
    else
      # Build rating pairs
      pairs =
        common_samples
        |> Enum.map(fn sample_id ->
          label1 = Enum.find(labels1, &(&1.sample_id == sample_id))
          label2 = Enum.find(labels2, &(&1.sample_id == sample_id))

          value1 = extract_value(label1, field)
          value2 = extract_value(label2, field)

          {value1, value2}
        end)

      kappa = calculate_kappa(pairs)
      {:ok, kappa}
    end
  end

  defp calculate_kappa(pairs) do
    n = length(pairs)

    # Observed agreement
    agreements = Enum.count(pairs, fn {v1, v2} -> v1 == v2 end)
    p_o = agreements / n

    # Expected agreement by chance
    all_values = pairs |> Enum.flat_map(&Tuple.to_list/1) |> Enum.uniq()

    p_e =
      all_values
      |> Enum.map(fn value ->
        # Proportion of times each rater used this value
        p1 = Enum.count(pairs, fn {v1, _} -> v1 == value end) / n
        p2 = Enum.count(pairs, fn {_, v2} -> v2 == value end) / n
        p1 * p2
      end)
      |> Enum.sum()

    # Cohen's kappa
    if p_e == 1.0 do
      1.0
    else
      (p_o - p_e) / (1 - p_e)
    end
  end

  defp extract_value(label, nil) do
    # Use first field if not specified
    label.values |> Map.values() |> List.first()
  end

  defp extract_value(label, field) do
    Map.get(label.values, field)
  end
end
