defmodule Anvil.API.Server do
  @moduledoc """
  Boots the Anvil `/v1` Plug router via Plug.Cowboy.

  Controlled by `:anvil, :api_server` config:

      config :anvil, :api_server, enabled: true, port: 4101

  In test, this is disabled to avoid port binding.
  """

  use Supervisor

  def start_link(_opts) do
    Supervisor.start_link(__MODULE__, [], name: __MODULE__)
  end

  @impl true
  def init(_) do
    config = Application.get_env(:anvil, :api_server, [])

    case Keyword.get(config, :enabled, false) do
      true ->
        port = Keyword.get(config, :port, 4101)
        cowboy = {Plug.Cowboy, scheme: :http, plug: Anvil.API.Router, options: [port: port]}
        Supervisor.init([cowboy], strategy: :one_for_one)

      _ ->
        Supervisor.init([], strategy: :one_for_one)
    end
  end
end
