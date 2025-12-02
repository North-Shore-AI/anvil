# ADR-005: Export System with Deterministic Lineage

## Status
Accepted

## Context

Labeled datasets are the end deliverable of annotation workflows, consumed by:

- **ML Training**: Fine-tuning models, evaluation benchmarks, few-shot prompts
- **Research Publication**: Archival datasets cited in papers, deposited in repositories (Zenodo, Hugging Face Hub)
- **Reproducibility**: Re-running experiments with identical data splits and label distributions
- **Compliance**: Audit trails for regulatory submissions (FDA, GDPR data exports)
- **Quality Analysis**: Offline statistical analysis of agreement, bias, label distribution

Export requirements vary by consumer:

| Consumer | Format | Key Requirements |
|----------|--------|------------------|
| PyTorch DataLoader | CSV, JSONL | Streaming (memory-safe for large datasets) |
| Hugging Face Transformers | Hugging Face Dataset | Arrow format, metadata dict, train/val/test splits |
| Pandas Analysis | CSV, Parquet | Column types, NA handling, UTF-8 encoding |
| Research Archive | JSONL + manifest | Deterministic ordering, cryptographic hashes, version pinning |
| Compliance Export | CSV | PII redaction, audit log inclusion, signed attestation |

Current Anvil v0.1 provides only basic `Anvil.Export` behaviour with no:
- **Lineage Tracking**: Cannot prove export "dataset_v2.1" came from specific queue/schema/sample version
- **Determinism**: Re-exporting same queue may produce different row ordering due to DB query non-determinism
- **Streaming**: Loading all labels into memory before export crashes on datasets >1M labels
- **Format Diversity**: Only one export format forces consumers to build custom converters
- **Manifest Metadata**: No machine-readable record of export parameters (schema version, filter criteria, row count)

Without robust exports, teams resort to manual SQL dumps, losing reproducibility and creating security risks (PII in ad-hoc queries).

## Decision

We will implement a streaming export system with multiple format adapters, deterministic ordering, manifest generation, and version pinning.

### Core Export Interface

```elixir
defmodule Anvil.Export do
  @callback to_format(
    queue_id :: binary(),
    opts :: keyword()
  ) :: {:ok, export_result} | {:error, reason}

  # Options:
  # - schema_version_id: UUID (required for reproducibility)
  # - sample_version: string (Forge version tag, optional)
  # - format: :csv | :jsonl | :huggingface | :parquet
  # - filter: label filters (e.g., only labels with agreement > 0.8)
  # - limit: max rows (for pagination)
  # - offset: starting row (for pagination)
  # - include_metadata: include agreement scores, labeler IDs, timestamps
  # - output_path: file path or S3 URL
  # - streaming: boolean (default true)
end
```

### Format Implementations

#### 1. CSV Export (`Anvil.Export.CSV`)

**Output Structure**:
```csv
sample_id,labeler_id,coherence,grounded,balance,novelty,overall,notes,submitted_at,agreement_coherence,agreement_overall
abc123,labeler1,true,true,false,true,true,"Sample seems coherent",2025-12-01T10:30:00Z,0.85,0.72
abc123,labeler2,true,false,false,true,true,"",2025-12-01T10:35:00Z,0.85,0.72
abc123,labeler3,false,true,true,true,false,"Contradictory claims",2025-12-01T10:40:00Z,0.85,0.72
```

**Implementation**:
```elixir
defmodule Anvil.Export.CSV do
  def to_format(queue_id, opts) do
    schema_version_id = Keyword.fetch!(opts, :schema_version_id)
    output_path = Keyword.fetch!(opts, :output_path)

    # Stream labels in batches
    labels_stream = stream_labels(queue_id, schema_version_id, opts)

    # Write to file with CSV encoder
    File.open!(output_path, [:write, :utf8], fn file ->
      # Write header
      IO.write(file, build_csv_header(schema_version_id) <> "\n")

      # Write rows
      labels_stream
      |> Stream.chunk_every(1000)
      |> Stream.each(fn batch ->
        rows = Enum.map(batch, &encode_csv_row/1)
        IO.write(file, Enum.join(rows, "\n") <> "\n")
      end)
      |> Stream.run()
    end)

    {:ok, build_manifest(queue_id, output_path, opts)}
  end

  defp stream_labels(queue_id, schema_version_id, opts) do
    # Deterministic ordering: ORDER BY sample_id, labeler_id, submitted_at
    Label
    |> join(:inner, [l], a in Assignment, on: l.assignment_id == a.id)
    |> where([l, a], a.queue_id == ^queue_id)
    |> where([l], l.schema_version_id == ^schema_version_id)
    |> order_by([l, a], [asc: a.sample_id, asc: l.labeler_id, asc: l.submitted_at])
    |> maybe_apply_filter(opts[:filter])
    |> maybe_apply_pagination(opts[:limit], opts[:offset])
    |> Repo.stream()
  end
end
```

