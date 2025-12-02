# Anvil

<div align="center">

<svg width="140" height="140" viewBox="0 0 200 200" xmlns="http://www.w3.org/2000/svg">
  <!-- Definitions -->
  <defs>
    <!-- Metallic Gradient - Base -->
    <linearGradient id="metalBase" x1="0%" y1="0%" x2="0%" y2="100%">
      <stop offset="0%" style="stop-color:#e8eaed;stop-opacity:1" />
      <stop offset="25%" style="stop-color:#b8bec5;stop-opacity:1" />
      <stop offset="50%" style="stop-color:#8a9199;stop-opacity:1" />
      <stop offset="75%" style="stop-color:#5f6873;stop-opacity:1" />
      <stop offset="100%" style="stop-color:#3a4149;stop-opacity:1" />
    </linearGradient>

    <!-- Anvil Gradient - Dark Steel -->
    <linearGradient id="anvilGradient" x1="0%" y1="0%" x2="100%" y2="100%">
      <stop offset="0%" style="stop-color:#4a5563;stop-opacity:1" />
      <stop offset="50%" style="stop-color:#2d3540;stop-opacity:1" />
      <stop offset="100%" style="stop-color:#1a1f26;stop-opacity:1" />
    </linearGradient>

    <!-- Highlight Gradient -->
    <linearGradient id="highlight" x1="0%" y1="0%" x2="100%" y2="100%">
      <stop offset="0%" style="stop-color:#ffffff;stop-opacity:0.8" />
      <stop offset="100%" style="stop-color:#ffffff;stop-opacity:0" />
    </linearGradient>

    <!-- Hexagon Background Gradient -->
    <linearGradient id="hexBg" x1="0%" y1="0%" x2="0%" y2="100%">
      <stop offset="0%" style="stop-color:#6b7280;stop-opacity:1" />
      <stop offset="50%" style="stop-color:#4b5563;stop-opacity:1" />
      <stop offset="100%" style="stop-color:#374151;stop-opacity:1" />
    </linearGradient>

    <!-- Inner Glow -->
    <radialGradient id="innerGlow" cx="50%" cy="50%" r="50%">
      <stop offset="0%" style="stop-color:#ffffff;stop-opacity:0.3" />
      <stop offset="50%" style="stop-color:#9ca3af;stop-opacity:0.1" />
      <stop offset="100%" style="stop-color:#4b5563;stop-opacity:0" />
    </radialGradient>

    <!-- Shadow Filter -->
    <filter id="shadow" x="-50%" y="-50%" width="200%" height="200%">
      <feGaussianBlur in="SourceAlpha" stdDeviation="3"/>
      <feOffset dx="2" dy="2" result="offsetblur"/>
      <feComponentTransfer>
        <feFuncA type="linear" slope="0.4"/>
      </feComponentTransfer>
      <feMerge>
        <feMergeNode/>
        <feMergeNode in="SourceGraphic"/>
      </feMerge>
    </filter>

    <!-- Inner Shadow -->
    <filter id="innerShadow" x="-50%" y="-50%" width="200%" height="200%">
      <feGaussianBlur in="SourceGraphic" stdDeviation="2" result="blur"/>
      <feOffset in="blur" dx="1" dy="1" result="offsetBlur"/>
      <feFlood flood-color="#000000" flood-opacity="0.3" result="offsetColor"/>
      <feComposite in="offsetColor" in2="offsetBlur" operator="in" result="offsetBlur"/>
      <feMerge>
        <feMergeNode in="SourceGraphic"/>
        <feMergeNode in="offsetBlur"/>
      </feMerge>
    </filter>

    <!-- Metallic Texture Pattern -->
    <pattern id="metallicTexture" x="0" y="0" width="4" height="4" patternUnits="userSpaceOnUse">
      <rect x="0" y="0" width="4" height="4" fill="#4b5563" opacity="0.1"/>
      <line x1="0" y1="0" x2="4" y2="4" stroke="#6b7280" stroke-width="0.5" opacity="0.2"/>
      <line x1="4" y1="0" x2="0" y2="4" stroke="#374151" stroke-width="0.5" opacity="0.2"/>
    </pattern>
  </defs>

  <!-- Outer Hexagon Border -->
  <polygon points="100,10 173.2,52.5 173.2,137.5 100,180 26.8,137.5 26.8,52.5"
           fill="url(#hexBg)"
           stroke="#9ca3af"
           stroke-width="2"
           filter="url(#shadow)"/>

  <!-- Inner Hexagon -->
  <polygon points="100,20 165.8,57.5 165.8,132.5 100,170 34.2,132.5 34.2,57.5"
           fill="url(#metalBase)"
           stroke="#6b7280"
           stroke-width="1.5"/>

  <!-- Texture Overlay -->
  <polygon points="100,20 165.8,57.5 165.8,132.5 100,170 34.2,132.5 34.2,57.5"
           fill="url(#metallicTexture)"
           opacity="0.3"/>

  <!-- Geometric Pattern Layer 1 - Outer Triangles -->
  <path d="M 100,20 L 165.8,57.5 L 100,57.5 Z" fill="#4b5563" opacity="0.3"/>
  <path d="M 165.8,57.5 L 165.8,132.5 L 132.9,95 Z" fill="#374151" opacity="0.3"/>
  <path d="M 165.8,132.5 L 100,170 L 132.9,132.5 Z" fill="#4b5563" opacity="0.3"/>
  <path d="M 100,170 L 34.2,132.5 L 67.1,132.5 Z" fill="#374151" opacity="0.3"/>
  <path d="M 34.2,132.5 L 34.2,57.5 L 67.1,95 Z" fill="#4b5563" opacity="0.3"/>
  <path d="M 34.2,57.5 L 100,20 L 67.1,57.5 Z" fill="#374151" opacity="0.3"/>

  <!-- Geometric Pattern Layer 2 - Inner Hexagon Frame -->
  <polygon points="100,45 143.3,67.5 143.3,112.5 100,135 56.7,112.5 56.7,67.5"
           fill="none"
           stroke="#9ca3af"
           stroke-width="1.5"
           opacity="0.4"/>

  <!-- Geometric Pattern Layer 3 - Star Pattern -->
  <line x1="100" y1="45" x2="100" y2="135" stroke="#6b7280" stroke-width="1" opacity="0.3"/>
  <line x1="56.7" y1="67.5" x2="143.3" y2="112.5" stroke="#6b7280" stroke-width="1" opacity="0.3"/>
  <line x1="56.7" y1="112.5" x2="143.3" y2="67.5" stroke="#6b7280" stroke-width="1" opacity="0.3"/>

  <!-- Central Anvil Design -->
  <g transform="translate(100, 95)" filter="url(#innerShadow)">
    <!-- Anvil Base -->
    <rect x="-32" y="20" width="64" height="12" rx="2" fill="url(#anvilGradient)" stroke="#1a1f26" stroke-width="1"/>

    <!-- Anvil Body -->
    <path d="M -28,20 L -28,-5 L -22,-10 L 22,-10 L 28,-5 L 28,20 Z"
          fill="url(#anvilGradient)"
          stroke="#1a1f26"
          stroke-width="1.2"/>

    <!-- Anvil Horn (left) -->
    <path d="M -28,-5 L -38,-5 L -38,-2 L -28,-2 Z"
          fill="#2d3540"
          stroke="#1a1f26"
          stroke-width="1"/>

    <!-- Anvil Horn (right) - smaller -->
    <path d="M 28,-5 L 34,-5 L 34,-2 L 28,-2 Z"
          fill="#2d3540"
          stroke="#1a1f26"
          stroke-width="1"/>

    <!-- Anvil Face Detail -->
    <rect x="-22" y="-8" width="44" height="6" fill="#4a5563" opacity="0.6"/>

    <!-- Metallic Highlight on Top -->
    <path d="M -20,-10 L -22,-10 L -22,-6 L 22,-6 L 22,-10 L 20,-10 Z"
          fill="url(#highlight)"
          opacity="0.5"/>

    <!-- Rivet Details -->
    <circle cx="-18" cy="0" r="1.5" fill="#1a1f26" stroke="#4a5563" stroke-width="0.5"/>
    <circle cx="-8" cy="0" r="1.5" fill="#1a1f26" stroke="#4a5563" stroke-width="0.5"/>
    <circle cx="8" cy="0" r="1.5" fill="#1a1f26" stroke="#4a5563" stroke-width="0.5"/>
    <circle cx="18" cy="0" r="1.5" fill="#1a1f26" stroke="#4a5563" stroke-width="0.5"/>

    <!-- Wear Lines on Anvil Face -->
    <line x1="-15" y1="-7" x2="15" y2="-7" stroke="#5f6873" stroke-width="0.5" opacity="0.4"/>
    <line x1="-18" y1="-5" x2="18" y2="-5" stroke="#5f6873" stroke-width="0.5" opacity="0.4"/>
    <line x1="-15" y1="-3" x2="15" y2="-3" stroke="#5f6873" stroke-width="0.5" opacity="0.4"/>

    <!-- Base Shadow -->
    <ellipse cx="0" cy="32" rx="32" ry="3" fill="#000000" opacity="0.2"/>

    <!-- Metallic Sheen -->
    <path d="M -24,-8 Q -20,-10 0,-10 Q 20,-10 24,-8"
          fill="none"
          stroke="#ffffff"
          stroke-width="1"
          opacity="0.3"/>
  </g>

  <!-- Corner Accent Details -->
  <circle cx="100" cy="20" r="3" fill="#9ca3af" opacity="0.5"/>
  <circle cx="165.8" cy="57.5" r="3" fill="#9ca3af" opacity="0.5"/>
  <circle cx="165.8" cy="132.5" r="3" fill="#9ca3af" opacity="0.5"/>
  <circle cx="100" cy="170" r="3" fill="#9ca3af" opacity="0.5"/>
  <circle cx="34.2" cy="132.5" r="3" fill="#9ca3af" opacity="0.5"/>
  <circle cx="34.2" cy="57.5" r="3" fill="#9ca3af" opacity="0.5"/>

  <!-- Highlight Overlay on Hexagon -->
  <polygon points="100,20 165.8,57.5 165.8,95 100,57.5"
           fill="url(#innerGlow)"
           opacity="0.4"/>

  <!-- Technical Grid Pattern -->
  <line x1="67.1" y1="57.5" x2="100" y2="95" stroke="#6b7280" stroke-width="0.5" opacity="0.2"/>
  <line x1="132.9" y1="57.5" x2="100" y2="95" stroke="#6b7280" stroke-width="0.5" opacity="0.2"/>
  <line x1="67.1" y1="132.5" x2="100" y2="95" stroke="#6b7280" stroke-width="0.5" opacity="0.2"/>
  <line x1="132.9" y1="132.5" x2="100" y2="95" stroke="#6b7280" stroke-width="0.5" opacity="0.2"/>

  <!-- Outer Glow Effect -->
  <polygon points="100,10 173.2,52.5 173.2,137.5 100,180 26.8,137.5 26.8,52.5"
           fill="none"
           stroke="#b8bec5"
           stroke-width="0.5"
           opacity="0.3"/>
</svg>

</div>

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
