# ADR-007: Authentication and Access Control

## Status
Accepted

## Context

Labeling platforms handle sensitive workflows requiring multi-layered authorization:

**Identity Management**:
- Labelers authenticate via organizational identity provider (SSO, OIDC)
- Service accounts for automated exports, API integrations
- Anonymous/guest labelers for public crowdsourcing (future use case)

**Access Control Requirements**:
- **Queue Isolation**: Labelers should only access queues they're assigned to (prevent cross-project contamination)
- **Role-Based Access**: Different permission levels (labeler, auditor, adjudicator, admin)
- **Least Privilege**: Default-deny access model; explicit grants required
- **Audit Trail**: All authorization decisions logged for compliance review
- **Time-Limited Access**: Temporary queue membership (e.g., 30-day contract labelers)

**Asset Security**:
- **Sample Content**: Samples from Forge may contain sensitive images, documents, or videos
- **Signed URLs**: Pre-signed S3 URLs for assets expire after short duration
- **Audit Logging**: Track who accessed which samples and when

**Multi-Tenancy**:
- Organizations (tenants) must be strictly isolated
- Cross-tenant access forbidden (even for platform admins)
- Tenant ID propagated through all authorization checks

Current Anvil v0.1 has no access control:
- Any labeler can request assignments from any queue
- No queue membership concept
- No audit logging for access decisions
- No integration with identity providers

Without systematic access control, Anvil cannot support:
- Multi-customer SaaS deployments
- Compliance requirements (SOC 2, ISO 27001)
- Sensitive data labeling (HIPAA, PII)

## Decision

We will implement role-based access control (RBAC) with queue memberships, default-deny policies, and OIDC integration for identity.

### 1. Labeler Identity Model

**Core Identity Fields**:

```elixir
defmodule Anvil.Labelers.Labeler do
  use Ecto.Schema

  schema "labelers" do
    field :tenant_id, :binary_id  # Organization/workspace isolation
    field :external_id, :string   # OIDC 'sub' claim or internal user ID
    field :email, :string         # For notifications (optional, PII)
    field :pseudonym, :string     # Export-safe identifier
    field :role, Ecto.Enum, values: [:labeler, :auditor, :adjudicator, :admin]
    field :status, Ecto.Enum, values: [:active, :suspended, :deactivated]
    field :expertise_weights, :map  # For weighted assignment policies
    field :blocklisted_queues, {:array, :binary_id}
    field :max_concurrent_assignments, :integer, default: 5

    has_many :queue_memberships, Anvil.Labelers.QueueMembership
    has_many :assignments, Anvil.Assignments.Assignment
    has_many :labels, Anvil.Labels.Label

    timestamps()
  end
end
```

**OIDC Integration**:

```elixir
defmodule Anvil.Auth.OIDC do
  @doc """
  Authenticate labeler via OIDC token (e.g., from Auth0, Okta, Keycloak).
  Creates labeler record on first login (just-in-time provisioning).
  """
  def authenticate(oidc_token, opts \\ []) do
    with {:ok, claims} <- verify_token(oidc_token),
         {:ok, labeler} <- find_or_create_labeler(claims) do
      {:ok, labeler}
    end
  end

  defp verify_token(token) do
    # Verify JWT signature, expiration, issuer
    # Use Joken or Guardian library
    case Joken.verify(token, signer()) do
      {:ok, claims} -> {:ok, claims}
      {:error, reason} -> {:error, :invalid_token}
    end
  end

  defp find_or_create_labeler(claims) do
    # Extract standard OIDC claims
    external_id = claims["sub"]
    email = claims["email"]
    tenant_id = claims["org_id"] || extract_tenant_from_email(email)

    case Repo.get_by(Labeler, external_id: external_id, tenant_id: tenant_id) do
      nil ->
        # Just-in-time provisioning
        Labelers.create_labeler(%{
          tenant_id: tenant_id,
          external_id: external_id,
          email: email,
          role: :labeler,  # Default role
          status: :active
        })

      labeler ->
        {:ok, labeler}
    end
  end
end
```

