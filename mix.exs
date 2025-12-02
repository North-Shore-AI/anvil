defmodule Anvil.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/North-Shore-AI/anvil"

  def project do
    [
      app: :anvil,
      version: @version,
      elixir: "~> 1.15",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      description: description(),
      package: package(),
      name: "Anvil",
      source_url: @source_url,
      homepage_url: @source_url,
      docs: docs(),
      dialyzer: dialyzer()
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {Anvil.Application, []}
    ]
  end

  defp deps do
    [
      {:jason, "~> 1.4"},
      {:ecto_sql, "~> 3.10"},
      {:postgrex, "~> 0.17"},
      {:oban, "~> 2.17"},
      {:telemetry, "~> 1.2"},
      {:telemetry_metrics, "~> 1.0"},
      {:cachex, "~> 3.6"},
      {:fuse, "~> 2.5"},
      {:httpoison, "~> 2.2"},
      {:ex_doc, "~> 0.31", only: :dev, runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:supertester, "~> 0.3.1", only: :test}
    ]
  end

  defp description do
    """
    Labeling queue library for managing human labeling workflows.
    Domain-agnostic HITL (human-in-the-loop) data annotation with
    inter-rater reliability metrics (Cohen's kappa, Fleiss' kappa,
    Krippendorff's alpha) and export to standard formats.
    """
  end

  defp package do
    [
      name: "anvil_ex",
      licenses: ["MIT"],
      links: %{
        "GitHub" => @source_url,
        "Changelog" => "#{@source_url}/blob/main/CHANGELOG.md"
      },
      maintainers: ["North-Shore-AI"],
      files: ~w(lib .formatter.exs mix.exs README.md LICENSE CHANGELOG.md)
    ]
  end

  defp docs do
    [
      main: "Anvil",
      extras: ["README.md", "CHANGELOG.md"],
      source_ref: "v#{@version}",
      source_url: @source_url,
      groups_for_modules: [
        Core: [
          Anvil,
          Anvil.Schema,
          Anvil.Queue,
          Anvil.Assignment,
          Anvil.Label
        ],
        "Schema Fields": [
          Anvil.Schema.Field
        ],
        "Queue Policies": [
          Anvil.Queue.Policy
        ],
        Agreement: [
          Anvil.Agreement,
          Anvil.Agreement.Cohen,
          Anvil.Agreement.Fleiss,
          Anvil.Agreement.Krippendorff
        ],
        Export: [
          Anvil.Export,
          Anvil.Export.CSV,
          Anvil.Export.JSONL
        ],
        Storage: [
          Anvil.Storage,
          Anvil.Storage.ETS
        ],
        "Forge Integration": [
          Anvil.ForgeBridge,
          Anvil.ForgeBridge.SampleDTO,
          Anvil.ForgeBridge.Direct,
          Anvil.ForgeBridge.HTTP,
          Anvil.ForgeBridge.Cached,
          Anvil.ForgeBridge.Mock
        ]
      ]
    ]
  end

  defp dialyzer do
    [
      plt_file: {:no_warn, "priv/plts/dialyzer.plt"},
      plt_add_apps: [:mix, :ex_unit]
    ]
  end
end
