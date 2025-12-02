<div align="center">

# Anvil

<img src="assets/anvil.svg" alt="Anvil Logo" width="392"/>

</div>

[![Hex.pm](https://img.shields.io/hexpm/v/anvil.svg)](https://hex.pm/packages/anvil)
[![Documentation](https://img.shields.io/badge/docs-hexpm-blue.svg)](https://hexdocs.pm/anvil)

Labeling queue and governance toolkit for human-in-the-loop workflows. Anvil provides GenServer-based queues for fast, in-memory work plus a Postgres/Oban pipeline for production-grade exports, telemetry, and retention.

## Highlights
- Schema-driven validation with typed fields (`:text`, `:select`, `:multiselect`, `:range`, `:number`, `:boolean`, `:date`, `:datetime`)
- Pluggable assignment policies: round-robin, random, weighted expertise, redundancy (k labels per sample), or custom policy modules
- Storage adapters for ETS (default) and Postgres (`Anvil.Storage.Postgres`) with Ecto schemas for queues, assignments, labels, schema versions, and audit logs
- Agreement metrics (Cohen, Fleiss, Krippendorff) with telemetry and background recomputation
- PII-aware exports with redaction, pseudonyms, manifests, and reproducibility verification
- Background jobs via Oban for timeouts, agreement recompute, and retention sweeps
- Optional Forge sample bridge and simple ACL helpers for queue membership

## Quickstart (in-memory queue)

```elixir
# 1) Define a schema
schema =
  Anvil.Schema.new(
    name: "sentiment",
    fields: [
      %Anvil.Schema.Field{
        name: "sentiment",
        type: :select,
        required: true,
        options: ["positive", "negative", "neutral"]
      }
    ]
  )

# 2) Start a queue (ETS storage by default)
{:ok, queue} =
  Anvil.create_queue(
    queue_id: "sentiment_queue",
    schema: schema,
    labels_per_sample: 2,
    policy: :round_robin
  )

# 3) Load work and labelers
Anvil.add_samples(queue, [%{id: "s1", text: "Great product!"}])
Anvil.add_labelers(queue, ["alice", "bob"])

# 4) Pull and start an assignment
{:ok, assignment} = Anvil.get_next_assignment(queue, "alice")
{:ok, assignment} = Anvil.Queue.start_assignment(queue, assignment.id)

# 5) Submit a label (validated against the schema)
{:ok, label} =
  Anvil.submit_label(queue, assignment.id, %{"sentiment" => "positive"})

# 6) Fetch labels and compute agreement
labels = Anvil.Queue.get_labels(queue)
{:ok, score} = Anvil.Agreement.compute(labels)
```

## Assignment policies
- `:round_robin` – walks samples in order
- `:random` – random sample from available set
- `:expertise` – weighted expertise policy (`:expertise_scores`, `:min_expertise`, optional `:difficulty_field`)
- `:redundancy` – prioritize under-labeled samples; default when `labels_per_sample > 1`
- Custom module – pass a module or `{module, config}` that implements `Anvil.Queue.Policy`

## Storage backends
- **ETS (default)**: zero-dependency, in-memory storage for tests and ephemeral queues.
- **Postgres**: use `Anvil.Storage.Postgres` (defaults to `Anvil.Repo`). Requires the host app to provide the database schema matching the Ecto modules under `Anvil.Schema.*`; migrations are not bundled in this repo.

```elixir
{:ok, queue} =
  Anvil.create_queue(
    queue_id: "prod_queue",
    schema: schema,
    storage: Anvil.Storage.Postgres
  )
```

## Agreement metrics
- `Anvil.Agreement.compute/2` auto-selects Cohen/Fleiss based on rater count or accepts `metric: :cohen | :fleiss | :krippendorff`.
- Helpers: `compute_for_field/3`, `compute_all_dimensions/3`, and `summary/3` for per-field rollups.
- Telemetry emits low-agreement events when scores drop below 0.6.

## Exporting labels
- **Manifested export (ADR-005)**: deterministic ordering, SHA256 manifest, optional PII redaction and pseudonyms. Requires Postgres data with schema versions.

  ```elixir
  {:ok, %{manifest: manifest, output_path: path}} =
    Anvil.Export.to_format(:csv, queue_id, %{
      schema_version_id: schema_version_id,
      output_path: "/tmp/labels.csv",
      redaction_mode: :automatic
    })

  {:ok, :reproducible} = Anvil.Export.verify_reproducibility(manifest)
  ```

- **Legacy export**: works with ETS queues; serializes current in-memory labels.

  ```elixir
  :ok = Anvil.Export.export(queue, format: :csv, path: "labels.csv")
  ```

## PII, retention, and governance
- PII metadata on fields (`pii`, `retention_days`, `redaction_policy`) drives redaction and retention.
- `Anvil.PII.Redactor` supports strip/truncate/hash/regex policies and payload redaction modes (`:none`, `:automatic`, `:aggressive`).
- `Anvil.PII.Retention` and the `Anvil.Workers.RetentionSweep` Oban job enforce retention windows and optional soft/hard deletion.
- Labeler pseudonyms available via `Anvil.PII.Pseudonym`.

## Background jobs and telemetry
- Oban cron (see `config/config.exs`): timeout sweeps, agreement recompute, retention sweeps.
- Telemetry events cover queue creation, assignment dispatch/completion, validation errors, exports, agreement, and storage queries.

## Forge integration
- `Anvil.ForgeBridge` fetches samples via pluggable backends (`Direct`, `HTTP`, `Cached`, `Mock`) with Cachex-based caching.

## Authentication and access control
- `Anvil.Auth.ACL` provides queue membership checks (`:labeler`, `:reviewer`, `:owner`) plus helpers for granting/revoking access.
- Signed URL and OIDC helpers are available under `Anvil.Auth`.

## Development

```bash
mix test
mix docs
```

## License

MIT License - see `LICENSE` for details.

## Acknowledgments

Built by the North Shore AI team for the machine learning community.