**Escaping**: Use standard CSV escaping (quotes, newlines) via `CSV.encode/2` library

#### 2. JSONL Export (`Anvil.Export.JSONL`)

**Output Structure** (one JSON object per line):
```json
{"sample_id":"abc123","labeler_id":"labeler1","payload":{"coherence":true,"grounded":true,"balance":false,"novelty":true,"overall":true,"notes":"Sample seems coherent"},"submitted_at":"2025-12-01T10:30:00Z","metadata":{"agreement":{"coherence":0.85,"overall":0.72}}}
{"sample_id":"abc123","labeler_id":"labeler2","payload":{"coherence":true,"grounded":false,"balance":false,"novelty":true,"overall":true,"notes":""},"submitted_at":"2025-12-01T10:35:00Z","metadata":{"agreement":{"coherence":0.85,"overall":0.72}}}
```

**Advantages**:
- Preserves nested JSON structures (no flattening required)
- Streamable (can process line-by-line)
- Compatible with jq, BigQuery, Spark

**Implementation**:
```elixir
defmodule Anvil.Export.JSONL do
  def to_format(queue_id, opts) do
    output_path = Keyword.fetch!(opts, :output_path)

    File.open!(output_path, [:write, :utf8], fn file ->
      stream_labels(queue_id, opts)
      |> Stream.map(&Jason.encode!/1)
      |> Stream.each(&IO.write(file, &1 <> "\n"))
      |> Stream.run()
    end)

    {:ok, build_manifest(queue_id, output_path, opts)}
  end
end
```

#### 3. Hugging Face Dataset Export (`Anvil.Export.HuggingFace`)

**Output**: Arrow format with `dataset_info.json` metadata

**Structure**:
```elixir
# Generates dataset compatible with:
# from datasets import load_from_disk
# dataset = load_from_disk("cns_synthesis_labels_v2")

defmodule Anvil.Export.HuggingFace do
  def to_format(queue_id, opts) do
    output_dir = Keyword.fetch!(opts, :output_path)
    File.mkdir_p!(output_dir)

    # Convert to Arrow format using ExArrow or Python bridge
    labels = stream_labels(queue_id, opts) |> Enum.to_list()

    dataset_dict = %{
      "train" => build_split(labels, :train, opts),
      "validation" => build_split(labels, :validation, opts),
      "test" => build_split(labels, :test, opts)
    }

    # Write Arrow files
    for {split, data} <- dataset_dict do
      arrow_path = Path.join(output_dir, "#{split}.arrow")
      write_arrow(data, arrow_path)
    end

    # Write dataset_info.json
    dataset_info = %{
      description: "CNS Synthesis Labels - Queue #{queue_id}",
      citation: generate_citation(queue_id, opts),
      homepage: "https://nsai.example.com/queues/#{queue_id}",
      license: "CC-BY-4.0",
      features: build_features_schema(opts[:schema_version_id]),
      splits: %{
        "train" => %{name: "train", num_examples: length(dataset_dict["train"])},
        "validation" => %{name: "validation", num_examples: length(dataset_dict["validation"])},
        "test" => %{name: "test", num_examples: length(dataset_dict["test"])}
      },
      version: %{version_str: "1.0.0", major: 1, minor: 0, patch: 0}
    }

    File.write!(Path.join(output_dir, "dataset_info.json"), Jason.encode!(dataset_info, pretty: true))

    {:ok, build_manifest(queue_id, output_dir, opts)}
  end

  defp build_split(labels, split, opts) do
    # Default 80/10/10 split, deterministic via hash-based assignment
    Enum.filter(labels, fn label ->
      sample_hash = :crypto.hash(:md5, label.sample_id) |> Base.encode16()
      first_byte = String.slice(sample_hash, 0..1) |> String.to_integer(16)

      case split do
        :train -> first_byte < 204  # 80% (204/255)
        :validation -> first_byte >= 204 and first_byte < 230  # 10%
        :test -> first_byte >= 230  # 10%
      end
    end)
  end
end
```

**Fallback**: If Arrow writing is complex, export as JSONL + README with instructions for conversion

#### 4. Parquet Export (`Anvil.Export.Parquet`) [Optional]

