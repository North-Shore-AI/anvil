defmodule Anvil.MixProject do
  use Mix.Project

  def project do
    [
      app: :anvil,
      version: "0.1.0",
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      description: description(),
      package: package(),
      source_url: "https://github.com/North-Shore-AI/anvil",
      homepage_url: "https://github.com/North-Shore-AI/anvil",
      docs: [
        main: "Anvil",
        extras: ["README.md"]
      ]
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger],
      mod: {Anvil.Application, []}
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:jason, "~> 1.4"},
      {:supertester, "~> 0.3.1", only: :test},
      {:ex_doc, "~> 0.31", only: :dev, runtime: false}
    ]
  end

  defp description do
    "Labeling queue library for managing human labeling workflows"
  end

  defp package do
    [
      name: "anvil",
      licenses: ["MIT"],
      links: %{"GitHub" => "https://github.com/North-Shore-AI/anvil"}
    ]
  end
end
