# Anvil Architecture Decision Records (ADRs)

This directory contains Architecture Decision Records documenting key technical decisions for the Anvil labeling queue system.

## Quick Reference

| ADR | Title | Status | Summary |
|-----|-------|--------|---------|
| [001](./001-postgres-storage-adapter.md) | Postgres Storage Adapter | Accepted | Production-grade persistence with Ecto, multi-tenancy support, shared cluster with Forge |
| [002](./002-assignment-policies.md) | Assignment Policy Engine | Accepted | Composable policies for fair distribution, expertise routing, redundancy, timeouts |
| [003](./003-schema-versioning.md) | Schema Versioning and Evolution | Accepted | Immutable schema versions, forward-only migrations, transform callbacks for reproducibility |
| [004](./004-agreement-computation.md) | Inter-Rater Agreement Computation | Accepted | Online/batch agreement metrics (Cohen's κ, Fleiss' κ, Krippendorff's α), per-dimension analysis |
| [005](./005-export-system.md) | Export System with Deterministic Lineage | Accepted | CSV/JSONL/HuggingFace exports, deterministic ordering, version pinning, manifest generation |
| [006](./006-pii-and-redaction.md) | PII Handling and Redaction Policies | Accepted | Schema-level PII annotations, export-time redaction, labeler pseudonymization, GDPR compliance |
| [007](./007-auth-and-acls.md) | Authentication and Access Control | Accepted | RBAC with queue memberships, OIDC integration, signed asset URLs, multi-tenant isolation |
| [008](./008-telemetry-integration.md) | Telemetry Integration and Observability | Accepted | :telemetry events, StatsD/OpenTelemetry export, Foundation/AITrace integration, alerting |
| [009](./009-background-jobs.md) | Background Job Management with Oban | Accepted | Postgres-backed job queue for timeouts, exports, agreement recompute, retention sweeps |
| [010](./010-forge-integration.md) | Forge Integration and Sample Management | Accepted | ForgeBridge abstraction, sample version pinning, DTO layer, caching, circuit breaking |

## Decision Categories

### Storage & Persistence
- **ADR-001**: Postgres adapter with Ecto schemas, optimistic locking, multi-tenancy
- **ADR-009**: Oban job queue for background processing

### Workflow & Quality
- **ADR-002**: Assignment policies (round-robin, weighted expertise, redundancy, concurrency limits)
- **ADR-004**: Inter-rater reliability metrics with automatic metric selection

### Data Management
- **ADR-003**: Schema versioning with immutability and transform migrations
- **ADR-005**: Deterministic exports with format adapters and lineage tracking
- **ADR-006**: PII protection with field annotations and retention policies

### Security & Compliance
- **ADR-006**: GDPR compliance (right-to-erasure, retention sweeps, pseudonymization)
- **ADR-007**: RBAC, queue ACLs, OIDC authentication, signed URLs

### Operations & Integration
- **ADR-008**: Comprehensive telemetry with StatsD, OpenTelemetry, and custom dashboards
- **ADR-010**: Forge integration with pluggable backends and fault tolerance

## Key Architectural Principles

1. **Reproducibility First**: Schema versioning (ADR-003), sample version pinning (ADR-010), deterministic exports (ADR-005)
2. **Privacy by Design**: PII annotations (ADR-006), pseudonymization (ADR-006), export redaction (ADR-006)
3. **Quality Assurance**: Agreement metrics (ADR-004), assignment policies (ADR-002), telemetry (ADR-008)
4. **Operational Excellence**: Background jobs (ADR-009), observability (ADR-008), fault tolerance (ADR-010)
5. **Flexibility**: Pluggable policies (ADR-002), multiple export formats (ADR-005), configurable backends (ADR-001, ADR-010)

## Technology Stack Summary

| Component | Technology | ADR Reference |
|-----------|------------|---------------|
| **Database** | Postgres with Ecto | ADR-001 |
| **Job Queue** | Oban (Postgres-backed) | ADR-009 |
| **Telemetry** | :telemetry + TelemetryMetrics | ADR-008 |
| **Authentication** | OIDC (Auth0, Okta, Keycloak) | ADR-007 |
| **Caching** | Cachex (in-memory) | ADR-010 |
| **Tracing** | OpenTelemetry (OTLP) | ADR-008 |
| **HTTP Client** | HTTPoison + Fuse | ADR-010 |
| **Asset Storage** | S3/MinIO (pre-signed URLs) | ADR-007 |

## Integration Points

### NSAI Platform Services

- **Forge**: Sample management (ADR-010)
  - Shared Postgres cluster (separate schemas)
  - Foreign key references or HTTP API
  - Sample version pinning for reproducibility

- **Foundation**: Metrics aggregation (ADR-008)
  - :telemetry event forwarding
  - Unified monitoring across monorepo

- **AITrace**: Dataset lineage (ADR-005, ADR-010)
  - Export manifest registration
  - Full provenance tracking (samples → labels → datasets)

- **Ingot**: UI client (mentioned in buildout plan)
  - Phoenix LiveView subscriptions to telemetry events
  - Real-time progress tracking for exports

## Implementation Roadmap

Following the work packages from the buildout plan:

1. **Storage v1** → ADR-001: Postgres schemas, migrations, Ecto repo
2. **Assignment Engine** → ADR-002: Policies, timeouts, requeues, audit logging
3. **Schema Versioning** → ADR-003: Immutable versions, migration helpers
4. **Telemetry** → ADR-008: Event emission, metrics dashboards
5. **Exports** → ADR-005: Format adapters, manifests, deterministic ordering
6. **Agreement** → ADR-004: Online + batch computation, per-dimension metrics
7. **Security** → ADR-006, ADR-007: Auth model, ACLs, PII handling
8. **Bridges** → ADR-010: Forge integration, sample resolution
9. **Background Jobs** → ADR-009: Oban setup, cron scheduling

## Reading Guide

### For New Engineers
Start with:
1. ADR-001 (storage foundation)
2. ADR-002 (assignment workflow)
3. ADR-008 (observability)

### For Security Audits
Focus on:
1. ADR-006 (PII and redaction)
2. ADR-007 (authentication and ACLs)
3. ADR-005 (export integrity)

### For Research Scientists
Review:
1. ADR-003 (schema evolution)
2. ADR-004 (agreement metrics)
3. ADR-005 (reproducible exports)
4. ADR-010 (sample versioning)

### For Platform Operators
Essential:
1. ADR-008 (telemetry and alerting)
2. ADR-009 (background jobs)
3. ADR-001 (database architecture)
4. ADR-010 (service integration)

## Document Format

All ADRs follow the standard format:

```markdown
# ADR-NNN: Title

## Status
Proposed | Accepted | Deprecated | Superseded

## Context
[Problem statement and requirements]

## Decision
[Solution with technical details]

## Consequences
### Positive
### Negative
### Neutral

## Implementation Notes
[Practical guidance for engineers]
```

## Questions or Feedback

For questions about these decisions:
- Open an issue in the NSAI monorepo
- Discuss in #anvil-dev Slack channel
- Contact the platform team

Last Updated: 2025-12-01
