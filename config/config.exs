import Config

config :anvil, Anvil.Repo,
  database: "anvil_dev",
  username: "postgres",
  password: "postgres",
  hostname: "localhost"

config :anvil, ecto_repos: [Anvil.Repo]

import_config "#{config_env()}.exs"
