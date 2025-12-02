defmodule Anvil.Agreement do
  @moduledoc """
  Inter-rater agreement metrics for measuring labeler consistency.

  Automatically selects the appropriate metric based on the data.
  """

  alias Anvil.Agreement.{Cohen, Fleiss, Krippendorff}

  @doc """
  Computes agreement metric, automatically selecting the appropriate algorithm.

  ## Options

    * `:metric` - Force a specific metric (:cohen, :fleiss, :krippendorff)
    * `:field` - Field name to compute agreement for (default: uses all fields)

  """
  @spec compute([Anvil.Label.t()], keyword()) :: {:ok, float()} | {:error, term()}
  def compute(labels, opts \\ []) do
    metric = Keyword.get(opts, :metric)

    cond do
      metric == :cohen -> Cohen.compute(labels, opts)
      metric == :fleiss -> Fleiss.compute(labels, opts)
      metric == :krippendorff -> Krippendorff.compute(labels, opts)
      true -> auto_select(labels, opts)
    end
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