**Use Case**: Large datasets for Spark, Presto, BigQuery
**Implementation**: Use `ExArrow` or shell out to `pyarrow` for conversion
**Deferred**: Implement only if requested; JSONL covers most use cases

### Deterministic Ordering

**Problem**: Database queries without explicit ORDER BY can return rows in non-deterministic order (depends on physical layout, query plan)

**Solution**: Always order by composite key:
```sql
ORDER BY sample_id ASC, labeler_id ASC, submitted_at ASC
```

**Hash Verification**:
```elixir
defp compute_export_hash(output_path) do
  # Streaming hash to handle large files
  File.stream!(output_path, [], 2048)
  |> Enum.reduce(:crypto.hash_init(:sha256), fn chunk, acc ->
    :crypto.hash_update(acc, chunk)
  end)
  |> :crypto.hash_final()
  |> Base.encode16(case: :lower)
end
```

**Manifest Inclusion**:
```json
{
  "export_id": "exp_abc123",
  "queue_id": "queue_xyz",
  "schema_version_id": "schema_v2",
  "sample_version": "2024-12-01",
  "format": "csv",
  "row_count": 1500,
  "sha256": "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
  "exported_at": "2025-12-01T15:00:00Z",
  "parameters": {
    "filter": {"agreement": {"$gte": 0.8}},
    "include_metadata": true
  }
}
```

### Pagination and Streaming

**Memory Safety**:
```elixir
# Avoid loading all labels into memory
# BAD:
labels = Repo.all(from l in Label, where: l.queue_id == ^queue_id)
write_csv(labels, output_path)

# GOOD:
Repo.stream(from l in Label, where: l.queue_id == ^queue_id)
|> Stream.chunk_every(1000)
|> Stream.each(&write_csv_batch(&1, file_handle))
|> Stream.run()
```

**API Support**:
```elixir
# Export 10k labels starting at offset 50k (for incremental exports)
Anvil.Export.to_csv(queue_id, %{
  schema_version_id: schema_v2,
  limit: 10_000,
  offset: 50_000,
  output_path: "labels_batch_5.csv"
})
```

**Progress Tracking**:
```elixir
# Emit telemetry for long-running exports
defp stream_with_progress(query, total_count) do
  Repo.stream(query)
  |> Stream.chunk_every(1000)
  |> Stream.with_index()
  |> Stream.each(fn {batch, index} ->
    processed = (index + 1) * 1000
    :telemetry.execute([:anvil, :export, :progress], %{processed: processed, total: total_count})
  end)
end
```

### Export Manifests

**Manifest Contents**:
```elixir
defmodule Anvil.Export.Manifest do
  defstruct [
    :export_id,
    :queue_id,
    :schema_version_id,
    :sample_version,
    :format,
    :output_path,
    :row_count,
    :sha256_hash,
    :exported_at,
    :parameters,
    :anvil_version,
    :schema_definition_hash
  ]
end
```

**Storage**:
- Write manifest as `{output_path}.manifest.json` alongside export file
- Optionally store in `export_manifests` table for queryability

**Validation**:
```elixir
# Re-export and verify hash matches
def verify_export_reproducibility(export_id) do
  manifest = load_manifest(export_id)

  {:ok, new_export} = Anvil.Export.to_format(
    manifest.queue_id,
    manifest.parameters
  )

  if new_export.sha256_hash == manifest.sha256_hash do
    {:ok, :reproducible}
  else
    {:error, :hash_mismatch, old: manifest.sha256_hash, new: new_export.sha256_hash}
  end
end
```

### Version Pinning

**Explicit Version Specification**:
```elixir
# REQUIRED: Must specify schema_version_id to prevent implicit "latest" behavior
Anvil.Export.to_csv(queue_id, %{
  schema_version_id: schema_v2_id,  # Explicit version
  sample_version: "2024-12-01"  # Optional Forge version tag
})

# FORBIDDEN: Implicit latest version creates non-reproducible exports
Anvil.Export.to_csv(queue_id, %{})  #=> {:error, :schema_version_required}
```

**Sample Version Integration** (from Forge):
```elixir
# Forge tracks sample versions via content hashing
# Anvil exports include Forge version for full lineage

defmodule Anvil.ForgeBridge do
  def fetch_sample_version(sample_id) do
    # Query Forge for sample version tag
    case Forge.Samples.get_version(sample_id) do
      {:ok, version} -> version
      {:error, _} -> nil  # Graceful degradation if Forge unavailable
    end
  end
end

# Manifest includes both schema and sample versions
%{
  schema_version_id: "schema_v2",
  sample_version: "forge_2024-12-01_abc123",  # Forge version tag
  sample_version_hashes: %{
    "sample_abc123" => "sha256:e3b0c44...",
    "sample_xyz789" => "sha256:a1b2c3d..."
  }
}
```

