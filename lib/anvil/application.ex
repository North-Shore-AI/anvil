defmodule Anvil.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      # Ecto Repo for Postgres storage
      Anvil.Repo,
      # Oban background job processing
      {Oban, Application.fetch_env!(:anvil, Oban)},
      # Registry for queue processes
      {Registry, keys: :unique, name: Anvil.Registry},
      # Cachex for Forge sample caching
      {Cachex, name: :forge_samples},
      # Task supervisor for async operations
      {Task.Supervisor, name: Anvil.TaskSupervisor}
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Anvil.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
