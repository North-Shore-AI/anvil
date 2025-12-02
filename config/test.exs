import Config

config :anvil, Anvil.Repo,
  database: "anvil_test",
  username: "postgres",
  password: "postgres",
  hostname: "localhost",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: 10

config :logger, level: :warning

# Configure Oban for testing (inline execution, no queues)
config :anvil, Oban, testing: :inline

# Configure ForgeBridge to use Mock adapter in tests
config :anvil,
  forge_bridge_backend: Anvil.ForgeBridge.Mock,
  forge_bridge_primary_backend: Anvil.ForgeBridge.Mock
