defmodule Anvil.Storage do
  @moduledoc """
  Behaviour for storage backends.

  Allows pluggable storage implementations (ETS, Postgres, etc.)
  """

  @callback init(opts :: keyword()) :: {:ok, state :: any()} | {:error, term()}

  @callback put_assignment(state :: any(), assignment :: Anvil.Assignment.t()) ::
              {:ok, state :: any()} | {:error, term()}

  @callback get_assignment(state :: any(), id :: String.t()) ::
              {:ok, Anvil.Assignment.t(), state :: any()} | {:error, term()}

  @callback list_assignments(state :: any(), filters :: keyword()) ::
              {:ok, [Anvil.Assignment.t()], state :: any()}

  @callback put_label(state :: any(), label :: Anvil.Label.t()) ::
              {:ok, state :: any()} | {:error, term()}

  @callback get_label(state :: any(), id :: String.t()) ::
              {:ok, Anvil.Label.t(), state :: any()} | {:error, term()}

  @callback list_labels(state :: any(), filters :: keyword()) ::
              {:ok, [Anvil.Label.t()], state :: any()}

  @callback put_sample(state :: any(), sample :: map()) ::
              {:ok, state :: any()} | {:error, term()}

  @callback get_sample(state :: any(), id :: String.t()) ::
              {:ok, map(), state :: any()} | {:error, term()}

  @callback list_samples(state :: any(), filters :: keyword()) ::
              {:ok, [map()], state :: any()}
end
