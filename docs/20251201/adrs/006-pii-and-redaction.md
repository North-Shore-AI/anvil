# ADR-006: PII Handling and Redaction Policies

## Status
Accepted

## Context

Labeling workflows often handle sensitive data subject to privacy regulations and ethical research standards:

**Personal Identifiable Information (PII)**:
- Labeler identities (names, emails, IP addresses)
- Sample content (medical records, customer support transcripts, social media posts)
- Free-text notes containing accidental PII mentions

**Regulatory Requirements**:
- **GDPR** (EU): Right to erasure (Article 17), data minimization (Article 5), purpose limitation
- **HIPAA** (US): Protected Health Information (PHI) de-identification requirements
- **CCPA** (California): Consumer data deletion requests within 45 days
- **Ethics Boards**: University IRBs require anonymized datasets for research publications

**Retention Policies**:
- **Research Archives**: Long-term retention (10+ years) for reproducibility
- **Operational Data**: Short-term retention (90 days) for quality monitoring
- **Compliance Exports**: GDPR data subject access requests require complete history

**Anonymization Challenges**:
- **Re-identification Risk**: Combining "anonymized" labels with public data can reveal identities
- **Pseudonymization**: Consistent labeler IDs needed for agreement analysis while protecting privacy
- **Export-Time Redaction**: Research datasets must strip PII while preserving analytical value
- **Right to Erasure**: Deleting labels breaks dataset reproducibility and agreement metrics

Current Anvil v0.1 has no PII protection mechanisms:
- Labeler IDs are raw UUIDs from identity provider (potentially linkable to real users)
- No field-level PII annotations or redaction policies
- No retention sweeps or automated deletion
- Exports include full labeler metadata by default

Without systematic PII handling, teams face compliance violations, ethics board rejections, and security incidents.

## Decision

We will implement multi-layered PII protection: schema-level field annotations, export-time redaction, labeler pseudonymization, and automated retention sweeps.

### 1. Schema-Level PII Annotations

**Field Metadata** in schema definitions:

```elixir
defmodule Anvil.Schema.CNSSynthesisV1 do
  use Ecto.Schema

  embedded_schema do
    field :coherence, :boolean, metadata: [pii: false, retention_days: :indefinite]
    field :grounded, :boolean, metadata: [pii: false, retention_days: :indefinite]
    field :notes, :string, metadata: [
      pii: :possible,  # May contain accidental PII
      retention_days: 365,
      redaction_policy: :truncate_on_export
    ]
    field :labeler_comments, :string, metadata: [
      pii: :likely,  # Often contains personal opinions/identifiers
      retention_days: 90,
      redaction_policy: :strip_on_export
    ]
  end
end

# Schema version JSONB storage:
{
  "fields": {
    "notes": {
      "type": "string",
      "pii": "possible",
      "retention_days": 365,
      "redaction_policy": "truncate_on_export"
    }
  }
}
```

**PII Levels**:
- `:none` - No PII expected (e.g., boolean labels, enums)
- `:possible` - May contain PII (free-text fields with guidelines to avoid PII)
- `:likely` - Expected to contain PII (e.g., labeler feedback, error reports)
- `:definite` - Always contains PII (e.g., labeler email, IP address)

**Retention Policies**:
- `:indefinite` - Keep forever (structural labels with no PII)
- `<integer>` - Days until eligible for deletion (e.g., 90, 365)
- Retention clock starts from `label.submitted_at`

### 2. Export-Time Redaction Policies

**Policy Types**:

```elixir
defmodule Anvil.Export.Redaction do
  @moduledoc """
  Redaction policies applied during export based on field PII annotations.
  """

  def apply_policy(field_value, policy, opts \\ [])

  # Strip field entirely
  def apply_policy(_value, :strip_on_export, _opts), do: nil

  # Truncate to first N characters
  def apply_policy(value, :truncate_on_export, opts) do
    max_length = Keyword.get(opts, :max_length, 100)
    String.slice(value, 0, max_length)
  end

  # Hash value (preserves uniqueness for grouping, not readability)
  def apply_policy(value, :hash_on_export, _opts) do
    :crypto.hash(:sha256, value) |> Base.encode16(case: :lower)
  end

  # Regex-based redaction (e.g., email addresses, phone numbers)
  def apply_policy(value, :regex_redact, opts) do
    patterns = Keyword.get(opts, :patterns, default_pii_patterns())
    Enum.reduce(patterns, value, fn {pattern, replacement}, acc ->
      Regex.replace(pattern, acc, replacement)
    end)
  end

  # Preserve field unchanged (explicit opt-in)
  def apply_policy(value, :preserve, _opts), do: value

  defp default_pii_patterns do
    [
      {~r/\b[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Z|a-z]{2,}\b/, "[EMAIL_REDACTED]"},
      {~r/\b\d{3}-\d{2}-\d{4}\b/, "[SSN_REDACTED]"},  # US SSN
      {~r/\b\d{3}-\d{3}-\d{4}\b/, "[PHONE_REDACTED]"}
    ]
  end
end
```

