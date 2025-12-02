defmodule Anvil.Repo do
  @moduledoc """
  Ecto repository for Anvil's Postgres storage adapter.

  Provides database access for labeling queues, assignments, labels,
  and related entities.
  """

  use Ecto.Repo,
    otp_app: :anvil,
    adapter: Ecto.Adapters.Postgres
end