**Service Accounts** (for API access):

```elixir
defmodule Anvil.Auth.ServiceAccount do
  use Ecto.Schema

  schema "service_accounts" do
    field :tenant_id, :binary_id
    field :name, :string  # e.g., "crucible_export_job"
    field :api_key_hash, :string  # bcrypt hash of API key
    field :scopes, {:array, :string}  # e.g., ["queue:read", "export:create"]
    field :expires_at, :utc_datetime

    timestamps()
  end
end

# API key authentication
def authenticate_api_key(api_key) do
  hash = hash_api_key(api_key)

  case Repo.get_by(ServiceAccount, api_key_hash: hash) do
    nil -> {:error, :invalid_api_key}
    account ->
      if DateTime.compare(account.expires_at, DateTime.utc_now()) == :gt do
        {:ok, account}
      else
        {:error, :expired_api_key}
      end
  end
end
```

### 2. Queue Access Control Lists (ACLs)

**Queue Membership Model**:

```elixir
defmodule Anvil.Labelers.QueueMembership do
  use Ecto.Schema

  schema "queue_memberships" do
    belongs_to :queue, Anvil.Queues.Queue
    belongs_to :labeler, Anvil.Labelers.Labeler

    field :role, Ecto.Enum, values: [:labeler, :reviewer, :owner]
    field :granted_by, :binary_id  # Labeler ID who granted access
    field :granted_at, :utc_datetime
    field :expires_at, :utc_datetime  # Time-limited access
    field :revoked_at, :utc_datetime

    timestamps()
  end
end
```

**Queue Table Updates**:

```elixir
schema "queues" do
  # ... existing fields ...
  field :access_mode, Ecto.Enum, values: [:private, :restricted, :public], default: :private
  field :default_role, Ecto.Enum, values: [:labeler, :reviewer], default: :labeler
end
```

**Access Modes**:
- `:private` - Explicit membership required (default)
- `:restricted` - Any labeler in tenant can request access, requires approval
- `:public` - Any authenticated labeler can join (for crowdsourcing)

### 3. Role Model

**Roles and Permissions**:

| Role | Permissions |
|------|-------------|
| **Labeler** | Request assignments, submit labels, view own labels |
| **Reviewer/Auditor** | View all labels, export data, compute agreement (read-only) |
| **Adjudicator** | Resolve label conflicts, override labels, approve/reject labels |
| **Queue Owner** | Manage queue membership, update policies, archive queue |
| **Tenant Admin** | All permissions within tenant, manage labelers, create queues |
| **Platform Admin** | Cross-tenant access (NSAI operators only) |

**Permission Checks**:

```elixir
defmodule Anvil.Auth.Abilities do
  @doc """
  Check if labeler can perform action on resource.
  Returns :ok or {:error, :forbidden}.
  """
  def can?(labeler, action, resource)

  # Labeler permissions
  def can?(%Labeler{role: :labeler}, :request_assignment, %Queue{} = queue) do
    check_queue_membership(labeler, queue, [:labeler, :reviewer, :owner])
  end

  def can?(%Labeler{role: :labeler}, :submit_label, %Assignment{labeler_id: labeler_id}) do
    if labeler.id == labeler_id, do: :ok, else: {:error, :forbidden}
  end

  # Auditor permissions
  def can?(%Labeler{role: :auditor}, :view_all_labels, %Queue{} = queue) do
    check_queue_membership(labeler, queue, [:reviewer, :owner])
  end

  def can?(%Labeler{role: :auditor}, :export_data, %Queue{} = queue) do
    check_queue_membership(labeler, queue, [:reviewer, :owner])
  end

  # Adjudicator permissions
  def can?(%Labeler{role: :adjudicator}, :override_label, %Label{}) do
    :ok  # Adjudicators can override any label in their tenant
  end

  # Admin permissions
  def can?(%Labeler{role: :admin}, _action, %{tenant_id: tenant_id}) do
    if labeler.tenant_id == tenant_id, do: :ok, else: {:error, :forbidden}
  end

  # Default deny
  def can?(_, _, _), do: {:error, :forbidden}

  defp check_queue_membership(labeler, queue, allowed_roles) do
    membership = Repo.get_by(QueueMembership,
      queue_id: queue.id,
      labeler_id: labeler.id,
      revoked_at: nil
    )

    cond do
      is_nil(membership) -> {:error, :not_member}
      membership.role not in allowed_roles -> {:error, :insufficient_permissions}
      not is_nil(membership.expires_at) and DateTime.compare(membership.expires_at, DateTime.utc_now()) == :lt ->
        {:error, :membership_expired}
      true -> :ok
    end
  end
end
```

