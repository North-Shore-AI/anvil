import Config

config :anvil, Anvil.Repo,
  database: "anvil_dev",
  username: "postgres",
  password: "postgres",
  hostname: "localhost"

config :anvil, ecto_repos: [Anvil.Repo]

# API server configuration (Plug.Cowboy)
config :anvil, :api_server,
  enabled: true,
  port: 4101

# ForgeBridge Configuration
config :anvil,
  forge_bridge_backend: Anvil.ForgeBridge.Direct,
  forge_schema: "forge",
  forge_cache_ttl: :timer.minutes(15)

# Oban Configuration
config :anvil, Oban,
  repo: Anvil.Repo,
  plugins: [
    # Cron scheduling for recurring jobs
    {Oban.Plugins.Cron,
     crontab: [
       # Timeout sweeps every 5 minutes
       {"*/5 * * * *", Anvil.Workers.TimeoutChecker},
       # Agreement recompute nightly at 2 AM
       {"0 2 * * *", Anvil.Workers.AgreementRecompute},
       # Retention sweep daily at 3 AM
       {"0 3 * * *", Anvil.Workers.RetentionSweep}
     ]},
    # Prune completed jobs after 7 days
    {Oban.Plugins.Pruner, max_age: 60 * 60 * 24 * 7},
    # Rescue orphaned jobs (e.g., if node crashes mid-execution)
    {Oban.Plugins.Lifeline, rescue_after: :timer.minutes(30)},
    # Monitor queue depth
    {Oban.Plugins.Stager, interval: 1000}
  ],
  queues: [
    # High priority queues
    timeouts: 1,
    # Medium priority queues
    exports: 3,
    agreement: 2,
    # Low priority queues
    maintenance: 1
  ]

import_config "#{config_env()}.exs"
