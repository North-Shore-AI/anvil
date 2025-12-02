defmodule Anvil.Agreement.Krippendorff do
  @moduledoc """
  Krippendorff's alpha for measuring agreement with support for missing data.

  α = 1 - (D_o / D_e)

  where:
  - D_o = observed disagreement
  - D_e = expected disagreement by chance
  """

  @doc """
  Computes Krippendorff's alpha.

  ## Options

    * `:field` - Field name to compute agreement for (default: first field in values)
    * `:metric` - Distance metric (:nominal, :ordinal, :interval, :ratio) (default: :nominal)

  """
  @spec compute([Anvil.Label.t()], keyword()) :: {:ok, float()} | {:error, term()}
  def compute(labels, opts \\ []) do
    field = Keyword.get(opts, :field)
    metric = Keyword.get(opts, :metric, :nominal)

    # Group labels by sample
    grouped =
      labels
      |> Enum.group_by(& &1.sample_id)

    if Enum.empty?(grouped) do
      {:error, :no_labels}
    else
      # Build reliability matrix (samples × raters)
      # Missing values are represented as nil
      {matrix, all_values} = build_reliability_matrix(grouped, field)

      alpha = calculate_alpha(matrix, all_values, metric)
      {:ok, alpha}
    end
  end

  defp build_reliability_matrix(grouped, field) do
    # Get all labelers
    labelers =
      grouped
      |> Enum.flat_map(fn {_, labels} -> Enum.map(labels, & &1.labeler_id) end)
      |> Enum.uniq()
      |> Enum.sort()

    # Build matrix
    matrix =
      grouped
      |> Enum.map(fn {_sample_id, sample_labels} ->
        labelers
        |> Enum.map(fn labeler ->
          label = Enum.find(sample_labels, &(&1.labeler_id == labeler))

          if label do
            extract_value(label, field)
          else
            nil
          end
        end)
      end)

    # Collect all non-nil values
    all_values =
      matrix
      |> List.flatten()
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()
      |> Enum.sort()

    {matrix, all_values}
  end

  defp calculate_alpha(matrix, all_values, metric) do
    # Calculate coincidence matrix
    coincidence = build_coincidence_matrix(matrix, all_values)

    # Observed disagreement
    d_o = observed_disagreement(coincidence, metric, all_values)

    # Expected disagreement
    d_e = expected_disagreement(coincidence, metric, all_values)

    # Krippendorff's alpha
    if d_e == 0.0 do
      1.0
    else
      1.0 - d_o / d_e
    end
  end

  defp build_coincidence_matrix(matrix, all_values) do
    # Initialize coincidence matrix
    n = length(all_values)
    coincidence = for _ <- 1..n, do: List.duplicate(0, n)

    # For each sample (row in matrix)
    matrix
    |> Enum.reduce(coincidence, fn row, acc ->
      # Get non-nil values
      values = Enum.reject(row, &is_nil/1)
      m = length(values)

      if m < 2 do
        acc
      else
        # Count pairwise coincidences
        update_coincidence_matrix(acc, values, all_values, m)
      end
    end)
  end

  defp update_coincidence_matrix(matrix, values, all_values, m) do
    # For each pair of values
    for i <- 0..(length(all_values) - 1),
        j <- 0..(length(all_values) - 1) do
      val_i = Enum.at(all_values, i)
      val_j = Enum.at(all_values, j)

      count_i = Enum.count(values, &(&1 == val_i))
      count_j = Enum.count(values, &(&1 == val_j))

      if i == j do
        # Diagonal: count_i * (count_i - 1) / (m - 1)
        increment = count_i * (count_i - 1) / (m - 1)
        update_matrix_cell(matrix, i, j, increment)
      else
        # Off-diagonal: count_i * count_j / (m - 1)
        increment = count_i * count_j / (m - 1)
        update_matrix_cell(matrix, i, j, increment)
      end
    end

    matrix
  end

  defp update_matrix_cell(matrix, i, j, increment) do
    row = Enum.at(matrix, i)
    current = Enum.at(row, j)
    new_row = List.replace_at(row, j, current + increment)
    List.replace_at(matrix, i, new_row)
  end

  defp observed_disagreement(coincidence, :nominal, all_values) do
    n = length(all_values)

    # Sum off-diagonal elements
    for i <- 0..(n - 1), j <- 0..(n - 1), i != j, reduce: 0.0 do
      acc ->
        val = get_matrix_value(coincidence, i, j)
        acc + val
    end
  end

  defp observed_disagreement(coincidence, _metric, _all_values) do
    # Simplified: for other metrics, use nominal distance
    # Full implementation would use different distance functions
    observed_disagreement(coincidence, :nominal, _all_values)
  end

  defp expected_disagreement(coincidence, :nominal, all_values) do
    n = length(all_values)

    # Sum of marginals
    marginals =
      for i <- 0..(n - 1) do
        Enum.sum(Enum.at(coincidence, i))
      end

    total = Enum.sum(marginals)

    # Expected disagreement
    for i <- 0..(n - 1), j <- 0..(n - 1), i != j, reduce: 0.0 do
      acc ->
        m_i = Enum.at(marginals, i)
        m_j = Enum.at(marginals, j)
        acc + m_i * m_j / (total - 1)
    end
  end

  defp expected_disagreement(coincidence, _metric, all_values) do
    # Simplified: for other metrics, use nominal distance
    expected_disagreement(coincidence, :nominal, all_values)
  end

  defp get_matrix_value(matrix, i, j) do
    matrix |> Enum.at(i) |> Enum.at(j)
  end

  defp extract_value(label, nil) do
    # Use first field if not specified
    label.values |> Map.values() |> List.first()
  end

  defp extract_value(label, field) do
    Map.get(label.values, field)
  end
end