**Plug Integration** (for Phoenix controllers):

```elixir
defmodule AnvilWeb.AuthorizePlug do
  import Plug.Conn

  def init(opts), do: opts

  def call(conn, action: action, resource: resource) do
    labeler = conn.assigns[:current_labeler]

    case Anvil.Auth.Abilities.can?(labeler, action, resource) do
      :ok -> conn
      {:error, reason} ->
        conn
        |> put_status(:forbidden)
        |> Phoenix.Controller.json(%{error: "Forbidden: #{reason}"})
        |> halt()
    end
  end
end

# Usage in controller
defmodule AnvilWeb.LabelController do
  plug AnvilWeb.AuthorizePlug, action: :submit_label, resource: :assignment when action == :create
end
```

### 4. Signed URLs for Assets

**Asset Access Flow**:

1. Labeler requests assignment → receives sample_id
2. Labeler requests asset URL → receives pre-signed S3 URL
3. Pre-signed URL expires after 1 hour
4. Access logged to audit trail

**Signed URL Generation**:

```elixir
defmodule Anvil.Assets do
  @doc """
  Generate signed URL for sample asset with audit logging.
  """
  def generate_asset_url(sample_id, labeler_id, opts \\ []) do
    # Verify labeler has access to queue containing this sample
    with {:ok, sample} <- ForgeBridge.fetch_sample(sample_id),
         {:ok, queue} <- get_queue_for_sample(sample_id),
         :ok <- Abilities.can?(labeler, :view_sample, queue) do

      # Generate pre-signed S3 URL
      expires_in = Keyword.get(opts, :expires_in, 3600)  # 1 hour default
      signed_url = ExAws.S3.presigned_url(s3_client(), :get, bucket(), sample.asset_key,
        expires_in: expires_in
      )

      # Audit log
      audit_log(:asset_accessed, %{
        labeler_id: labeler_id,
        sample_id: sample_id,
        asset_key: sample.asset_key,
        expires_at: DateTime.add(DateTime.utc_now(), expires_in, :second)
      })

      {:ok, signed_url}
    end
  end
end
```

**Alternative: Proxy Assets** (for tighter control):

```elixir
# Instead of signed URLs, proxy assets through Anvil HTTP endpoint
# Enables real-time revocation, bandwidth tracking, watermarking

defmodule AnvilWeb.AssetController do
  def show(conn, %{"sample_id" => sample_id}) do
    labeler = conn.assigns.current_labeler

    with {:ok, sample} <- ForgeBridge.fetch_sample(sample_id),
         :ok <- Abilities.can?(labeler, :view_sample, sample) do

      # Stream asset from S3 through Phoenix
      asset_stream = ExAws.S3.download_file(bucket(), sample.asset_key)

      audit_log(:asset_accessed, %{labeler_id: labeler.id, sample_id: sample_id})

      conn
      |> put_resp_header("content-type", sample.content_type)
      |> send_chunked(200)
      |> stream_asset(asset_stream)
    end
  end
end
```

### 5. Multi-Tenant Isolation

**Tenant Context Enforcement**:

