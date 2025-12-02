defmodule Anvil.Auth.OIDC do
  @moduledoc """
  OIDC (OpenID Connect) authentication behaviour for Anvil.

  Defines interface for authenticating labelers via OIDC tokens from
  identity providers like Auth0, Okta, Keycloak, Google, etc.

  Implementations should verify JWT signatures, check expiration,
  validate issuer, and extract standard OIDC claims.
  """

  defmodule Claims do
    @moduledoc """
    Standard OIDC claims extracted from ID token.
    """

    @type t :: %__MODULE__{
            sub: String.t(),
            email: String.t(),
            exp: integer(),
            iss: String.t(),
            tenant_id: String.t(),
            name: String.t() | nil,
            preferred_username: String.t() | nil
          }

    @enforce_keys [:sub, :email, :exp, :iss, :tenant_id]
    defstruct [
      :sub,
      :email,
      :exp,
      :iss,
      :tenant_id,
      :name,
      :preferred_username
    ]
  end

  defmodule Labeler do
    @moduledoc """
    Labeler identity created from OIDC authentication.
    """

    @type t :: %__MODULE__{
            external_id: String.t(),
            email: String.t(),
            tenant_id: String.t(),
            role: Anvil.Auth.Role.role(),
            status: :active | :suspended | :deactivated
          }

    @enforce_keys [:external_id, :email, :tenant_id, :role, :status]
    defstruct [
      :external_id,
      :email,
      :tenant_id,
      :role,
      :status
    ]
  end

  @type token :: String.t()
  @type opts :: keyword()
  @type error_reason :: :invalid_token | :expired_token | :invalid_issuer | :missing_claims

  @doc """
  Authenticates a labeler using an OIDC token.

  Returns labeler identity with external_id, email, tenant_id, and default role.
  Implements just-in-time provisioning - creates labeler on first login.

  ## Options
    - `:tenant_id` - Override tenant_id from token claims
    - `:role` - Override default role (:labeler)
  """
  @callback authenticate(token(), opts()) :: {:ok, Labeler.t()} | {:error, error_reason()}

  @doc """
  Verifies OIDC token and extracts claims.

  Should verify:
  - JWT signature using provider's public key
  - Token expiration (exp claim)
  - Issuer matches expected value (iss claim)
  - Audience matches client ID (aud claim)
  """
  @callback verify_token(token()) :: {:ok, map()} | {:error, error_reason()}
end
