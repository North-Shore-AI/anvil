import Config

# Development-specific configuration
config :anvil, Anvil.Repo,
  show_sensitive_data_on_connection_error: true,
  pool_size: 10
