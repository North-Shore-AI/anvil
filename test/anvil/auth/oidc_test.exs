defmodule Anvil.Auth.OIDCTest do
  use ExUnit.Case, async: true

  alias Anvil.Auth.OIDC

  describe "behaviour callbacks" do
    test "defines authenticate/2 and verify_token/1 callbacks" do
      # Verify the behaviour module exists and has callbacks
      _behaviours = OIDC.__info__(:attributes)[:behaviour] || []
      # The behaviour should define callbacks (we can't easily test this directly,
      # but we can verify the Mock adapter implements them)
      assert function_exported?(OIDC.Mock, :authenticate, 2)
      assert function_exported?(OIDC.Mock, :verify_token, 1)
    end
  end

  describe "Mock adapter" do
    setup do
      {:ok, adapter: OIDC.Mock}
    end

    test "authenticate/2 returns labeler for valid token", %{adapter: adapter} do
      token = "valid-token-123"

      {:ok, labeler} = adapter.authenticate(token)

      assert labeler.external_id != nil
      assert labeler.email != nil
      assert labeler.tenant_id != nil
      assert labeler.role == :labeler
      assert labeler.status == :active
    end

    test "authenticate/2 with custom claims", %{adapter: adapter} do
      token = "valid-token-123"
      opts = [tenant_id: "custom-tenant", role: :admin]

      {:ok, labeler} = adapter.authenticate(token, opts)

      assert labeler.tenant_id == "custom-tenant"
      assert labeler.role == :admin
    end

    test "authenticate/2 returns error for invalid token", %{adapter: adapter} do
      token = "invalid-token"

      assert {:error, :invalid_token} = adapter.authenticate(token)
    end

    test "authenticate/2 returns error for expired token", %{adapter: adapter} do
      token = "expired-token"

      assert {:error, :expired_token} = adapter.authenticate(token)
    end

    test "verify_token/1 returns claims for valid token", %{adapter: adapter} do
      token = "valid-token-123"

      {:ok, claims} = adapter.verify_token(token)

      assert is_map(claims)
      assert claims["sub"] != nil
      assert claims["email"] != nil
      assert claims["exp"] != nil
      assert claims["iss"] != nil
    end

    test "verify_token/1 returns error for invalid token", %{adapter: adapter} do
      token = "invalid-token"

      assert {:error, :invalid_token} = adapter.verify_token(token)
    end

    test "verify_token/1 returns error for malformed token", %{adapter: adapter} do
      token = "malformed"

      assert {:error, :invalid_token} = adapter.verify_token(token)
    end

    test "verify_token/1 checks expiration", %{adapter: adapter} do
      token = "expired-token"

      assert {:error, :expired_token} = adapter.verify_token(token)
    end
  end

  describe "Claims struct" do
    test "creates claims with required fields" do
      claims = %OIDC.Claims{
        sub: "user-123",
        email: "user@example.com",
        exp: DateTime.utc_now() |> DateTime.add(3600, :second) |> DateTime.to_unix(),
        iss: "https://auth.example.com",
        tenant_id: "tenant-1"
      }

      assert claims.sub == "user-123"
      assert claims.email == "user@example.com"
      assert claims.tenant_id == "tenant-1"
    end

    test "has optional fields" do
      claims = %OIDC.Claims{
        sub: "user-123",
        email: "user@example.com",
        exp: DateTime.utc_now() |> DateTime.add(3600, :second) |> DateTime.to_unix(),
        iss: "https://auth.example.com",
        tenant_id: "tenant-1",
        name: "John Doe",
        preferred_username: "jdoe"
      }

      assert claims.name == "John Doe"
      assert claims.preferred_username == "jdoe"
    end
  end

  describe "Labeler struct from OIDC" do
    test "creates labeler from claims" do
      labeler = %OIDC.Labeler{
        external_id: "oidc-user-123",
        email: "user@example.com",
        tenant_id: "tenant-1",
        role: :labeler,
        status: :active
      }

      assert labeler.external_id == "oidc-user-123"
      assert labeler.email == "user@example.com"
      assert labeler.tenant_id == "tenant-1"
      assert labeler.role == :labeler
      assert labeler.status == :active
    end
  end
end
