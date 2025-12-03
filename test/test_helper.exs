ExUnit.start(max_cases: 1)

# Configure Supertester
Application.put_env(:supertester, :isolation, :full_isolation)

# Start Ecto Sandbox for test isolation when repo is enabled
if Application.get_env(:anvil, :start_repo, true) do
  Ecto.Adapters.SQL.Sandbox.mode(Anvil.Repo, :manual)
end
