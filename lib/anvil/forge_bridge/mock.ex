defmodule Anvil.ForgeBridge.Mock do
  @moduledoc """
  Mock implementation of ForgeBridge for testing.

  Returns fixture data without requiring Forge to be running. Useful for:
  - Unit tests
  - Integration tests
  - Development without Forge dependency

  ## Configuration

      # config/test.exs
      config :anvil, forge_bridge_backend: Anvil.ForgeBridge.Mock

  ## Behavior

  - `fetch_sample/2` - Returns mock sample with predictable content
  - `fetch_samples/2` - Batch returns mock samples
  - `verify_sample_exists/1` - Always returns true
  - `fetch_sample_version/1` - Returns "mock_v1" version

  Mock samples have content based on their ID for deterministic testing.
  """

  @behaviour Anvil.ForgeBridge

  alias Anvil.ForgeBridge.SampleDTO

  @impl true
  def fetch_sample(sample_id, opts \\ []) do
    # Simulate not found for specific test IDs
    if sample_id == "non-existent-id" do
      {:error, :not_found}
    else
      {:ok, build_mock_sample(sample_id, opts)}
    end
  end

  @impl true
  def fetch_samples(sample_ids, opts \\ []) when is_list(sample_ids) do
    samples =
      sample_ids
      |> Enum.reject(&(&1 == "non-existent-id"))
      |> Enum.map(&build_mock_sample(&1, opts))

    {:ok, samples}
  end

  @impl true
  def verify_sample_exists(sample_id) do
    sample_id != "non-existent-id"
  end

  @impl true
  def fetch_sample_version(sample_id) do
    if sample_id == "non-existent-id" do
      {:error, :not_found}
    else
      {:ok, "mock_v1"}
    end
  end

  # Private helpers

  defp build_mock_sample(sample_id, opts) do
    version = Keyword.get(opts, :version, "mock_v1")

    %SampleDTO{
      id: sample_id,
      content: %{
        "text" => "Mock sample content for #{sample_id}",
        "type" => "text"
      },
      version: version,
      metadata: %{
        "mock" => true,
        "difficulty" => "easy"
      },
      asset_urls: [],
      source: "mock_dataset",
      created_at: DateTime.utc_now()
    }
  end
end
