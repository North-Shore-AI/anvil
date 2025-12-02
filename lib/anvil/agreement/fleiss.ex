defmodule Anvil.Agreement.Fleiss do
  @moduledoc """
  Fleiss' kappa for measuring agreement among multiple raters.

  κ = (P̄ - P̄_e) / (1 - P̄_e)

  where:
  - P̄ = mean observed agreement across samples
  - P̄_e = expected agreement by chance
  """

  @doc """
  Computes Fleiss' kappa for n raters.

  ## Options

    * `:field` - Field name to compute agreement for (default: first field in values)

  """
  @spec compute([Anvil.Label.t()], keyword()) :: {:ok, float()} | {:error, term()}
  def compute(labels, opts \\ []) do
    field = Keyword.get(opts, :field)

    # Group labels by sample
    grouped =
      labels
      |> Enum.group_by(& &1.sample_id)

    if Enum.empty?(grouped) do
      {:error, :no_labels}
    else
      # Build rating matrix
      matrix =
        grouped
        |> Enum.map(fn {_sample_id, sample_labels} ->
          sample_labels
          |> Enum.map(&extract_value(&1, field))
        end)

      kappa = calculate_fleiss_kappa(matrix)
      {:ok, kappa}
    end
  end

  defp calculate_fleiss_kappa(matrix) do
    n = length(matrix)
    k = matrix |> List.first() |> length()

    # Get all unique categories
    categories =
      matrix
      |> List.flatten()
      |> Enum.uniq()
      |> Enum.sort()

    # Build frequency table: for each sample, count votes per category
    freq_table =
      matrix
      |> Enum.map(fn ratings ->
        categories
        |> Enum.map(fn cat ->
          Enum.count(ratings, &(&1 == cat))
        end)
      end)

    # Calculate P_i for each sample (extent of agreement)
    p_values =
      freq_table
      |> Enum.map(fn freqs ->
        sum_squares = freqs |> Enum.map(&(&1 * &1)) |> Enum.sum()
        (sum_squares - k) / (k * (k - 1))
      end)

    # Mean observed agreement
    p_bar = Enum.sum(p_values) / n

    # Calculate proportion of all assignments to each category
    p_j =
      categories
      |> Enum.with_index()
      |> Enum.map(fn {_cat, idx} ->
        sum = freq_table |> Enum.map(&Enum.at(&1, idx)) |> Enum.sum()
        sum / (n * k)
      end)

    # Expected agreement by chance
    p_e = p_j |> Enum.map(&(&1 * &1)) |> Enum.sum()

    # Fleiss' kappa
    if p_e == 1.0 do
      1.0
    else
      (p_bar - p_e) / (1 - p_e)
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