```elixir
defmodule Anvil.TenantContext do
  @moduledoc """
  Ensures all queries are scoped to current tenant.
  """

  defmacro __using__(_opts) do
    quote do
      import Ecto.Query
      alias Anvil.TenantContext

      def all(query, tenant_id) do
        query
        |> TenantContext.scope_to_tenant(tenant_id)
        |> Repo.all()
      end

      def get!(query, id, tenant_id) do
        query
        |> TenantContext.scope_to_tenant(tenant_id)
        |> Repo.get!(id)
      end
    end
  end

  def scope_to_tenant(query, tenant_id) do
    from r in query, where: r.tenant_id == ^tenant_id
  end
end

# Usage
defmodule Anvil.Queues do
  use Anvil.TenantContext

  def list_queues(tenant_id) do
    Queue
    |> all(tenant_id)
  end
end
```

**Database-Level Enforcement** (via Postgres Row-Level Security):

```sql
-- Enable RLS on all tenant-scoped tables
ALTER TABLE queues ENABLE ROW LEVEL SECURITY;

-- Policy: Users can only access rows matching their tenant_id
CREATE POLICY tenant_isolation ON queues
USING (tenant_id = current_setting('app.current_tenant_id')::uuid);

-- Set tenant context per-connection
SET app.current_tenant_id = 'tenant_abc123';
```

**Connection Pooling** with Tenant Context:

```elixir
# Ecto adapter that sets tenant context on checkout
defmodule Anvil.Repo do
  use Ecto.Repo, otp_app: :anvil, adapter: Ecto.Adapters.Postgres

  def with_tenant(tenant_id, fun) do
    Repo.transaction(fn ->
      Repo.query!("SET LOCAL app.current_tenant_id = $1", [tenant_id])
      fun.()
    end)
  end
end

# Usage
Repo.with_tenant(tenant_id, fn ->
  Anvil.Queues.list_queues()  # Automatically filtered by RLS
end)
```

### 6. Audit Logging

**Audit Log Table**:

```elixir
schema "audit_logs" do
  field :tenant_id, :binary_id
  field :actor_id, :binary_id  # Labeler or service account ID
  field :actor_type, Ecto.Enum, values: [:labeler, :service_account, :system]
  field :action, :string  # "assignment_requested", "label_submitted", "asset_accessed"
  field :resource_type, :string  # "queue", "assignment", "label", "sample"
  field :resource_id, :binary_id
  field :metadata, :map  # Action-specific details
  field :ip_address, :string
  field :user_agent, :string
  field :occurred_at, :utc_datetime

  timestamps(updated_at: false)
end
```

**Audit Macro**:

```elixir
defmodule Anvil.Audit do
  def log(action, attrs) do
    %AuditLog{}
    |> AuditLog.changeset(attrs)
    |> Repo.insert()

    # Also emit telemetry
    :telemetry.execute([:anvil, :audit, action], %{}, attrs)
  end
end

# Usage
Audit.log(:label_submitted, %{
  actor_id: labeler.id,
  actor_type: :labeler,
  resource_type: "label",
  resource_id: label.id,
  metadata: %{queue_id: queue.id, agreement_score: 0.85},
  ip_address: conn.remote_ip,
  occurred_at: DateTime.utc_now()
})
```

**Compliance Queries**:

```elixir
# Who accessed sample X?
def list_sample_accesses(sample_id) do
  from(a in AuditLog,
    where: a.resource_id == ^sample_id and a.action == "asset_accessed",
    order_by: [desc: a.occurred_at]
  )
  |> Repo.all()
end

# What actions did labeler Y perform?
def list_labeler_actions(labeler_id, since: since) do
  from(a in AuditLog,
    where: a.actor_id == ^labeler_id and a.occurred_at > ^since,
    order_by: [desc: a.occurred_at]
  )
  |> Repo.all()
end
```

## Consequences

### Positive

