# ADR-001: Postgres Storage Adapter

## Status
Accepted

## Context

Anvil v0.1 relies exclusively on ETS-based storage, which provides fast in-memory operations but lacks durability, multi-tenancy support, and reproducibility guarantees essential for production ML labeling workflows. The current implementation loses all queue state on application restart, cannot support cross-instance coordination, and provides no audit trail for regulatory compliance or dataset lineage tracking.

As Anvil scales to support CNS experiments and broader NSAI data collection workflows, we need:
- **Durability**: Labels and assignments must survive restarts and be recoverable for dataset reconstruction
- **Multi-tenancy**: Isolation between organizations/experiments while sharing infrastructure
- **Lineage**: Immutable audit logs linking labels to schema versions and sample versions
- **Concurrency**: Safe distributed access patterns for multiple labeling UIs and background jobs
- **Integration**: Shared data layer with Forge (sample management) to avoid service sprawl

The choice of storage backend fundamentally shapes system reliability, operational complexity, and integration patterns with the broader NSAI platform.

## Decision

We will implement `Anvil.Storage.Postgres` as the primary production storage adapter alongside the existing ETS adapter (retained for testing). The Postgres implementation will:

### Schema Design

**Core Tables:**

1. **queues**
   - `id` (UUID, PK)
   - `tenant_id` (UUID, nullable for single-tenant deployments)
   - `name` (text, indexed)
   - `schema_version_id` (UUID, FK to schema_versions)
   - `policy` (jsonb, serialized policy configuration)
   - `status` (enum: active, paused, archived)
   - `created_at`, `updated_at` (timestamptz)
   - Unique constraint: `(tenant_id, name)` for named queue lookups

2. **assignments**
   - `id` (UUID, PK)
   - `queue_id` (UUID, FK to queues)
   - `sample_id` (UUID, FK to Forge samples via foreign key or logical reference)
   - `labeler_id` (UUID, FK to labelers)
   - `status` (enum: pending, reserved, completed, timed_out, requeued)
   - `reserved_at` (timestamptz, nullable)
   - `deadline` (timestamptz, nullable, computed as reserved_at + timeout)
   - `timeout_seconds` (integer, policy-derived)
   - `version` (integer, for optimistic locking)
   - `created_at`, `updated_at` (timestamptz)
   - Indexes:
     - `(queue_id, status)` for dispatch queries
     - `(labeler_id, status)` for per-labeler workload views
     - `(deadline)` for timeout sweeps where status = 'reserved'
     - `(created_at)` for chronological ordering

3. **labels**
   - `id` (UUID, PK)
   - `assignment_id` (UUID, FK to assignments)
   - `labeler_id` (UUID, FK to labelers, denormalized for query efficiency)
   - `schema_version_id` (UUID, FK to schema_versions, immutable once written)
   - `payload` (jsonb, validated against schema)
   - `blob_pointer` (text, nullable, S3/MinIO key for large attachments)
   - `submitted_at` (timestamptz)
   - `created_at` (timestamptz)
   - Index: `(schema_version_id)` for export queries

4. **labelers**
   - `id` (UUID, PK)
   - `tenant_id` (UUID, nullable)
   - `external_id` (text, OIDC sub or internal user ID)
   - `pseudonym` (text, generated for PII-safe exports)
   - `expertise_weights` (jsonb, nullable, for weighted assignment policies)
   - `blocklisted_queues` (UUID[], nullable, for per-labeler exclusions)
   - `max_concurrent_assignments` (integer, default 5)
   - `created_at`, `updated_at` (timestamptz)
   - Unique constraint: `(tenant_id, external_id)`

5. **schema_versions**
   - `id` (UUID, PK)
   - `queue_id` (UUID, FK to queues)
   - `version_number` (integer, sequential within queue)
   - `schema_definition` (jsonb, JSON schema or Ecto embedded schema)
   - `transform_from_previous` (text, nullable, Elixir module name for migrations)
   - `frozen_at` (timestamptz, nullable, set when first label written)
   - `created_at` (timestamptz)
   - Unique constraint: `(queue_id, version_number)`
   - Immutability: Once `frozen_at` is set, schema_definition becomes read-only

6. **samples**
   - **Option A (Preferred)**: Foreign key reference to Forge's samples table
     - `id` (UUID, PK, matches Forge sample ID)
     - `forge_sample_id` (UUID, FK to forge.samples(id))
     - Minimal denormalization for query optimization
   - **Option B**: Logical reference only
     - Store `sample_id` UUID in assignments, resolve via `ForgeBridge` at runtime
     - Avoids tight coupling but complicates transactional guarantees

7. **audit_logs**
   - `id` (UUID, PK)
   - `tenant_id` (UUID, nullable)
   - `entity_type` (enum: queue, assignment, label, labeler)
   - `entity_id` (UUID)
   - `action` (enum: created, updated, deleted, accessed)
   - `actor_id` (UUID, FK to labelers, nullable for system actions)
   - `metadata` (jsonb, action-specific details)
   - `occurred_at` (timestamptz)
   - Indexes:
     - `(entity_type, entity_id)` for entity history
     - `(occurred_at)` for time-based retention sweeps
     - `(tenant_id)` for multi-tenant isolation

