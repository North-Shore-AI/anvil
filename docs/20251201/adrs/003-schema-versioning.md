# ADR-003: Schema Versioning and Evolution

## Status
Accepted

## Context

Labeling schemas evolve over time as research questions mature, annotation guidelines improve, and edge cases emerge. Common schema evolution scenarios:

- **Field Addition**: Adding new optional fields (e.g., adding "confidence_score" to existing coherence/grounded labels)
- **Field Removal**: Deprecating unused fields (e.g., removing experimental "sentiment" field after pilot showed it wasn't informative)
- **Refinement**: Changing enum values (e.g., splitting "partially_coherent" into "mostly_coherent" and "minimally_coherent")
- **Restructuring**: Changing nesting (e.g., moving "notes" from top-level to nested under each dimension)
- **Validation Tightening**: Adding constraints (e.g., requiring "evidence_quote" when grounded=true)

Without version control, schema changes create fundamental problems:

1. **Export Inconsistency**: Labels created under different schemas produce incompatible datasets; merging requires manual reconciliation
2. **Reproducibility Loss**: Cannot recreate historical exports; papers citing "dataset v2.1" cannot be validated if schema changed
3. **Lineage Breaks**: Agreement metrics computed across schema versions are meaningless (comparing apples to oranges)
4. **Data Loss**: Naive migrations can silently drop data (e.g., removing a field loses all existing values)
5. **Backward Compatibility**: Cannot re-run old analyses on new labels if schema structure changed

The schema versioning system must balance **immutability** (for reproducibility) with **evolvability** (for research agility), while providing safe migration paths that preserve data integrity.

## Decision

We will implement immutable schema versioning with forward-only migrations and optional transform callbacks for backward compatibility.

### Core Principles

1. **Immutability After First Use**: Once a label exists for a schema version, that version becomes frozen (read-only)
2. **Forward-Only Migrations**: New versions created explicitly; old versions never modified
3. **Explicit Versioning**: Every label tagged with `schema_version_id`; exports pin to specific version
4. **Transform Callbacks**: Optional Elixir modules to remap labels from version N to N+1 during dual-write period

### Schema Version Lifecycle

#### Phase 1: Draft (Mutable)

```elixir
# Create initial schema (v1)
{:ok, schema_v1} = Anvil.Schema.create(%{
  queue_id: queue_id,
  version_number: 1,
  schema_definition: %{
    type: "object",
    properties: %{
      coherence: %{type: "boolean"},
      grounded: %{type: "boolean"},
      notes: %{type: "string", maxLength: 500}
    },
    required: ["coherence", "grounded"]
  }
})

# Schema is mutable until first label submitted
Anvil.Schema.update(schema_v1.id, %{
  schema_definition: %{...}  # Can freely modify
})
```

**State**: `frozen_at` = NULL
**Allowed Operations**: Update schema_definition, delete version (if no labels exist)

#### Phase 2: Frozen (Immutable)

```elixir
# First label submission freezes schema
{:ok, label} = Anvil.Label.submit(%{
  assignment_id: assignment_id,
  schema_version_id: schema_v1.id,
  payload: %{coherence: true, grounded: false, notes: "..."}
})

# schema_v1.frozen_at now set to current timestamp
schema_v1 = Repo.reload(schema_v1)
assert schema_v1.frozen_at != nil

# Update attempts now fail
{:error, :schema_frozen} = Anvil.Schema.update(schema_v1.id, %{...})
```

**State**: `frozen_at` = timestamp of first label
**Allowed Operations**: Read-only; create new version via migration

#### Phase 3: Migration to New Version

```elixir
# Create v2 with transform callback
{:ok, schema_v2} = Anvil.Schema.create_migration(%{
  from_version_id: schema_v1.id,
  version_number: 2,
  schema_definition: %{
    type: "object",
    properties: %{
      coherence: %{type: "string", enum: ["high", "medium", "low"]},  # Changed from boolean
      grounded: %{type: "boolean"},
      balance: %{type: "boolean"},  # New field
      notes: %{type: "string", maxLength: 1000}  # Relaxed constraint
    },
    required: ["coherence", "grounded", "balance"]
  },
  transform_module: "Anvil.Transforms.V1ToV2"  # Optional
})
```

**Transform Module** (implements `Anvil.Schema.Transform` behaviour):

```elixir
defmodule Anvil.Transforms.V1ToV2 do
  @behaviour Anvil.Schema.Transform

  @impl true
  def forward(label_v1) do
    %{
      coherence: boolean_to_level(label_v1.coherence),
      grounded: label_v1.grounded,
      balance: nil,  # New field, no source data
      notes: label_v1.notes
    }
  end

  @impl true
  def backward(label_v2) do
    # For dual-write period: write v2 label, also write v1 for compatibility
    %{
      coherence: level_to_boolean(label_v2.coherence),
      grounded: label_v2.grounded,
      notes: label_v2.notes
      # Drops 'balance' field
    }
  end

  defp boolean_to_level(true), do: "high"
  defp boolean_to_level(false), do: "low"

  defp level_to_boolean("high"), do: true
  defp level_to_boolean("medium"), do: true
  defp level_to_boolean("low"), do: false
end
```

### Dual-Write Period (Optional)

For critical queues, maintain compatibility during migration:

```elixir
# Configuration in queue policy
config = %{
  dual_write_enabled: true,
  dual_write_until: ~U[2025-12-15 00:00:00Z],
  active_schema_version_id: schema_v2.id,
  compat_schema_version_id: schema_v1.id
}

# Label submission writes to both versions
def submit_label(assignment_id, payload, opts) do
  primary_label = %{
    assignment_id: assignment_id,
    schema_version_id: schema_v2.id,
    payload: payload  # v2 format
  }

  compat_label = if dual_write_active?() do
    %{
      assignment_id: assignment_id,
      schema_version_id: schema_v1.id,
      payload: Transform.V1ToV2.backward(payload)
    }
  end

  Repo.transaction(fn ->
    Repo.insert!(primary_label)
    if compat_label, do: Repo.insert!(compat_label)
  end)
end
```

**Rationale**: Downstream systems (exports, analytics) can continue reading v1 while migration completes

### Schema Definition Storage

Schemas stored as JSONB in `schema_versions.schema_definition`:

**Option A: JSON Schema**
```json
{
  "type": "object",
  "properties": {
    "coherence": {"type": "boolean"},
    "grounded": {"type": "boolean"}
  },
  "required": ["coherence", "grounded"]
}
```

**Option B: Ecto Embedded Schema (Recommended)**
```elixir
defmodule Anvil.Schema.CNSSynthesisV1 do
  use Ecto.Schema

  embedded_schema do
    field :coherence, :boolean
    field :grounded, :boolean
    field :notes, :string
  end

  def changeset(schema, attrs) do
    schema
    |> cast(attrs, [:coherence, :grounded, :notes])
    |> validate_required([:coherence, :grounded])
    |> validate_length(:notes, max: 500)
  end
end

# Serialize to JSONB
schema_definition = %{
  module: "Anvil.Schema.CNSSynthesisV1",
  fields: [:coherence, :grounded, :notes],
  validations: [...]
}
```

**Validation on Label Submission**:
```elixir
def validate_payload(payload, schema_version_id) do
  schema_version = Repo.get!(SchemaVersion, schema_version_id)
  schema_module = String.to_existing_atom(schema_version.schema_definition.module)

  changeset = schema_module.changeset(struct(schema_module), payload)

  if changeset.valid? do
    {:ok, apply_changes(changeset)}
  else
    {:error, changeset.errors}
  end
end
```

### Migration Helpers

**1. Batch Remapping Labels** (for one-time migrations):

```elixir
defmodule Anvil.Schema.Migrator do
  def remap_labels(from_version_id, to_version_id, transform_module) do
    labels = Repo.all(from l in Label, where: l.schema_version_id == ^from_version_id)

    for label <- labels do
      new_payload = transform_module.forward(label.payload)

      Repo.insert!(%Label{
        assignment_id: label.assignment_id,
        labeler_id: label.labeler_id,
        schema_version_id: to_version_id,
        payload: new_payload,
        submitted_at: label.submitted_at,
        created_at: DateTime.utc_now()
      })
    end
  end
end
```

**Use Case**: Bulk migration for research reanalysis; creates duplicate labels under new schema

**2. Export with On-the-Fly Transform**:

```elixir
# Export v1 labels in v2 format without creating duplicate rows
Anvil.Export.to_jsonl(queue_id, %{
  target_schema_version_id: schema_v2.id,
  transform_module: Anvil.Transforms.V1ToV2
})

# Internally applies transform.forward() during streaming
for label <- stream_labels(queue_id) do
  if label.schema_version_id == schema_v1.id do
    emit_json(transform_module.forward(label.payload))
  else
    emit_json(label.payload)  # Already v2
  end
end
```

### Schema Version Constraints

**Database Constraints**:
```sql
-- Prevent modification of frozen schemas
CREATE OR REPLACE FUNCTION prevent_schema_update()
RETURNS TRIGGER AS $$
BEGIN
  IF OLD.frozen_at IS NOT NULL THEN
    RAISE EXCEPTION 'Cannot modify frozen schema version %', OLD.id;
  END IF;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER schema_version_immutability
BEFORE UPDATE ON schema_versions
FOR EACH ROW EXECUTE FUNCTION prevent_schema_update();

-- Auto-freeze on first label
CREATE OR REPLACE FUNCTION freeze_schema_on_label()
RETURNS TRIGGER AS $$
BEGIN
  UPDATE schema_versions
  SET frozen_at = NOW()
  WHERE id = NEW.schema_version_id AND frozen_at IS NULL;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER freeze_schema_trigger
AFTER INSERT ON labels
FOR EACH ROW EXECUTE FUNCTION freeze_schema_on_label();
```

### Version Number Management

**Sequential Numbering**:
- `version_number` is integer, sequential within each queue
- Gap detection: If v1 and v3 exist but not v2, warn during export (indicates data loss risk)

**Version Lineage**:
- Optional `parent_version_id` field to track migration chain (v1 → v2 → v3)
- Enables validation that transforms form a valid DAG (no cycles)

## Consequences

### Positive

- **Reproducibility**: Pinning exports to `schema_version_id` guarantees identical output across time; satisfies scientific publishing requirements
- **Lineage**: Every label traceable to exact schema definition; dataset citations include schema version hash
- **Safe Evolution**: Frozen schemas prevent accidental breaking changes; migrations are explicit and auditable
- **Data Preservation**: Transform callbacks enable lossless migration (forward + backward transforms); no silent data drops
- **Flexibility**: Dual-write period enables gradual migration for critical queues without downtime
- **Validation Consistency**: Schema-specific validation logic (via Ecto changesets) enforces data quality at write time
- **Export Correctness**: Agreement metrics computed only within schema version, avoiding apples-to-oranges comparisons

### Negative

- **Storage Overhead**: Dual-write creates duplicate labels during migration period; 2x storage cost until cutover
- **Migration Complexity**: Transform modules require careful implementation; bugs can silently corrupt data
- **Version Proliferation**: Frequent schema changes create many versions; exports must specify version explicitly
- **Backward Compatibility Burden**: Maintaining transform.backward() for dual-write requires ongoing effort
- **Schema Debugging**: Errors in frozen schemas cannot be fixed in-place; must create new version and migrate
- **Query Complexity**: Queries spanning multiple schema versions require union of label sets with transformations

### Neutral

- **Transform Testing**: Transform modules require dedicated test coverage (round-trip property tests: backward(forward(x)) == x)
- **Migration Tooling**: Provide CLI command for schema migration: `mix anvil.schema.migrate --queue=cns_synthesis --transform=V1ToV2`
- **Version Deprecation**: Mark old versions as deprecated (but not deleted) once all labels migrated; support archive-only mode
- **Schema Registry**: Consider external schema registry (e.g., Confluent Schema Registry) for cross-system schema sharing
- **Diff Visualization**: Provide `Anvil.Schema.diff(v1, v2)` to show added/removed/changed fields for auditing

## Implementation Notes

1. **JSON Schema vs Ecto**:
   - Prefer Ecto embedded schemas for type safety and changesets
   - Serialize to JSONB as `%{module: ..., config: ...}` for storage
   - JSON Schema as fallback for external integrations

2. **Transform Testing Strategy**:
   ```elixir
   defmodule Anvil.Transforms.V1ToV2Test do
     use ExUnit.Case
     use ExUnitProperties

     property "forward/backward round-trip preserves v1 data" do
       check all label_v1 <- v1_generator() do
         label_v2 = V1ToV2.forward(label_v1)
         assert V1ToV2.backward(label_v2) == label_v1
       end
     end

     property "forward transform produces valid v2 schema" do
       check all label_v1 <- v1_generator() do
         label_v2 = V1ToV2.forward(label_v1)
         assert {:ok, _} = validate_v2(label_v2)
       end
     end
   end
   ```

3. **Migration Workflow**:
   ```bash
   # 1. Create new schema version (draft)
   mix anvil.schema.create --queue=cns_synthesis --version=2 --from=1

   # 2. Test transform module
   mix test test/transforms/v1_to_v2_test.exs

   # 3. Enable dual-write (7 day overlap)
   mix anvil.schema.dual_write --queue=cns_synthesis --duration=7d

   # 4. Monitor dual-write for errors
   mix anvil.schema.dual_write.status

   # 5. Cutover to v2 (disable dual-write)
   mix anvil.schema.cutover --queue=cns_synthesis --to-version=2

   # 6. Backfill old labels (optional)
   mix anvil.schema.migrate --queue=cns_synthesis --from=1 --to=2 --batch-size=1000
   ```

4. **Export Pinning**:
   ```elixir
   # Explicit version pinning
   Anvil.Export.to_csv(queue_id, %{
     schema_version_id: schema_v2.id,
     sample_version: "2024-12-01"  # From Forge
   })

   # Export manifest includes version metadata
   %{
     queue_id: "...",
     schema_version_id: "...",
     schema_version_number: 2,
     schema_hash: "sha256:abc123...",
     sample_version: "2024-12-01",
     label_count: 1500,
     exported_at: ~U[2025-12-01 10:00:00Z]
   }
   ```

5. **Telemetry Events**:
   - `[:anvil, :schema, :created]` - %{queue_id, version_number}
   - `[:anvil, :schema, :frozen]` - %{schema_version_id, frozen_at}
   - `[:anvil, :schema, :migrated]` - %{from_version, to_version, label_count}
   - `[:anvil, :schema, :dual_write, :conflict]` - %{label_id, v1_payload, v2_payload} (when backward transform produces different result)

6. **Schema Validation Errors**:
   - Return detailed errors to labeler UI (field-level feedback)
   - Log validation failures with full payload for debugging (PII-aware logging)
   - Alert on sudden spike in validation failures (indicates schema/UI mismatch)