## Consequences

### Positive

- **Reproducibility**: Deterministic ordering + version pinning guarantees identical exports across time; satisfies research publication requirements
- **Lineage Tracking**: Manifest metadata enables dataset provenance; can trace labels back to specific queue, schema, sample versions
- **Memory Safety**: Streaming export handles multi-million label datasets without OOM crashes
- **Format Flexibility**: Multiple export formats reduce friction for different consumers (ML pipelines, analytics, archival)
- **Integrity Verification**: SHA256 hashes enable tamper detection; can prove dataset hasn't been modified
- **Audit Compliance**: Export manifests satisfy regulatory requirements for data export auditing (GDPR Article 20, FDA 21 CFR Part 11)
- **Incremental Exports**: Pagination support enables daily incremental exports without re-exporting entire dataset

### Negative

- **Format Maintenance Burden**: Each export format (CSV, JSONL, HF, Parquet) requires testing, bug fixes, and feature parity
- **Storage Overhead**: Manifest files add ~1-5KB per export; for frequent exports, consider manifest database table
- **Hash Computation Cost**: SHA256 hashing large exports adds latency (e.g., ~10s for 1GB file); consider async background job
- **Determinism Brittleness**: Query plan changes (Postgres version upgrade) could theoretically alter order despite ORDER BY; requires regression testing
- **Version Complexity**: Requiring explicit schema_version_id adds friction for quick ad-hoc exports; consider "draft export" mode
- **Arrow Dependency**: Hugging Face export requires `ExArrow` or Python bridge; adds complexity to deployment

### Neutral

- **Compression**: Consider optional gzip compression for exports (`.csv.gz`, `.jsonl.gz`) to reduce storage/transfer costs
- **Signed URLs**: For S3 exports, generate signed URLs with expiration for secure sharing
- **Export Scheduling**: Oban job for nightly automated exports with configurable retention (e.g., keep last 7 daily exports)
- **Diff Export**: Export only labels created/modified since last export (requires tracking `updated_at`)
- **Multi-Queue Export**: Support exporting merged labels from multiple related queues (e.g., train + val queues)

## Implementation Notes

1. **CSV Library**:
   - Use `nimble_csv` for performant streaming CSV encoding
   - Handle edge cases: quotes, newlines, Unicode, NULL values

2. **Progress UI** (for Ingot LiveView):
   ```elixir
   # Subscribe to export progress events
   def mount(_params, _session, socket) do
     Phoenix.PubSub.subscribe(Anvil.PubSub, "export:#{export_id}")
     {:ok, socket}
   end

   def handle_info({:export_progress, %{processed: n, total: t}}, socket) do
     {:noreply, assign(socket, progress: n / t * 100)}
   end
   ```

3. **Error Handling**:
   ```elixir
   # Atomic export with rollback
   def to_format(queue_id, opts) do
     tmp_path = "#{opts[:output_path]}.tmp"

     try do
       write_export(tmp_path, queue_id, opts)
       File.rename!(tmp_path, opts[:output_path])
       {:ok, manifest}
     rescue
       e -> {:error, e}
     after
       File.rm(tmp_path)  # Cleanup on failure
     end
   end
   ```

4. **Testing Strategy**:
   - Golden file tests: Compare exports against known-good fixtures
   - Property tests: Export + re-export should produce identical hashes
   - Large dataset test: Export 1M labels, verify memory usage stays constant
   - Format parity test: CSV and JSONL should contain same data (modulo formatting)

5. **Telemetry Events**:
   ```elixir
   :telemetry.execute([:anvil, :export, :start], %{}, %{queue_id: id, format: :csv})
   :telemetry.execute([:anvil, :export, :stop], %{duration: ms, row_count: n}, %{})
   :telemetry.execute([:anvil, :export, :exception], %{}, %{error: inspect(e)})
   ```

6. **CLI Interface**:
   ```bash
   # Export command
   mix anvil.export --queue=cns_synthesis --schema-version=v2 --format=csv --output=labels.csv

   # Verify export
   mix anvil.export.verify --manifest=labels.csv.manifest.json

   # Compare exports
   mix anvil.export.diff export1.manifest.json export2.manifest.json
   ```

7. **Performance Targets**:
   - Export 100k labels: <30 seconds (CSV/JSONL)
   - Export 1M labels: <5 minutes (streaming, no memory spike)
   - Manifest generation: <1 second
   - Hash computation: <10 seconds for 1GB file