### Concurrency & Safety

- **Optimistic Locking**: `assignments.version` incremented on every update; conflicting updates fail with Ecto.StaleEntryError
- **Deadline Enforcement**: `deadline` computed as `reserved_at + timeout_seconds`; background Oban job sweeps expired reservations
- **Idempotency**: Label submission checks for existing `(assignment_id, labeler_id)` pairs to prevent duplicate submissions

### Database Configuration

- **Shared Cluster**: Deploy in same Postgres cluster as Forge using separate schema (`anvil` schema vs `forge` schema)
- **Connection Pooling**: Use Ecto connection pool with size tuned for expected concurrency (recommend 20-50 connections)
- **Foreign Keys**: Cross-schema foreign key from `anvil.samples` to `forge.samples` if using Option A
- **Migrations**: Standard Ecto migrations in `priv/repo/migrations/`

### Adapter Interface

Implement existing `Anvil.Storage` behaviour:

```elixir
defmodule Anvil.Storage.Postgres do
  @behaviour Anvil.Storage

  @impl true
  def create_queue(attrs, opts), do: # Ecto insert into queues table

  @impl true
  def next_assignment(queue_id, labeler_id, opts), do: # Transaction with optimistic lock

  @impl true
  def submit_label(assignment_id, payload, opts), do: # Insert label + audit log + update assignment

  @impl true
  def compute_agreement(queue_id, opts), do: # Query labels grouped by sample_id
end
```

Configuration in application.ex:

```elixir
config :anvil, Anvil.Storage,
  adapter: Anvil.Storage.Postgres,
  repo: Anvil.Repo
```

## Consequences

### Positive

- **Durability**: All labeling work persists across restarts; dataset exports remain reproducible indefinitely
- **Audit Compliance**: Immutable audit logs satisfy regulatory requirements (GDPR, 21 CFR Part 11) for research data provenance
- **Multi-Tenancy**: Tenant isolation at database level enables SaaS deployment model for NSAI platform
- **Scalability**: Postgres handles millions of labels with proper indexing; read replicas support analytics workloads
- **Integration**: Shared cluster with Forge reduces operational burden (single backup/restore, unified monitoring)
- **Concurrency**: Optimistic locking enables safe distributed labeling without distributed locks or consensus protocols
- **Lineage**: Schema version pinning creates immutable snapshot references for reproducible dataset exports
- **Ecosystem**: Ecto provides battle-tested migration tooling, query composition, and connection pooling

### Negative

- **Operational Complexity**: Requires Postgres instance management (backups, replication, monitoring) vs pure ETS
- **Latency**: Network round-trips add ~1-5ms vs in-memory ETS reads (acceptable for human-in-loop labeling workflows)
- **Migration Risk**: Schema changes require coordinated deployments and careful data migrations
- **Cost**: Managed Postgres (RDS/Cloud SQL) has ongoing cost vs free in-memory storage
- **Coupling**: Shared cluster with Forge means database incidents affect both services (mitigated by separate schemas)
- **Complexity**: Developers must understand Ecto, migrations, and SQL query optimization

### Neutral

- **ETS Adapter Retained**: Keep existing ETS adapter for unit tests and local development (fast, no dependencies)
- **Optional Blob Store**: Large label payloads (images, videos) stored in S3/MinIO with pointers in labels table; defer until needed
- **Replica Strategy**: Read replicas for analytics deferred until query volume justifies; start with single writer instance
- **Partitioning**: Table partitioning by tenant_id or created_at deferred until tables exceed ~100M rows

## Implementation Notes

1. **Forge Integration Decision Required**: Choose Option A (foreign key) vs Option B (logical reference) based on deployment topology
   - If Forge + Anvil share Postgres cluster: Use Option A for transactional consistency
   - If separate databases: Use Option B with eventual consistency via event bridge

2. **Migration Path**: Provide `Anvil.Storage.Migrator` to export ETS state to Postgres for existing deployments

3. **Testing Strategy**:
   - Shared test suite against `Anvil.Storage` behaviour runs on both ETS and Postgres
   - Postgres-specific tests for concurrency scenarios, deadlines, audit logs
   - Integration tests with Forge for foreign key validation

4. **Performance Targets**:
   - Assignment dispatch: <50ms p99 (includes optimistic lock retry)
   - Label submission: <100ms p99 (includes audit log write + agreement trigger)
   - Export query: <5s for 100k labels with pagination

5. **Monitoring**:
   - Emit :telemetry events for query durations, lock conflicts, timeout sweep counts
   - Alert on high optimistic lock retry rates (indicates assignment contention)
   - Track audit log growth rate for retention planning
