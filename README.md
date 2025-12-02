# Anvil

![Anvil Logo](assets/anvil.svg)

[![Hex.pm](https://img.shields.io/hexpm/v/anvil.svg)](https://hex.pm/packages/anvil)
[![Documentation](https://img.shields.io/badge/docs-hexpm-blue.svg)](https://hexdocs.pm/anvil)

Labeling queue library for managing human labeling workflows. Anvil is a domain-agnostic system for orchestrating human annotation tasks across any sample type - images, text, audio, video, or custom data structures.

## Purpose

Anvil provides a robust foundation for building human-in-the-loop machine learning systems. It handles the complexity of:

- **Queue Management**: Distribute samples to human labelers efficiently
- **Assignment Policies**: Control how work is allocated (round-robin, random, expertise-based)
- **Label Validation**: Ensure label quality with schema-based validation
- **Inter-Rater Reliability**: Compute agreement metrics (Cohen's kappa, Fleiss' kappa, Krippendorff's alpha)
- **Export & Integration**: Export labeled data in multiple formats (CSV, JSONL)

## Core Abstractions

### LabelSchema

Defines the structure and validation rules for labels. Schemas are domain-agnostic and support various field types:

```elixir
schema = Anvil.Schema.new(
  name: "image_classification",
  fields: [
    %Anvil.Schema.Field{
      name: "category",
      type: :select,
      required: true,
      options: ["cat", "dog", "bird"]
    },
    %Anvil.Schema.Field{
      name: "confidence",
      type: :range,
      required: true,
      min: 1,
      max: 5
    },
    %Anvil.Schema.Field{
      name: "notes",
      type: :text,
      required: false
    }
  ]
)
```

### Queue

Manages the distribution of samples to labelers. Queues track assignments, handle retries, and enforce deadlines:

```elixir
{:ok, queue} = Anvil.Queue.start_link(
  queue_id: "image_queue_1",
  schema: schema,
  policy: :round_robin,
  labels_per_sample: 3,  # Multiple labelers for agreement metrics
  assignment_timeout: 3600  # 1 hour timeout
)
```

### Assignment

Represents a single labeling task assigned to a specific labeler. Tracks lifecycle states:

- `:pending` - Created but not yet started
- `:in_progress` - Labeler is actively working
- `:completed` - Label submitted and validated
- `:expired` - Deadline passed without completion
- `:skipped` - Labeler chose to skip

### Label

The actual annotation data submitted by a labeler. Labels are validated against the schema:

```elixir
label = Anvil.submit_label(assignment_id, %{
  "category" => "cat",
  "confidence" => 4,
  "notes" => "Clear image, definitely a cat"
})
```

### Agreement

Compute inter-rater reliability metrics when multiple labelers annotate the same samples:

```elixir
# Cohen's kappa for 2 raters
{:ok, kappa} = Anvil.Agreement.Cohen.compute(labels1, labels2)

# Fleiss' kappa for n raters
{:ok, kappa} = Anvil.Agreement.Fleiss.compute(all_labels)

# Krippendorff's alpha (works with missing data)
{:ok, alpha} = Anvil.Agreement.Krippendorff.compute(all_labels)
```

### Export

Export labeled data for downstream processing:

```elixir
# Export to CSV
Anvil.Export.CSV.export(queue_id, "/path/to/output.csv")

# Export to JSONL (JSON Lines)
Anvil.Export.JSONL.export(queue_id, "/path/to/output.jsonl")
```

## Installation

Add `anvil` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:anvil, "~> 0.1.0"}
  ]
end
```

## Usage Examples

### Basic Workflow

```elixir
# 1. Define your labeling schema
schema = Anvil.Schema.new(
  name: "sentiment_analysis",
  fields: [
    %Anvil.Schema.Field{
      name: "sentiment",
      type: :select,
      required: true,
      options: ["positive", "negative", "neutral"]
    },
    %Anvil.Schema.Field{
      name: "intensity",
      type: :range,
      required: true,
      min: 1,
      max: 10
    }
  ]
)

# 2. Create a queue
{:ok, queue} = Anvil.create_queue(
  queue_id: "sentiment_queue",
  schema: schema,
  policy: :round_robin
)

# 3. Add samples to the queue
samples = [
  %{id: "sample_1", text: "This movie was amazing!"},
  %{id: "sample_2", text: "Terrible experience, would not recommend."},
  %{id: "sample_3", text: "It was okay, nothing special."}
]

Anvil.add_samples(queue, samples)

# 4. Assign samples to labelers
labelers = ["labeler_1", "labeler_2", "labeler_3"]
Anvil.add_labelers(queue, labelers)

# 5. Get next assignment for a labeler
{:ok, assignment} = Anvil.get_next_assignment(queue, "labeler_1")

# 6. Submit a label
{:ok, label} = Anvil.submit_label(assignment.id, %{
  "sentiment" => "positive",
  "intensity" => 9
})

# 7. Check agreement between labelers
{:ok, agreement} = Anvil.compute_agreement(queue, sample_id: "sample_1")

# 8. Export results
Anvil.export(queue, format: :csv, path: "labels.csv")
```

### Advanced: Custom Assignment Policies

```elixir
# Define a custom policy based on labeler expertise
policy = %Anvil.Queue.Policy{
  type: :expertise,
  config: %{
    expertise_scores: %{
      "expert_1" => 0.95,
      "expert_2" => 0.87,
      "novice_1" => 0.45
    },
    min_expertise: 0.7  # Only assign to labelers above this threshold
  }
}

{:ok, queue} = Anvil.create_queue(
  queue_id: "expert_queue",
  schema: schema,
  policy: policy
)
```

### Advanced: Label Quality Control

```elixir
# Configure quality control measures
{:ok, queue} = Anvil.create_queue(
  queue_id: "qc_queue",
  schema: schema,
  quality_control: %{
    consensus_threshold: 0.8,  # Require 80% agreement
    gold_standard_samples: ["sample_1", "sample_2"],  # Known correct labels
    max_attempts_per_labeler: 3,  # Limit retries
    min_labeling_time: 5  # Minimum seconds to prevent rushing
  }
)
```

## API Documentation

### Core API

#### `Anvil.create_queue/1`

Creates a new labeling queue.

**Parameters:**
- `opts` - Keyword list of options
  - `:queue_id` - Unique identifier for the queue
  - `:schema` - LabelSchema defining the label structure
  - `:policy` - Assignment policy (`:round_robin`, `:random`, `:expertise`)
  - `:labels_per_sample` - Number of labels needed per sample (default: 1)
  - `:assignment_timeout` - Timeout in seconds (default: 3600)

**Returns:** `{:ok, pid}` or `{:error, reason}`

#### `Anvil.add_samples/2`

Adds samples to a queue for labeling.

**Parameters:**
- `queue` - Queue PID or name
- `samples` - List of sample maps (must include `:id` field)

**Returns:** `:ok` or `{:error, reason}`

#### `Anvil.get_next_assignment/2`

Gets the next assignment for a labeler.

**Parameters:**
- `queue` - Queue PID or name
- `labeler_id` - Identifier for the labeler

**Returns:** `{:ok, assignment}` or `{:error, :no_samples_available}`

#### `Anvil.submit_label/2`

Submits a label for an assignment.

**Parameters:**
- `assignment_id` - The assignment identifier
- `values` - Map of field names to values

**Returns:** `{:ok, label}` or `{:error, validation_errors}`

#### `Anvil.compute_agreement/2`

Computes inter-rater agreement metrics.

**Parameters:**
- `queue` - Queue PID or name
- `opts` - Options
  - `:sample_id` - Compute for specific sample
  - `:metric` - Metric type (`:cohen`, `:fleiss`, `:krippendorff`)

**Returns:** `{:ok, metric_value}` or `{:error, reason}`

#### `Anvil.export/2`

Exports labeled data.

**Parameters:**
- `queue` - Queue PID or name
- `opts` - Options
  - `:format` - Export format (`:csv`, `:jsonl`)
  - `:path` - Output file path
  - `:filter` - Filter function for samples

**Returns:** `:ok` or `{:error, reason}`

### Schema API

#### `Anvil.Schema.new/1`

Creates a new label schema.

#### `Anvil.Schema.validate/2`

Validates label values against a schema.

#### `Anvil.Schema.Field.types/0`

Returns list of supported field types: `:text`, `:select`, `:multiselect`, `:range`, `:boolean`, `:date`, `:datetime`, `:number`

### Agreement API

#### `Anvil.Agreement.Cohen.compute/2`

Computes Cohen's kappa for two raters.

#### `Anvil.Agreement.Fleiss.compute/1`

Computes Fleiss' kappa for n raters.

#### `Anvil.Agreement.Krippendorff.compute/2`

Computes Krippendorff's alpha with configurable distance metrics.

## Architecture

Anvil is built on OTP principles:

- **Supervision Tree**: Automatic restart of failed processes
- **GenServer Queues**: Each queue runs in its own process
- **Storage Behaviour**: Pluggable storage backends (ETS, Postgres, etc.)
- **Isolated Testing**: Full process isolation in tests using Supertester

## Testing

Run the test suite:

```bash
mix test
```

Run with coverage:

```bash
mix test --cover
```

## Contributing

Contributions are welcome! Please see [CONTRIBUTING.md](CONTRIBUTING.md) for details.

## License

MIT License - see [LICENSE](LICENSE) for details.

## Acknowledgments

Built by the North Shore AI team for the machine learning community.