**Export Integration**:

```elixir
defmodule Anvil.Export.CSV do
  def to_format(queue_id, opts) do
    schema_version = load_schema_version(opts[:schema_version_id])
    redaction_mode = Keyword.get(opts, :redaction_mode, :automatic)

    labels_stream = stream_labels(queue_id, opts)
    |> Stream.map(&apply_redactions(&1, schema_version, redaction_mode))

    write_csv(labels_stream, output_path)
  end

  defp apply_redactions(label, schema_version, redaction_mode) do
    case redaction_mode do
      :none ->
        # No redaction (for trusted internal exports)
        label

      :automatic ->
        # Apply schema-defined redaction policies
        redacted_payload = Enum.reduce(label.payload, %{}, fn {field, value}, acc ->
          policy = get_field_policy(schema_version, field)
          redacted_value = Redaction.apply_policy(value, policy)
          Map.put(acc, field, redacted_value)
        end)
        %{label | payload: redacted_payload}

      :aggressive ->
        # Strip all PII-possible and above fields
        redacted_payload = Enum.reduce(label.payload, %{}, fn {field, value}, acc ->
          pii_level = get_field_pii_level(schema_version, field)
          if pii_level in [:none], do: Map.put(acc, field, value), else: acc
        end)
        %{label | payload: redacted_payload}
    end
  end
end
```

**Export Modes**:
```elixir
# No redaction (internal analytics, requires authorization)
Anvil.Export.to_csv(queue_id, %{redaction_mode: :none})

# Automatic (schema-defined policies)
Anvil.Export.to_csv(queue_id, %{redaction_mode: :automatic})

# Aggressive (strip all possible PII)
Anvil.Export.to_csv(queue_id, %{redaction_mode: :aggressive})
```

### 3. Labeler Pseudonymization

**Problem**: Labeler UUIDs from identity provider (e.g., OIDC `sub` claim) may be linkable to real users via other systems.

**Solution**: Generate stable pseudonyms at labeler creation:

```elixir
defmodule Anvil.Labelers do
  def create_labeler(attrs) do
    pseudonym = generate_pseudonym(attrs.external_id, attrs.tenant_id)

    %Labeler{}
    |> changeset(attrs)
    |> put_change(:pseudonym, pseudonym)
    |> Repo.insert()
  end

  defp generate_pseudonym(external_id, tenant_id) do
    # HMAC-based pseudonym: stable per-tenant, unlinkable across tenants
    secret = Application.fetch_env!(:anvil, :pseudonym_secret)
    payload = "#{tenant_id}:#{external_id}"

    hash = :crypto.mac(:hmac, :sha256, secret, payload)
    |> Base.encode16(case: :lower)
    |> String.slice(0..15)

    "labeler_#{hash}"
  end
end

# Labelers table:
# id: internal UUID (never exported)
# external_id: OIDC sub or internal user ID (admin-only)
# pseudonym: "labeler_a1b2c3d4e5f6g7h8" (exported in datasets)
```

**Export Behavior**:
```elixir
# Always export pseudonym, never external_id or internal UUID
def encode_label_for_export(label) do
  labeler = Repo.get!(Labeler, label.labeler_id)

  %{
    sample_id: label.sample_id,
    labeler: labeler.pseudonym,  # "labeler_a1b2..."
    payload: label.payload,
    submitted_at: label.submitted_at
  }
end
```

**Re-identification Protection**:
- Pseudonyms are stable within tenant (same labeler always gets same pseudonym)
- Different tenants get different pseudonyms for same external_id (prevents cross-tenant linking)
- Secret rotation: When `pseudonym_secret` rotates, regenerate all pseudonyms (breaking old exports)

### 4. Time-Based Retention Sweeps

**Oban Job** for automated deletion:

```elixir
defmodule Anvil.Jobs.RetentionSweep do
  use Oban.Worker, queue: :anvil_maintenance

  @impl Oban.Worker
  def perform(_job) do
    # Find labels past retention period
    expired_labels = find_expired_labels()

    # Redact or delete based on policy
    for label <- expired_labels do
      schema_version = Repo.get!(SchemaVersion, label.schema_version_id)
      handle_expired_label(label, schema_version)
    end

    :ok
  end

  defp find_expired_labels do
    # Query labels where field retention period has elapsed
    # Complex: different fields have different retention periods

    # Simplified: Delete entire label if ANY field is expired
    # (More conservative: keep label, redact only expired fields)

    now = DateTime.utc_now()

    from(l in Label,
      join: sv in SchemaVersion, on: l.schema_version_id == sv.id,
      where: fragment("EXISTS (
        SELECT 1 FROM jsonb_each_text(?::jsonb) AS field
        WHERE (? -> field.key ->> 'retention_days')::int IS NOT NULL
        AND ? + (? -> field.key ->> 'retention_days')::int * interval '1 day' < ?
      )", sv.schema_definition, sv.schema_definition, l.submitted_at, sv.schema_definition, ^now)
    )
    |> Repo.all()
  end

  defp handle_expired_label(label, schema_version) do
    case schema_version.retention_action do
      :hard_delete ->
        # Permanent deletion (breaks reproducibility)
        Repo.delete!(label)

      :soft_delete ->
        # Tombstone: keep metadata, strip payload
        Label.changeset(label, %{
          payload: %{},
          deleted_at: DateTime.utc_now(),
          deletion_reason: "retention_policy"
        })
        |> Repo.update!()

      :field_redaction ->
        # Redact only expired fields, keep unexpired
        redacted_payload = redact_expired_fields(label.payload, schema_version)
        Label.changeset(label, %{payload: redacted_payload})
        |> Repo.update!()
    end
  end
end
```

**Scheduling**:
```elixir
# config/config.exs
config :anvil, Oban,
  queues: [anvil_maintenance: 1],
  plugins: [
    {Oban.Plugins.Cron,
     crontab: [
       {"0 2 * * *", Anvil.Jobs.RetentionSweep}  # Daily at 2 AM
     ]}
  ]
```

### 5. Right-to-Erasure Support

**GDPR Article 17 Compliance**:

```elixir
defmodule Anvil.GDPR do
  @doc """
  Erase all data for a specific labeler (GDPR right to erasure).
  WARNING: Breaks dataset reproducibility and agreement metrics.
  """
  def erase_labeler(labeler_id, opts \\ []) do
    labeler = Repo.get!(Labeler, labeler_id)

    # Log erasure request for audit
    audit_log(:right_to_erasure_requested, labeler_id, opts)

    # Strategy 1: Hard delete (GDPR compliant but destructive)
    if Keyword.get(opts, :hard_delete, false) do
      Repo.transaction(fn ->
        # Delete labels
        from(l in Label, where: l.labeler_id == ^labeler_id) |> Repo.delete_all()

        # Delete assignments
        from(a in Assignment, where: a.labeler_id == ^labeler_id) |> Repo.delete_all()

        # Anonymize labeler record (keep for foreign key integrity)
        Labeler.changeset(labeler, %{
          external_id: "REDACTED_#{labeler.id}",
          pseudonym: "REDACTED_#{labeler.id}",
          deleted_at: DateTime.utc_now()
        })
        |> Repo.update!()

        # Invalidate affected agreement metrics
        invalidate_agreement_metrics(labeler_id)
      end)
    else
      # Strategy 2: Pseudonymization (preserves dataset utility)
      # Replace labeler pseudonym with random ID, keeping labels
      new_pseudonym = "anonymous_#{:crypto.strong_rand_bytes(8) |> Base.encode16()}"

      Labeler.changeset(labeler, %{
        external_id: "ANONYMOUS",
        pseudonym: new_pseudonym,
        anonymized_at: DateTime.utc_now()
      })
      |> Repo.update!()
    end

    audit_log(:right_to_erasure_completed, labeler_id, opts)
  end
end
```

**Impact Assessment**:
- Hard deletion: Breaks reproducibility of exports, invalidates agreement metrics
- Pseudonymization: Preserves dataset utility, may not satisfy strict GDPR interpretation
- Recommendation: Pseudonymization by default, hard delete only upon explicit user request

### 6. Audit Metadata for Exports

**Export manifest includes redaction metadata**:

```json
{
  "export_id": "exp_abc123",
  "queue_id": "queue_xyz",
  "redaction_mode": "automatic",
  "redacted_fields": ["notes", "labeler_comments"],
  "redaction_policies": {
    "notes": "truncate_on_export",
    "labeler_comments": "strip_on_export"
  },
  "labeler_pseudonyms": true,
  "pii_risk_assessment": "low",
  "exported_at": "2025-12-01T15:00:00Z",
  "data_classification": "research_public"
}
```

