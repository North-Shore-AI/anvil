defmodule Anvil.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children =
      []
      |> maybe_child(Application.get_env(:anvil, :start_repo, true), Anvil.Repo)
      |> maybe_child(
        Application.get_env(:anvil, :start_oban, true),
        {Oban, Application.get_env(:anvil, Oban, [])}
      )
      |> maybe_child(true, {Registry, keys: :unique, name: Anvil.Registry})
      |> maybe_child(true, {Cachex, name: :forge_samples})
      |> maybe_child(true, {Task.Supervisor, name: Anvil.TaskSupervisor})
      |> maybe_child(api_enabled?(), Anvil.API.Server)

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Anvil.Supervisor]
    Supervisor.start_link(children, opts)
  end

  defp maybe_child(children, true, child), do: children ++ [child]
  defp maybe_child(children, _flag, _child), do: children

  defp api_enabled? do
    config = Application.get_env(:anvil, :api_server, [])
    Keyword.get(config, :enabled, false)
  end
end
