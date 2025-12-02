# ADR-005: Export Format Support

## Status

Accepted

## Context

Labeled data needs to be exported for downstream use in:

1. **Model Training**: ML frameworks expect specific formats
2. **Analysis**: Data scientists use various tools (Python, R, Excel)
3. **Archival**: Long-term storage and compliance
4. **Integration**: Feeding into data pipelines
5. **Reporting**: Stakeholder visibility into labeling progress

Different use cases prefer different formats:
- **CSV**: Universal compatibility, spreadsheet-friendly
- **JSON/JSONL**: Structured data, preserves types, streaming-friendly
- **Parquet**: Columnar storage, efficient for big data
- **Custom**: Domain-specific formats

We need to balance flexibility with maintainability.

## Decision

We will implement two export formats in v1, with an extension mechanism for custom exporters.

### Built-in Formats

#### 1. CSV (Comma-Separated Values)

**Use Case**: Maximum compatibility, spreadsheet analysis, simple datasets

**Format**:
```csv
sample_id,labeler_id,field_1,field_2,labeling_time_seconds,created_at
s1,labeler1,cat,4,12,2024-01-15T10:30:00Z
s1,labeler2,cat,5,15,2024-01-15T10:32:00Z
s2,labeler1,dog,3,10,2024-01-15T10:35:00Z
```

**API**:
```elixir
Anvil.export(queue, format: :csv, path: "/path/to/output.csv")

# With options
Anvil.export(queue,
  format: :csv,
  path: "/path/to/output.csv",
  options: %{
    delimiter: ",",
    include_metadata: true,
    include_sample_data: false,
    filter: fn label -> label.valid? end
  }
)
```

**Advantages**:
- Universal tool support
- Human-readable
- Easy to import into Excel, R, Python
- Small file size

**Disadvantages**:
- No type information
- Limited support for nested structures
- Quoting/escaping issues with text fields
- Not streaming-friendly for large datasets

**Implementation Details**:
```elixir
defmodule Anvil.Export.CSV do
  def export(queue, path, opts \\ []) do
    labels = get_labels(queue)
    delimiter = opts[:delimiter] || ","

    File.open(path, [:write], fn file ->
      # Write header
      IO.write(file, header_row(labels, delimiter))

      # Write rows
      labels
      |> Stream.map(&to_row(&1, delimiter))
      |> Enum.each(&IO.write(file, &1))
    end)
  end

  defp header_row(labels, delimiter) do
    # Extract field names from schema
    # Format: sample_id,labeler_id,field1,field2,...
  end

  defp to_row(label, delimiter) do
    # Convert label to CSV row
    # Handle escaping and quoting
  end
end
```

#### 2. JSONL (JSON Lines)

**Use Case**: Structured data, preserves types, streaming, nested fields

**Format**:
```jsonl
{"sample_id":"s1","labeler_id":"labeler1","values":{"category":"cat","confidence":4},"labeling_time_seconds":12,"created_at":"2024-01-15T10:30:00Z"}
{"sample_id":"s1","labeler_id":"labeler2","values":{"category":"cat","confidence":5},"labeling_time_seconds":15,"created_at":"2024-01-15T10:32:00Z"}
{"sample_id":"s2","labeler_id":"labeler1","values":{"category":"dog","confidence":3},"labeling_time_seconds":10,"created_at":"2024-01-15T10:35:00Z"}
```

**API**:
```elixir
Anvil.export(queue, format: :jsonl, path: "/path/to/output.jsonl")

# With options
Anvil.export(queue,
  format: :jsonl,
  path: "/path/to/output.jsonl",
  options: %{
    pretty: false,
    include_metadata: true,
    include_sample_data: true,
    filter: fn label -> label.valid? end
  }
)
```

**Advantages**:
- Preserves data types
- Supports nested structures
- Streaming-friendly (one JSON per line)
- Easy to process with jq, Python, etc.
- Handles complex schemas well

**Disadvantages**:
- Not human-readable for large fields
- Slightly larger file size than CSV
- Less tool support than CSV (though improving)

**Implementation Details**:
```elixir
defmodule Anvil.Export.JSONL do
  def export(queue, path, opts \\ []) do
    labels = get_labels(queue)

    File.open(path, [:write], fn file ->
      labels
      |> Stream.map(&to_json/1)
      |> Enum.each(&IO.write(file, &1 <> "\n"))
    end)
  end

  defp to_json(label) do
    label
    |> Map.from_struct()
    |> Jason.encode!()
  end
end
```

### Custom Exporters

Extension mechanism for domain-specific formats:

```elixir
defmodule MyCustomExporter do
  @behaviour Anvil.Export.Exporter

  @impl true
  def export(labels, path, opts) do
    # Custom export logic
    # E.g., format for specific ML framework
    :ok
  end
end

# Usage
Anvil.export(queue,
  format: {MyCustomExporter, %{custom_option: "value"}},
  path: "/path/to/output.custom"
)
```

### Export API

#### Main Function

```elixir
@spec export(queue :: pid() | atom(), opts :: keyword()) ::
  :ok | {:error, reason :: term()}

def export(queue, opts) do
  # Extract options
  format = Keyword.fetch!(opts, :format)
  path = Keyword.fetch!(opts, :path)
  export_opts = Keyword.get(opts, :options, %{})

  # Get labels from queue
  labels = Queue.get_labels(queue)

  # Apply filters if specified
  labels = maybe_filter(labels, export_opts[:filter])

  # Call appropriate exporter
  case format do
    :csv -> Export.CSV.export(labels, path, export_opts)
    :jsonl -> Export.JSONL.export(labels, path, export_opts)
    {module, config} -> module.export(labels, path, Map.merge(export_opts, config))
  end
end
```