**Signed Attestation** (for compliance exports):
```elixir
defmodule Anvil.Export.Attestation do
  def sign_manifest(manifest, signer_id) do
    payload = Jason.encode!(manifest)
    signature = sign_payload(payload, get_signing_key())

    %{
      manifest: manifest,
      attestation: %{
        signer_id: signer_id,
        signed_at: DateTime.utc_now(),
        signature: signature,
        statement: "I attest that this export complies with GDPR redaction requirements."
      }
    }
  end

  defp sign_payload(payload, private_key) do
    :public_key.sign(payload, :sha256, private_key)
    |> Base.encode64()
  end
end
```

## Consequences

### Positive

- **GDPR Compliance**: Right-to-erasure support and field-level retention policies satisfy EU privacy requirements
- **Ethics Board Approval**: Pseudonymization and PII redaction enable academic research publication
- **Security Defense-in-Depth**: Multiple layers (schema annotations, export redaction, pseudonyms) reduce data breach risk
- **Flexibility**: Configurable redaction modes (none/automatic/aggressive) balance utility vs privacy for different use cases
- **Automation**: Oban retention sweeps eliminate manual data cleanup tasks
- **Auditability**: Export manifests and attestations provide compliance evidence for regulators

### Negative

- **Reproducibility Tension**: Hard deletion for right-to-erasure breaks dataset lineage and agreement recomputation
- **Complexity**: Multiple redaction policies, retention periods, and pseudonymization layers increase system complexity
- **Performance Overhead**: Retention sweeps scanning large label tables may cause DB load; requires careful indexing
- **False Security**: Regex-based PII redaction is fragile (e.g., misses "email at domain dot com"); requires human review
- **Schema Burden**: Annotating every field with PII level and retention policy adds design overhead
- **Testing Difficulty**: Validating redaction correctness requires manual inspection of exports; hard to automate

### Neutral

- **Re-identification Risk**: Even pseudonymized datasets can be re-identified via linkage attacks; consider differential privacy for high-risk data
- **Regulatory Uncertainty**: GDPR interpretation varies by data protection authority; pseudonymization may not satisfy all jurisdictions
- **Export Warnings**: Exports with redaction_mode=:none should display prominent warnings about PII inclusion
- **Labeler Consent**: Terms of service should inform labelers that pseudonymized labels may be published in research datasets
- **Encryption at Rest**: PII fields should use database-level encryption (e.g., Postgres `pgcrypto`) for added protection

## Implementation Notes

1. **PII Detection Libraries**:
   - Consider `ex_pii_scanner` or integrate with external PII detection APIs (AWS Macie, Google DLP)
   - Flag fields with detected PII for manual review

2. **Differential Privacy** (future work):
   ```elixir
   # Add Laplace noise to aggregate statistics
   def export_with_privacy(queue_id, epsilon: 1.0) do
     # Standard differential privacy mechanisms
     # Deferred until specific use case emerges
   end
   ```

3. **Testing Strategy**:
   - Golden file tests: Verify redacted exports match expected output
   - Property test: Redacted fields should never contain regex-matched PII patterns
   - Integration test: Right-to-erasure should leave no labeler-identifiable data

4. **Telemetry**:
   ```elixir
   :telemetry.execute([:anvil, :retention, :sweep_completed], %{deleted_count: n})
   :telemetry.execute([:anvil, :gdpr, :erasure_requested], %{}, %{labeler_id: id})
   :telemetry.execute([:anvil, :export, :pii_detected], %{field: :notes}, %{export_id: id})
   ```

5. **CLI Commands**:
   ```bash
   # Trigger retention sweep
   mix anvil.retention.sweep --dry-run

   # Erase labeler (GDPR)
   mix anvil.gdpr.erase-labeler --id=labeler_123 --hard-delete

   # Validate export for PII
   mix anvil.export.scan-pii --file=labels.csv
   ```

6. **Documentation Requirements**:
   - Privacy policy template for labeling platform deployment
   - Data processing agreement (DPA) template for GDPR Article 28
   - Labeler consent form template
   - Export PII risk assessment guide

7. **Default Policies**:
   - New schemas: Default all free-text fields to `pii: :possible, retention_days: 365`
   - New labelers: Auto-generate pseudonym, never export external_id
   - New exports: Default to `redaction_mode: :automatic` with opt-out for trusted users
