ExUnit.start()

# Configure Supertester
Application.put_env(:supertester, :isolation, :full_isolation)

# Start Ecto Sandbox for test isolation
Ecto.Adapters.SQL.Sandbox.mode(Anvil.Repo, :manual)
