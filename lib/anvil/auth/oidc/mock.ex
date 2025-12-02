defmodule Anvil.Auth.OIDC.Mock do
  @moduledoc """
  Mock OIDC adapter for testing.

  Accepts specific token patterns for testing various scenarios:
  - "valid-token-*" -> Returns successful authentication
  - "expired-token" -> Returns expired error
  - "invalid-token" -> Returns invalid error
  - Anything else -> Returns invalid error
  """

  @behaviour Anvil.Auth.OIDC

  alias Anvil.Auth.OIDC
  alias Anvil.Auth.Role

  @impl true
  def authenticate(token, opts \\ []) do
    case verify_token(token) do
      {:ok, claims} ->
        labeler = build_labeler(claims, opts)
        {:ok, labeler}

      error ->
        error
    end
  end

  @impl true
  def verify_token("expired-token") do
    {:error, :expired_token}
  end

  def verify_token("invalid-token") do
    {:error, :invalid_token}
  end

  def verify_token("valid-token-" <> _rest = token) do
    claims = %{
      "sub" => extract_user_id(token),
      "email" => "test@example.com",
      "exp" => DateTime.utc_now() |> DateTime.add(3600, :second) |> DateTime.to_unix(),
      "iss" => "https://mock-idp.example.com",
      "tenant_id" => "default-tenant",
      "name" => "Test User"
    }

    {:ok, claims}
  end

  def verify_token(_token) do
    {:error, :invalid_token}
  end

  # Private helpers

  defp build_labeler(claims, opts) do
    %OIDC.Labeler{
      external_id: claims["sub"],
      email: claims["email"],
      tenant_id: opts[:tenant_id] || claims["tenant_id"],
      role: opts[:role] || Role.default(),
      status: :active
    }
  end

  defp extract_user_id("valid-token-" <> rest) do
    if rest == "" do
      "user-#{:erlang.unique_integer([:positive])}"
    else
      "user-#{rest}"
    end
  end
end