#### Streaming API (for large datasets)

```elixir
# Export in chunks to avoid loading all labels into memory
Anvil.export_stream(queue,
  format: :jsonl,
  path: "/path/to/output.jsonl",
  chunk_size: 1000
)
```

#### Export with Transformations

```elixir
# Apply transformations before export
Anvil.export(queue,
  format: :csv,
  path: "/path/to/output.csv",
  transform: fn label ->
    # Flatten nested structures
    # Compute derived fields
    # Format dates
    transformed_label
  end
)
```

### Common Options

All exporters support:

- `:filter` - Filter function to select labels
- `:include_metadata` - Include labeling metadata (time, attempts, etc.)
- `:include_sample_data` - Include original sample data
- `:transform` - Transformation function applied to each label

### Agreement Export

Special export format for agreement analysis:

```elixir
Anvil.export_agreement(queue,
  format: :csv,
  path: "/path/to/agreement.csv",
  metric: :fleiss
)
```

Output:
```csv
sample_id,num_raters,fleiss_kappa,interpretation,labels
s1,3,0.85,almost_perfect,"[""cat"",""cat"",""dog""]"
s2,3,1.00,perfect,"[""dog"",""dog"",""dog""]"
```

## Consequences

### Positive

- **Compatibility**: CSV ensures maximum tool support
- **Flexibility**: JSONL handles complex schemas
- **Extensibility**: Custom exporters for specific needs
- **Streaming**: Memory-efficient for large datasets
- **Filtering**: Export only relevant labels

### Negative

- **Format Proliferation**: Risk of too many exporters
- **Maintenance**: Each exporter needs testing and updates
- **Documentation**: Users need guidance on format selection
- **Performance**: Some formats (JSON) are slower than others

### Mitigation

- Limit built-in formats to 2-3 most common
- Provide clear format selection guide
- Benchmark all exporters
- Document performance characteristics
- Add streaming support for large exports

## Implementation Details

### Performance Considerations

```elixir
# Stream-based processing to avoid loading all labels
defmodule Anvil.Export do
  def export_large_dataset(queue, opts) do
    Queue.stream_labels(queue)
    |> Stream.chunk_every(1000)
    |> Stream.map(&export_chunk/1)
    |> Stream.run()
  end
end
```

### Error Handling

```elixir
# Handle export errors gracefully
def export(queue, opts) do
  with {:ok, labels} <- get_labels(queue),
       {:ok, path} <- validate_path(opts[:path]),
       :ok <- ensure_directory_exists(path),
       :ok <- write_export(labels, path, opts) do
    :ok
  else
    {:error, reason} -> {:error, reason}
  end
rescue
  e -> {:error, {:export_failed, e}}
end
```

### Validation

```elixir
# Validate exported data
defmodule Anvil.Export.Validator do
  def validate_export(path, format) do
    # Read back exported file
    # Verify format correctness
    # Check row counts
    # Validate data integrity
  end
end
```

## Alternatives Considered

### 1. Only Support JSON

**Rejected** because:
- Not as widely supported as CSV
- Overkill for simple tabular data
- Harder for non-technical users

### 2. Support Every Format (CSV, JSON, XML, Parquet, Avro, etc.)

**Rejected** because:
- Too much maintenance burden
- Most use cases covered by CSV + JSONL
- Can be added as custom exporters if needed

### 3. Database Direct Export

**Rejected** because:
- Couples export to storage implementation
- Harder to test
- Less portable
- Can be added as custom exporter

### 4. Cloud Storage Integration (S3, GCS, etc.)

**Rejected** for v1 because:
- Adds external dependencies
- Complicates testing
- Can be layered on top
- Users can upload files themselves

## Future Enhancements

### Possible v2 Features

1. **Parquet Export**: Columnar format for big data analytics
2. **Excel Export**: Direct .xlsx generation
3. **Cloud Upload**: Built-in S3/GCS upload
4. **Incremental Export**: Only export new labels since last export
5. **Compression**: Automatic gzip/bzip2 compression
6. **Format Conversion**: Convert between formats

### Extension Points

```elixir
# Hook for pre-export transformations
defmodule Anvil.Export.Hook do
  @callback before_export(labels :: [Label.t()]) :: [Label.t()]
  @callback after_export(path :: String.t()) :: :ok
end

# Hook for custom metadata
defmodule Anvil.Export.Metadata do
  @callback metadata(queue :: pid()) :: map()
end
```

## Testing Strategy

Each exporter includes:

```elixir
defmodule Anvil.Export.CSVTest do
  use Supertester.ExUnitFoundation, isolation: :full_isolation

  test "exports valid CSV" do
    queue = setup_queue_with_labels()

    path = temp_file_path()
    :ok = Anvil.export(queue, format: :csv, path: path)

    # Verify CSV is valid
    assert File.exists?(path)
    assert valid_csv?(path)
  end

  performance "exports large datasets efficiently" do
    queue = setup_queue_with_labels(10_000)

    assert_performs fn ->
      Anvil.export(queue, format: :csv, path: temp_file_path())
    end, under: :seconds, count: 1
  end
end
```

## References

- [CSV RFC 4180](https://tools.ietf.org/html/rfc4180)
- [JSON Lines Format](https://jsonlines.org/)
- [Apache Parquet](https://parquet.apache.org/)
- [Data Export Best Practices](https://www.oreilly.com/library/view/designing-data-intensive-applications/9781491903063/)