- **Compliance-Ready**: RBAC + audit logging satisfy SOC 2, ISO 27001, HIPAA requirements
- **Multi-Tenancy Support**: Tenant isolation enables SaaS deployment for multiple organizations
- **Least Privilege**: Default-deny access model reduces attack surface and accidental data exposure
- **Flexibility**: Queue membership model supports diverse access patterns (private, restricted, public)
- **Identity Integration**: OIDC support enables SSO with existing corporate identity providers
- **Auditability**: Comprehensive audit logs support compliance audits and security investigations
- **Asset Security**: Signed URLs with expiration prevent long-lived asset links from leaking

### Negative

- **Complexity**: Multi-layered authorization (roles, memberships, ACLs) increases cognitive load for developers
- **Performance Overhead**: Authorization checks on every query add latency (~1-5ms per check)
- **Database Load**: Postgres RLS adds query planning overhead; may impact high-throughput workloads
- **Migration Risk**: Retrofitting access control to existing deployments requires data migration
- **Testing Burden**: Authorization matrix (roles × actions × resources) requires extensive test coverage
- **User Friction**: Queue membership approval workflows slow onboarding for urgent labeling needs

### Neutral

- **Platform Admin Role**: Cross-tenant access for NSAI operators should be heavily audited and MFA-protected
- **Anonymous Access**: Public queues for crowdsourcing deferred until specific use case emerges
- **Fine-Grained Permissions**: Future consideration for sample-level ACLs (e.g., labeler can only see samples matching criteria)
- **Rate Limiting**: Consider per-labeler rate limits for API endpoints to prevent abuse
- **Session Management**: OIDC tokens should be short-lived (15 min); refresh token rotation for security

## Implementation Notes

1. **OIDC Library Selection**:
   - Use `oidcc` or `openid_connect` for OIDC flows
   - Support multiple providers (Auth0, Okta, Keycloak, Google) via configuration
   - Implement token caching to reduce IdP load

2. **Postgres RLS vs Application-Level**:
   - **RLS Pros**: Defense-in-depth, works even if app code has bugs
   - **RLS Cons**: Harder to debug, potential performance issues
   - **Recommendation**: Start with application-level, add RLS for high-security tenants

3. **Audit Log Retention**:
   - Default 7-year retention for compliance (matches typical audit requirements)
   - Partition audit_logs by month for query performance
   - Archive to cold storage (S3 Glacier) after 1 year

4. **Testing Strategy**:
   - Permission matrix test: Assert each role × action combination
   - Tenant isolation test: Verify queries never leak cross-tenant data
   - Audit completeness test: Every state-changing action must produce audit log

5. **Telemetry Events**:
   ```elixir
   :telemetry.execute([:anvil, :auth, :login_success], %{}, %{labeler_id: id})
   :telemetry.execute([:anvil, :auth, :access_denied], %{}, %{reason: :not_member})
   :telemetry.execute([:anvil, :audit, :asset_accessed], %{}, %{sample_id: id})
   ```

6. **CLI Commands**:
   ```bash
   # Grant queue access
   mix anvil.queue.grant --queue=cns_synthesis --labeler=user@example.com --role=labeler

   # Revoke access
   mix anvil.queue.revoke --queue=cns_synthesis --labeler=user@example.com

   # List queue members
   mix anvil.queue.members --queue=cns_synthesis

   # Audit report
   mix anvil.audit.report --labeler=user@example.com --since=2025-12-01
   ```

7. **Performance Targets**:
   - Authorization check: <5ms p99 (includes DB query for membership)
   - Signed URL generation: <50ms (includes S3 API call)
   - Audit log write: async, <10ms (fire-and-forget to queue)

8. **Security Hardening**:
   - API keys: bcrypt hash with high cost factor (12+)
   - OIDC tokens: Verify signature, issuer, audience, expiration
   - Audit logs: Immutable (no updates/deletes except retention sweep)
   - Rate limiting: 100 requests/min per labeler for assignment requests
