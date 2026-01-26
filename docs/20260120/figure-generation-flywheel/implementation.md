# Publication-Quality Figure Generation Flywheel

## Technical Implementation Document

**Date:** 2026-01-20
**Status:** Draft
**Author:** NSAI Architecture
**Related ADRs:** ADR-001 through ADR-010

---

## 1. Problem Statement

### 1.1 The Goal

Build a system that generates publication-quality SVG figures (Nature, Science, Cell tier) from structured specifications, where human feedback continuously improves generation quality through automated prompt optimization.

### 1.2 Why This Is Hard

World-class scientific figures exhibit properties that are difficult to formalize:

| Property | Description | Formalizable? |
|----------|-------------|---------------|
| Syntactic validity | Parses as SVG, renders correctly | Yes |
| Structural correctness | Required elements present, data points mapped | Yes |
| Style compliance | Colors, fonts, dimensions match journal spec | Yes (with rules) |
| Visual hierarchy | Eye drawn to key findings | Partially |
| Aesthetic quality | "Looks professional" | No |

The unformalizable properties require human judgment. The system must encode that judgment over time.

### 1.3 The Insight

Manual prompting is prototyping. Every iteration session generates training data:

- The specification provided
- The output received
- What the human did next (accepted, revised, rejected)
- The revision diff (highest signal)

This feedback can train DSPex to optimize the generation prompt, creating a flywheel where human taste gets encoded into the system.

---

## 2. Architecture Overview

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                              Figure Specification                            │
│                    (data + figure_type + style + constraints)                │
└─────────────────────────────────────────────────────────────────────────────┘
                                        │
                                        ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│                           FORGE: Generation Pipeline                         │
│  ┌──────────────┐   ┌──────────────┐   ┌──────────────┐                    │
│  │ Source.Spec  │ → │ Stage.LLM    │ → │ Measurements │                    │
│  │ (fig specs)  │   │ (DSPex opt.) │   │ (validation) │                    │
│  └──────────────┘   └──────────────┘   └──────────────┘                    │
│                            ↑                                                │
│                            │ Optimized Prompt                               │
│                            │                                                │
└────────────────────────────┼────────────────────────────────────────────────┘
                             │
                             │
┌────────────────────────────┼────────────────────────────────────────────────┐
│                            │          ANVIL: Review Queue                    │
│                            │                                                │
│  ┌──────────────┐   ┌─────┴────────┐   ┌──────────────┐                    │
│  │ ForgeBridge  │ → │    Queue     │ → │   Storage    │                    │
│  │ (samples)    │   │ (lifecycle)  │   │ (Postgres)   │                    │
│  └──────────────┘   └──────────────┘   └──────────────┘                    │
│                            │                   │                            │
│                            ▼                   │                            │
│                   ┌──────────────┐             │                            │
│                   │  Optimizer   │ ◄───────────┘                            │
│                   │  (DSPex)     │    Labels + Revisions                    │
│                   └──────────────┘                                          │
│                            │                                                │
└────────────────────────────┼────────────────────────────────────────────────┘
                             │
                             │ Updated Prompt
                             ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│                           INGOT: Review Interface                            │
│  ┌──────────────┐   ┌──────────────┐   ┌──────────────┐                    │
│  │ SVG Preview  │   │ Accept/Reject│   │ Inline Edit  │                    │
│  │ (rendered)   │   │ (keyboard)   │   │ (revision)   │                    │
│  └──────────────┘   └──────────────┘   └──────────────┘                    │
└─────────────────────────────────────────────────────────────────────────────┘
```

### 2.1 Component Mapping

| Component | Project | Role |
|-----------|---------|------|
| Generation | Forge | LLM generates SVG from specs via DSPex-optimized prompts |
| Validation | Forge.Measurement | Automated checks (syntax, structure, style rules) |
| Review Queue | Anvil | Lifecycle management, label storage |
| Review UI | Ingot | Human accepts/rejects/revises figures |
| Optimization | Anvil.Optimizer (new) | Closes the loop: labels → DSPex → updated prompts |

---

## 3. Figure Specification Schema

### 3.1 Core Specification Structure

```elixir
defmodule FigForge.Spec do
  @moduledoc """
  Structured specification for figure generation.
  Must be complete enough that generation is deterministic given this spec.
  """

  use TypedStruct

  typedstruct do
    field :id, String.t(), enforce: true
    field :figure_type, figure_type(), enforce: true
    field :style, style_spec(), enforce: true
    field :data, data_spec(), enforce: true
    field :panels, list(panel_spec()), default: []
    field :annotations, list(annotation()), default: []
    field :constraints, constraints(), default: %{}
    field :metadata, map(), default: %{}
  end

  @type figure_type ::
    :line_plot | :scatter | :bar | :heatmap | :violin |
    :box | :histogram | :multi_panel | :network | :custom

  @type style_spec :: %{
    journal: :nature | :science | :cell | :pnas | :elife | :custom,
    width: :single_column | :double_column | :full_page | {:mm, number()},
    colorblind_safe: boolean(),
    custom_overrides: map()
  }

  @type data_spec :: %{
    series: list(series()),
    x_var: String.t(),
    y_var: String.t(),
    group_var: String.t() | nil,
    error_var: String.t() | nil,
    labels: %{x: String.t(), y: String.t()}
  }

  @type panel_spec :: %{
    id: atom(),
    position: {non_neg_integer(), non_neg_integer()},
    span: {pos_integer(), pos_integer()},
    figure_type: figure_type(),
    data: data_spec()
  }
end
```

### 3.2 Journal Style Specifications

```elixir
defmodule FigForge.Styles do
  @moduledoc """
  Codified style guides from top journals.
  Derived from actual submission guidelines.
  """

  def nature do
    %{
      name: :nature,
      dimensions: %{
        single_column: {89, :mm},
        double_column: {183, :mm},
        max_height: {247, :mm}
      },
      fonts: %{
        primary: "Helvetica",
        fallback: ["Arial", "sans-serif"],
        axis_label_size: 7,      # points
        tick_label_size: 6,
        panel_label_size: 8,
        panel_label_weight: :bold
      },
      colors: %{
        primary: ["#E64B35", "#4DBBD5", "#00A087", "#3C5488", "#F39B7F"],
        colorblind_safe: ["#0072B2", "#D55E00", "#009E73", "#CC79A7", "#F0E442"],
        sequential: :viridis,
        diverging: :RdBu
      },
      lines: %{
        width: 0.5,
        data_line_width: 1.0,
        marker_size: 4,
        error_cap_size: 2
      },
      panels: %{
        label_style: :lowercase,  # a, b, c
        label_position: :top_left,
        label_offset: {-0.1, 1.05},
        spacing: 0.15
      },
      axes: %{
        spine_width: 0.5,
        tick_direction: :out,
        tick_length: 3,
        tick_width: 0.5
      }
    }
  end

  def science, do: # ... similar structure
  def cell, do: # ... similar structure
end
```

---

## 4. Forge Pipeline: SVG Generation

### 4.1 Pipeline Definition

```elixir
defmodule FigForge.Pipeline do
  @moduledoc """
  Forge pipeline for figure generation.
  Produces SVG samples from specifications.
  """

  use Forge.Pipeline

  pipeline :figure_generation do
    # Input: structured figure specifications
    source FigForge.Source.Specs,
      batch_size: 10

    # Generation stage (DSPex-optimized prompt)
    stage FigForge.Stages.Generate,
      timeout: 60_000,
      retry: [max_attempts: 2, backoff: :exponential]

    # Automated validation measurements
    measurement FigForge.Measurements.SVGValidity
    measurement FigForge.Measurements.StructuralIntegrity
    measurement FigForge.Measurements.StyleCompliance
    measurement FigForge.Measurements.DataIntegrity

    # Storage
    storage Forge.Storage.Postgres,
      table: :figure_samples
  end
end
```

### 4.2 Generation Stage

```elixir
defmodule FigForge.Stages.Generate do
  @moduledoc """
  LLM-powered SVG generation stage.
  Uses DSPex module with learnable prompt.
  """

  @behaviour Forge.Stage

  alias FigForge.Prompts.FigureGenerator

  @impl true
  def process(sample, _opts) do
    spec = sample.data
    style = FigForge.Styles.get(spec.style.journal)

    case FigureGenerator.generate(spec, style) do
      {:ok, svg} ->
        enriched = Map.merge(spec, %{
          svg: svg,
          generated_at: DateTime.utc_now(),
          generator_version: FigureGenerator.version()
        })
        {:ok, %{sample | data: enriched}}

      {:error, reason} ->
        {:skip, %{reason: reason, spec_id: spec.id}}
    end
  end

  @impl true
  def name, do: "figure_generate"
end
```

### 4.3 DSPex Generator Module

```elixir
defmodule FigForge.Prompts.FigureGenerator do
  @moduledoc """
  DSPex module for SVG generation.
  Prompt is optimizable via MIPRO based on feedback.
  """

  use DSPex.Module

  @signature """
  figure_spec: The structured specification including data, figure type, and style requirements
  style_config: Journal-specific style parameters (fonts, colors, dimensions)
  ->
  svg_code: Complete, valid SVG markup that renders the figure
  """

  # Learnable instruction prefix (optimized by DSPex)
  @instruction """
  You are an expert scientific visualization designer. Generate publication-quality
  SVG figures that would be accepted by Nature, Science, or Cell.

  Requirements:
  - Output valid SVG that renders correctly
  - Follow the exact style specifications (fonts, colors, dimensions)
  - Ensure all data points are accurately represented
  - Use proper visual hierarchy to guide the reader
  - Include all required elements (axes, labels, legends, panel labels)
  - Maintain professional aesthetics with appropriate whitespace

  The SVG must be complete and self-contained.
  """

  @impl true
  def forward(inputs, opts \\ []) do
    spec = inputs.figure_spec
    style = inputs.style_config

    prompt = build_prompt(spec, style)

    case DSPex.LM.complete(prompt, opts) do
      {:ok, response} ->
        extract_svg(response)
      error ->
        error
    end
  end

  defp build_prompt(spec, style) do
    """
    #{@instruction}

    ## Figure Specification

    Type: #{spec.figure_type}
    Dimensions: #{format_dimensions(spec, style)}

    ### Data
    #{format_data(spec.data)}

    ### Style Configuration
    #{format_style(style)}

    ### Panel Layout
    #{format_panels(spec.panels)}

    ### Annotations
    #{format_annotations(spec.annotations)}

    Generate the complete SVG now. Output only the SVG markup, no explanation.
    """
  end

  # Version tracking for reproducibility
  def version do
    # Hash of current instruction + prompt template
    :crypto.hash(:sha256, @instruction)
    |> Base.encode16(case: :lower)
    |> String.slice(0, 8)
  end

  # Called by Optimizer to update learned prompt
  def update(optimized_params) do
    # Hot-swap the instruction prefix
    # Implementation depends on DSPex state management
  end
end
```

---

## 5. Automated Measurements

### 5.1 SVG Validity

```elixir
defmodule FigForge.Measurements.SVGValidity do
  @moduledoc """
  Validates SVG is syntactically correct and renderable.
  """

  @behaviour Forge.Measurement

  @impl true
  def name, do: :svg_validity

  @impl true
  def measure(sample) do
    svg = sample.data.svg

    checks = [
      {:parseable, check_parseable(svg)},
      {:has_root_svg, check_root_element(svg)},
      {:valid_viewbox, check_viewbox(svg)},
      {:no_broken_refs, check_references(svg)}
    ]

    failed = Enum.filter(checks, fn {_, result} -> result != :ok end)

    %{
      valid: Enum.empty?(failed),
      checks: Map.new(checks),
      failed: Enum.map(failed, &elem(&1, 0))
    }
  end

  defp check_parseable(svg) do
    case Floki.parse_document(svg) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp check_root_element(svg) do
    case Floki.parse_document(svg) do
      {:ok, doc} ->
        if Floki.find(doc, "svg") != [], do: :ok, else: {:error, :no_svg_root}
      _ ->
        {:error, :parse_failed}
    end
  end

  defp check_viewbox(svg) do
    case Floki.parse_document(svg) do
      {:ok, doc} ->
        svg_elem = Floki.find(doc, "svg") |> List.first()
        viewbox = Floki.attribute(svg_elem, "viewBox") |> List.first()
        if viewbox, do: :ok, else: {:error, :no_viewbox}
      _ ->
        {:error, :parse_failed}
    end
  end

  defp check_references(svg) do
    # Check that all href/xlink:href references resolve
    # ... implementation
    :ok
  end
end
```

### 5.2 Style Compliance

```elixir
defmodule FigForge.Measurements.StyleCompliance do
  @moduledoc """
  Validates SVG adheres to journal style specifications.
  """

  @behaviour Forge.Measurement

  @impl true
  def name, do: :style_compliance

  @impl true
  def measure(sample) do
    svg = sample.data.svg
    spec = sample.data
    style = FigForge.Styles.get(spec.style.journal)

    checks = [
      {:dimensions, check_dimensions(svg, spec, style)},
      {:font_family, check_fonts(svg, style)},
      {:font_sizes, check_font_sizes(svg, style)},
      {:color_palette, check_colors(svg, style)},
      {:line_weights, check_line_weights(svg, style)}
    ]

    scores = Enum.map(checks, fn {name, result} ->
      {name, compliance_score(result)}
    end)

    %{
      overall_score: Enum.sum(Enum.map(scores, &elem(&1, 1))) / length(scores),
      checks: Map.new(scores),
      violations: extract_violations(checks)
    }
  end

  defp check_colors(svg, style) do
    # Extract all colors used in SVG
    used_colors = extract_colors(svg)

    # Check against allowed palette
    allowed = MapSet.new(style.colors.primary ++ style.colors.colorblind_safe)
    violations = Enum.reject(used_colors, &MapSet.member?(allowed, normalize_color(&1)))

    %{compliant: Enum.empty?(violations), violations: violations}
  end

  defp check_fonts(svg, style) do
    used_fonts = extract_font_families(svg)
    allowed = [style.fonts.primary | style.fonts.fallback]

    violations = Enum.reject(used_fonts, fn font ->
      Enum.any?(allowed, &String.contains?(font, &1))
    end)

    %{compliant: Enum.empty?(violations), violations: violations}
  end

  # ... additional checks
end
```

### 5.3 Data Integrity

```elixir
defmodule FigForge.Measurements.DataIntegrity do
  @moduledoc """
  Validates that all data points from spec are represented in SVG.
  """

  @behaviour Forge.Measurement

  @impl true
  def name, do: :data_integrity

  @impl true
  def measure(sample) do
    spec = sample.data
    svg = sample.data.svg

    expected_points = count_data_points(spec.data)
    rendered_points = count_rendered_points(svg, spec.figure_type)

    %{
      expected: expected_points,
      rendered: rendered_points,
      complete: rendered_points >= expected_points,
      coverage: rendered_points / max(expected_points, 1)
    }
  end

  defp count_data_points(data_spec) do
    data_spec.series
    |> Enum.map(&length(&1.points))
    |> Enum.sum()
  end

  defp count_rendered_points(svg, figure_type) do
    case figure_type do
      :line_plot -> count_path_points(svg)
      :scatter -> count_circle_elements(svg)
      :bar -> count_rect_elements(svg)
      # ... other types
    end
  end
end
```

---

## 6. Anvil Integration: Review Queue

### 6.1 Schema for SVG Review

```elixir
defmodule FigForge.ReviewSchema do
  @moduledoc """
  Anvil schema for figure review workflow.
  """

  def schema do
    Anvil.Schema.new(
      name: "figure_review",
      version: "1.0",
      fields: [
        %Anvil.Schema.Field{
          name: "quality",
          type: :select,
          required: true,
          options: ["accept", "needs_revision", "reject"],
          description: "Overall quality assessment"
        },
        %Anvil.Schema.Field{
          name: "style_score",
          type: :range,
          min: 1,
          max: 5,
          required: true,
          description: "Adherence to journal style (1=poor, 5=excellent)"
        },
        %Anvil.Schema.Field{
          name: "clarity_score",
          type: :range,
          min: 1,
          max: 5,
          required: true,
          description: "Data clarity and readability (1=poor, 5=excellent)"
        },
        %Anvil.Schema.Field{
          name: "revision_notes",
          type: :text,
          required: false,
          description: "What would you change? (captures implicit critique)"
        },
        %Anvil.Schema.Field{
          name: "revised_svg",
          type: :text,
          required: false,
          description: "Your corrected SVG (highest signal for training)"
        }
      ]
    )
  end
end
```

### 6.2 Queue Configuration

```elixir
defmodule FigForge.ReviewQueue do
  @moduledoc """
  Anvil queue configuration for figure review.
  """

  def create_queue(opts \\ []) do
    Anvil.create_queue(%{
      id: opts[:id] || "figure_review_#{Date.utc_today()}",
      schema: FigForge.ReviewSchema.schema(),
      policy: Anvil.Queue.Policy.RoundRobin,
      policy_config: %{},
      labels_per_sample: 1,  # Single reviewer per figure
      assignment_timeout: :timer.minutes(30),
      metadata: %{
        forge_pipeline: :figure_generation,
        component_module: "FigForge.Prompts.FigureGenerator"
      }
    })
  end

  def populate_from_forge(queue_id, opts \\ []) do
    # Fetch samples that passed automated measurements
    samples = Forge.Storage.query(:figure_samples, %{
      status: :measured,
      measurements: %{
        svg_validity: %{valid: true},
        style_compliance: %{overall_score: {:gte, 0.7}},
        data_integrity: %{complete: true}
      }
    }, limit: opts[:limit] || 100)

    # Transform to Anvil sample format
    anvil_samples = Enum.map(samples, fn sample ->
      %{
        id: sample.id,
        content: %{
          spec: sample.data,
          svg: sample.data.svg,
          measurements: sample.measurements
        },
        metadata: %{
          forge_sample_id: sample.id,
          generated_at: sample.data.generated_at,
          generator_version: sample.data.generator_version
        }
      }
    end)

    Anvil.add_samples(queue_id, anvil_samples)
  end
end
```

---

## 7. The Optimizer: Closing the Loop

### 7.1 Optimizer Module

```elixir
defmodule Anvil.Optimizer do
  @moduledoc """
  Closes the feedback loop: Anvil labels → DSPex optimization → Updated prompts.

  This is the key component that transforms manual review into system improvement.
  """

  use GenServer
  require Logger

  alias Anvil.Storage.Postgres, as: Storage

  @default_opts [
    min_examples: 20,           # Minimum examples before optimization
    optimization_interval: :timer.hours(24),
    metric_threshold: 0.8,      # Target acceptance rate
    dspex_optimizer: :mipro,
    dspex_max_iterations: 50
  ]

  # Client API

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Trigger optimization for a specific queue.
  """
  def optimize(queue_id, opts \\ []) do
    GenServer.call(__MODULE__, {:optimize, queue_id, opts}, :timer.minutes(10))
  end

  @doc """
  Schedule periodic optimization for a queue.
  """
  def schedule(queue_id, interval \\ @default_opts[:optimization_interval]) do
    GenServer.cast(__MODULE__, {:schedule, queue_id, interval})
  end

  @doc """
  Get optimization history and metrics.
  """
  def get_stats(queue_id) do
    GenServer.call(__MODULE__, {:stats, queue_id})
  end

  # Server Implementation

  @impl true
  def init(opts) do
    opts = Keyword.merge(@default_opts, opts)

    state = %{
      opts: opts,
      scheduled: %{},
      history: %{}
    }

    {:ok, state}
  end

  @impl true
  def handle_call({:optimize, queue_id, opts}, _from, state) do
    result = run_optimization(queue_id, Keyword.merge(state.opts, opts))

    state = update_history(state, queue_id, result)

    {:reply, result, state}
  end

  @impl true
  def handle_call({:stats, queue_id}, _from, state) do
    stats = Map.get(state.history, queue_id, [])
    {:reply, {:ok, stats}, state}
  end

  @impl true
  def handle_cast({:schedule, queue_id, interval}, state) do
    timer_ref = Process.send_after(self(), {:run_scheduled, queue_id}, interval)
    state = put_in(state, [:scheduled, queue_id], {timer_ref, interval})
    {:noreply, state}
  end

  @impl true
  def handle_info({:run_scheduled, queue_id}, state) do
    # Run optimization
    case run_optimization(queue_id, state.opts) do
      {:ok, _result} ->
        Logger.info("Scheduled optimization completed for queue #{queue_id}")
      {:error, reason} ->
        Logger.warning("Scheduled optimization failed for queue #{queue_id}: #{inspect(reason)}")
    end

    # Reschedule
    {_old_ref, interval} = state.scheduled[queue_id]
    timer_ref = Process.send_after(self(), {:run_scheduled, queue_id}, interval)
    state = put_in(state, [:scheduled, queue_id], {timer_ref, interval})

    {:noreply, state}
  end

  # Core Optimization Logic

  defp run_optimization(queue_id, opts) do
    with {:ok, queue} <- Storage.get_queue(queue_id),
         {:ok, trainset} <- build_trainset(queue_id, opts),
         :ok <- validate_trainset_size(trainset, opts[:min_examples]),
         {:ok, prompt_module} <- get_prompt_module(queue),
         {:ok, optimized} <- run_dspex(prompt_module, trainset, opts),
         :ok <- deploy_optimized(prompt_module, optimized) do

      emit_telemetry(:optimization_complete, %{
        queue_id: queue_id,
        trainset_size: length(trainset),
        improvement: optimized.improvement
      })

      {:ok, %{
        queue_id: queue_id,
        trainset_size: length(trainset),
        optimized_at: DateTime.utc_now(),
        metrics: optimized.metrics
      }}
    end
  end

  defp build_trainset(queue_id, _opts) do
    # Fetch all completed labels
    {:ok, labels} = Storage.get_labels(queue_id, status: :completed)

    # Separate by quality rating
    accepted = Enum.filter(labels, &(&1.data["quality"] == "accept"))
    rejected = Enum.filter(labels, &(&1.data["quality"] == "reject"))
    revised = Enum.filter(labels, &(&1.data["revised_svg"] != nil))

    # Build training examples
    trainset =
      build_accepted_examples(accepted) ++
      build_revision_examples(revised) ++
      build_negative_examples(rejected)

    {:ok, trainset}
  end

  defp build_accepted_examples(accepted) do
    Enum.map(accepted, fn label ->
      sample = fetch_sample_content(label.sample_id)

      %DSPex.Example{
        inputs: %{
          figure_spec: sample.spec,
          style_config: FigForge.Styles.get(sample.spec.style.journal)
        },
        outputs: %{
          svg_code: sample.svg
        },
        metadata: %{
          source: :accepted,
          style_score: label.data["style_score"],
          clarity_score: label.data["clarity_score"]
        }
      }
    end)
  end

  defp build_revision_examples(revised) do
    # Revisions are highest signal - user actively corrected the output
    # Weight these higher by including them multiple times
    Enum.flat_map(revised, fn label ->
      sample = fetch_sample_content(label.sample_id)

      example = %DSPex.Example{
        inputs: %{
          figure_spec: sample.spec,
          style_config: FigForge.Styles.get(sample.spec.style.journal)
        },
        outputs: %{
          svg_code: label.data["revised_svg"]  # User's corrected version
        },
        metadata: %{
          source: :revision,
          original_svg: sample.svg,
          revision_notes: label.data["revision_notes"]
        }
      }

      # Include revision examples twice for higher weight
      [example, example]
    end)
  end

  defp build_negative_examples(rejected) do
    # Rejected examples help DSPex understand what NOT to do
    Enum.map(rejected, fn label ->
      sample = fetch_sample_content(label.sample_id)

      %DSPex.Example{
        inputs: %{
          figure_spec: sample.spec,
          style_config: FigForge.Styles.get(sample.spec.style.journal)
        },
        outputs: %{
          svg_code: sample.svg
        },
        metadata: %{
          source: :rejected,
          is_negative: true,
          rejection_reason: label.data["revision_notes"]
        }
      }
    end)
  end

  defp validate_trainset_size(trainset, min) do
    if length(trainset) >= min do
      :ok
    else
      {:error, {:insufficient_examples, length(trainset), min}}
    end
  end

  defp get_prompt_module(queue) do
    case queue.metadata["component_module"] do
      nil -> {:error, :no_component_module}
      module_str -> {:ok, String.to_existing_atom("Elixir." <> module_str)}
    end
  end

  defp run_dspex(prompt_module, trainset, opts) do
    # Partition trainset
    {train, dev} = split_trainset(trainset, 0.8)

    # Filter out negative examples for training (keep for validation)
    train_positive = Enum.reject(train, & &1.metadata[:is_negative])

    DSPex.optimize(
      prompt_module,
      trainset: train_positive,
      devset: dev,
      metric: &acceptance_metric/2,
      optimizer: opts[:dspex_optimizer],
      max_iterations: opts[:dspex_max_iterations]
    )
  end

  defp acceptance_metric(predicted, example) do
    if example.metadata[:is_negative] do
      # For negative examples, lower similarity is better
      1.0 - svg_similarity(predicted.svg_code, example.outputs.svg_code)
    else
      # For positive examples, higher similarity is better
      svg_similarity(predicted.svg_code, example.outputs.svg_code)
    end
  end

  defp svg_similarity(svg1, svg2) do
    # Structural similarity based on element tree
    # Not pixel-perfect comparison
    tree1 = parse_svg_structure(svg1)
    tree2 = parse_svg_structure(svg2)

    structural_sim = tree_similarity(tree1, tree2)

    # Also compare key attributes (colors, positions)
    attr_sim = attribute_similarity(svg1, svg2)

    0.6 * structural_sim + 0.4 * attr_sim
  end

  defp deploy_optimized(prompt_module, optimized) do
    # Hot-swap the optimized prompt
    apply(prompt_module, :update, [optimized.params])

    Logger.info("Deployed optimized prompt for #{prompt_module}")
    :ok
  end

  defp emit_telemetry(event, metadata) do
    :telemetry.execute(
      [:anvil, :optimizer, event],
      %{timestamp: System.system_time()},
      metadata
    )
  end

  defp update_history(state, queue_id, result) do
    history = Map.get(state.history, queue_id, [])
    updated = [result | history] |> Enum.take(100)  # Keep last 100
    put_in(state, [:history, queue_id], updated)
  end
end
```

### 7.2 Telemetry Events

```elixir
defmodule Anvil.Optimizer.Telemetry do
  @moduledoc """
  Telemetry events for optimizer observability.
  """

  def events do
    [
      [:anvil, :optimizer, :optimization_started],
      [:anvil, :optimizer, :trainset_built],
      [:anvil, :optimizer, :dspex_iteration],
      [:anvil, :optimizer, :optimization_complete],
      [:anvil, :optimizer, :optimization_failed],
      [:anvil, :optimizer, :prompt_deployed]
    ]
  end

  def metrics do
    [
      summary("anvil.optimizer.trainset.size"),
      summary("anvil.optimizer.trainset.accepted_ratio"),
      summary("anvil.optimizer.trainset.revision_ratio"),
      summary("anvil.optimizer.duration.ms"),
      counter("anvil.optimizer.optimizations.total"),
      last_value("anvil.optimizer.metric.improvement")
    ]
  end
end
```

---

## 8. Ingot Integration: Review UI

### 8.1 LiveView Component for SVG Review

```elixir
defmodule IngotWeb.FigureReviewLive do
  @moduledoc """
  LiveView for reviewing generated figures.
  Supports accept/reject/revise workflow with keyboard shortcuts.
  """

  use IngotWeb, :live_view

  alias Anvil.Queue
  alias FigForge.ReviewQueue

  @impl true
  def mount(%{"queue_id" => queue_id}, session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Ingot.PubSub, "queue:#{queue_id}")
    end

    user_id = session["user_id"]

    socket =
      socket
      |> assign(:queue_id, queue_id)
      |> assign(:user_id, user_id)
      |> assign(:current_assignment, nil)
      |> assign(:editing_svg, false)
      |> assign(:form, to_form(%{}))
      |> fetch_next_assignment()

    {:ok, socket}
  end

  @impl true
  def handle_event("accept", _params, socket) do
    submit_label(socket, %{
      "quality" => "accept",
      "style_score" => socket.assigns.form.params["style_score"] || 5,
      "clarity_score" => socket.assigns.form.params["clarity_score"] || 5
    })
  end

  @impl true
  def handle_event("reject", _params, socket) do
    submit_label(socket, %{
      "quality" => "reject",
      "style_score" => socket.assigns.form.params["style_score"] || 1,
      "clarity_score" => socket.assigns.form.params["clarity_score"] || 1,
      "revision_notes" => socket.assigns.form.params["revision_notes"]
    })
  end

  @impl true
  def handle_event("submit_revision", %{"revised_svg" => svg} = params, socket) do
    submit_label(socket, %{
      "quality" => "needs_revision",
      "style_score" => params["style_score"],
      "clarity_score" => params["clarity_score"],
      "revision_notes" => params["revision_notes"],
      "revised_svg" => svg
    })
  end

  @impl true
  def handle_event("toggle_edit", _params, socket) do
    {:noreply, assign(socket, :editing_svg, !socket.assigns.editing_svg)}
  end

  @impl true
  def handle_event("keydown", %{"key" => "1"}, socket), do: handle_event("accept", %{}, socket)
  @impl true
  def handle_event("keydown", %{"key" => "2"}, socket), do: handle_event("reject", %{}, socket)
  @impl true
  def handle_event("keydown", %{"key" => "e"}, socket), do: handle_event("toggle_edit", %{}, socket)
  @impl true
  def handle_event("keydown", _params, socket), do: {:noreply, socket}

  defp submit_label(socket, label_data) do
    case Anvil.submit_label(
      socket.assigns.queue_id,
      socket.assigns.current_assignment.id,
      label_data
    ) do
      {:ok, _label} ->
        socket
        |> put_flash(:info, "Label submitted")
        |> fetch_next_assignment()
        |> then(&{:noreply, &1})

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed: #{inspect(reason)}")}
    end
  end

  defp fetch_next_assignment(socket) do
    case Anvil.get_next_assignment(socket.assigns.queue_id, socket.assigns.user_id) do
      {:ok, assignment} ->
        sample = Anvil.ForgeBridge.fetch_sample(assignment.sample_id)

        socket
        |> assign(:current_assignment, assignment)
        |> assign(:current_sample, sample)
        |> assign(:editing_svg, false)
        |> assign(:form, to_form(%{}))

      {:error, :no_samples_available} ->
        socket
        |> assign(:current_assignment, nil)
        |> assign(:current_sample, nil)
        |> put_flash(:info, "No more samples to review")
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="figure-review" phx-window-keydown="keydown">
      <%= if @current_sample do %>
        <div class="review-container">
          <!-- SVG Preview -->
          <div class="svg-preview">
            <%= if @editing_svg do %>
              <.svg_editor svg={@current_sample.content.svg} />
            <% else %>
              <div class="svg-render">
                <%= raw(@current_sample.content.svg) %>
              </div>
            <% end %>
          </div>

          <!-- Spec Summary -->
          <div class="spec-panel">
            <h3>Specification</h3>
            <.spec_summary spec={@current_sample.content.spec} />
          </div>

          <!-- Measurements -->
          <div class="measurements-panel">
            <h3>Automated Checks</h3>
            <.measurement_badges measurements={@current_sample.content.measurements} />
          </div>

          <!-- Rating Form -->
          <div class="rating-panel">
            <.form for={@form} phx-submit="submit_revision">
              <.rating_slider name="style_score" label="Style" />
              <.rating_slider name="clarity_score" label="Clarity" />
              <.textarea name="revision_notes" label="Notes (optional)" />

              <%= if @editing_svg do %>
                <.textarea name="revised_svg" label="Revised SVG" value={@current_sample.content.svg} />
              <% end %>
            </.form>
          </div>

          <!-- Action Buttons -->
          <div class="actions">
            <button phx-click="accept" class="btn-accept">
              Accept (1)
            </button>
            <button phx-click="toggle_edit" class="btn-edit">
              Edit (E)
            </button>
            <button phx-click="reject" class="btn-reject">
              Reject (2)
            </button>
          </div>

          <!-- Keyboard Shortcuts Help -->
          <div class="shortcuts-help">
            <kbd>1</kbd> Accept | <kbd>2</kbd> Reject | <kbd>E</kbd> Edit
          </div>
        </div>
      <% else %>
        <div class="empty-state">
          <p>No more figures to review.</p>
          <p>Check back later or adjust queue filters.</p>
        </div>
      <% end %>
    </div>
    """
  end
end
```

---

## 9. Metrics and Quality Gates

### 9.1 Acceptance Rate Tracking

```elixir
defmodule FigForge.Metrics do
  @moduledoc """
  Metrics for tracking flywheel health.
  """

  alias Anvil.Storage.Postgres, as: Storage

  def acceptance_rate(queue_id, opts \\ []) do
    since = Keyword.get(opts, :since, DateTime.add(DateTime.utc_now(), -7, :day))

    {:ok, labels} = Storage.get_labels(queue_id,
      status: :completed,
      since: since
    )

    total = length(labels)
    accepted = Enum.count(labels, &(&1.data["quality"] == "accept"))

    %{
      total: total,
      accepted: accepted,
      rate: if(total > 0, do: accepted / total, else: 0.0),
      period_start: since,
      period_end: DateTime.utc_now()
    }
  end

  def first_shot_rate(queue_id, opts \\ []) do
    # Samples accepted without revision
    since = Keyword.get(opts, :since, DateTime.add(DateTime.utc_now(), -7, :day))

    {:ok, labels} = Storage.get_labels(queue_id,
      status: :completed,
      since: since
    )

    total = length(labels)
    first_shot = Enum.count(labels, fn label ->
      label.data["quality"] == "accept" && label.data["revised_svg"] == nil
    end)

    %{
      total: total,
      first_shot_accepted: first_shot,
      rate: if(total > 0, do: first_shot / total, else: 0.0)
    }
  end

  def revision_patterns(queue_id, opts \\ []) do
    # Analyze what kinds of revisions are being made
    {:ok, labels} = Storage.get_labels(queue_id,
      status: :completed,
      has_revision: true
    )

    patterns = labels
    |> Enum.map(fn label ->
      original = fetch_original_svg(label.sample_id)
      revised = label.data["revised_svg"]

      analyze_diff(original, revised)
    end)
    |> aggregate_patterns()

    %{
      total_revisions: length(labels),
      common_issues: patterns
    }
  end

  defp analyze_diff(original, revised) do
    # Categorize the types of changes made
    # This helps identify systematic issues the generator has
    %{
      color_changes: detect_color_changes(original, revised),
      font_changes: detect_font_changes(original, revised),
      position_changes: detect_position_changes(original, revised),
      element_additions: detect_additions(original, revised),
      element_removals: detect_removals(original, revised)
    }
  end

  defp aggregate_patterns(diffs) do
    # Aggregate across all diffs to find common issues
    diffs
    |> Enum.reduce(%{}, fn diff, acc ->
      Enum.reduce(diff, acc, fn {category, changes}, inner_acc ->
        Map.update(inner_acc, category, changes, &(&1 ++ changes))
      end)
    end)
    |> Enum.map(fn {category, all_changes} ->
      {category, most_common(all_changes, 5)}
    end)
    |> Map.new()
  end
end
```

### 9.2 Quality Gates

```elixir
defmodule FigForge.QualityGate do
  @moduledoc """
  Quality gates that determine when system is production-ready.
  """

  @thresholds %{
    acceptance_rate: 0.80,        # 80% accepted without revision
    first_shot_rate: 0.60,        # 60% accepted on first try
    measurement_pass_rate: 0.95,  # 95% pass automated checks
    max_revision_time: 300        # 5 minutes average review time
  }

  def evaluate(queue_id) do
    metrics = %{
      acceptance: FigForge.Metrics.acceptance_rate(queue_id),
      first_shot: FigForge.Metrics.first_shot_rate(queue_id),
      measurement: measurement_pass_rate(queue_id),
      review_time: average_review_time(queue_id)
    }

    gates = %{
      acceptance_rate: metrics.acceptance.rate >= @thresholds.acceptance_rate,
      first_shot_rate: metrics.first_shot.rate >= @thresholds.first_shot_rate,
      measurement_pass: metrics.measurement >= @thresholds.measurement_pass_rate,
      review_time: metrics.review_time <= @thresholds.max_revision_time
    }

    %{
      passed: Enum.all?(gates, fn {_, v} -> v end),
      gates: gates,
      metrics: metrics,
      thresholds: @thresholds
    }
  end

  def ready_for_autonomous?(queue_id) do
    # Is the system good enough to generate without review?
    eval = evaluate(queue_id)

    # Need very high first-shot rate for autonomous mode
    eval.passed && eval.metrics.first_shot.rate >= 0.90
  end
end
```

---

## 10. Operational Considerations

### 10.1 Supervision Tree

```elixir
defmodule FigForge.Application do
  use Application

  def start(_type, _args) do
    children = [
      # Forge pipeline
      {Forge.Pipeline.Supervisor, pipelines: [FigForge.Pipeline]},

      # Anvil components
      {Anvil.Repo, []},
      {Anvil.Queue.Supervisor, []},

      # Optimizer (periodic optimization)
      {Anvil.Optimizer, [
        min_examples: 20,
        optimization_interval: :timer.hours(24)
      ]},

      # Snakepit for DSPex Python interop (if using matplotlib backend)
      {Snakepit.Supervisor, pools: [
        %{name: :dspex_pool, pool_size: 4, affinity: :strict_queue}
      ]},

      # Phoenix endpoint for Ingot
      IngotWeb.Endpoint
    ]

    opts = [strategy: :one_for_one, name: FigForge.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
```

### 10.2 Configuration

```elixir
# config/config.exs

config :fig_forge,
  forge_pipeline: :figure_generation,
  default_style: :nature,
  llm_provider: :anthropic,
  llm_model: "claude-sonnet-4-20250514"

config :anvil,
  repo: Anvil.Repo,
  forge_bridge_backend: Anvil.ForgeBridge.Direct,
  start_oban: true

config :anvil, Anvil.Optimizer,
  enabled: true,
  min_examples: 20,
  optimization_interval: :timer.hours(24),
  dspex_optimizer: :mipro,
  dspex_max_iterations: 50

config :ingot, IngotWeb.Endpoint,
  url: [host: "localhost"],
  secret_key_base: "...",
  live_view: [signing_salt: "..."]
```

### 10.3 Database Migrations

```elixir
defmodule Anvil.Repo.Migrations.AddFigureReviewTables do
  use Ecto.Migration

  def change do
    # Existing Anvil tables handle most of this
    # Just need to add indexes for common queries

    create index(:labels, [:queue_id, :inserted_at])
    create index(:labels, [:queue_id, "(data->>'quality')"])
    create index(:labels, [:queue_id, "(data->>'revised_svg' IS NOT NULL)"])

    # Optimization history
    create table(:optimization_runs) do
      add :queue_id, :string, null: false
      add :trainset_size, :integer, null: false
      add :accepted_count, :integer
      add :revision_count, :integer
      add :rejected_count, :integer
      add :dspex_iterations, :integer
      add :metric_before, :float
      add :metric_after, :float
      add :prompt_version, :string
      add :metadata, :map, default: %{}

      timestamps()
    end

    create index(:optimization_runs, [:queue_id, :inserted_at])
  end
end
```

---

## 11. Incremental Build Plan

### Phase 1: Manual Baseline (Week 1)

1. Create 30 reference SVGs manually with Claude
2. Define figure specification schema
3. Write the best single prompt for spec → SVG
4. Measure: what percentage work first try?

### Phase 2: Automated Validation (Week 2)

1. Implement Forge measurements (SVGValidity, StyleCompliance, DataIntegrity)
2. Run generation through Forge pipeline
3. Automatic rejection of syntactically invalid outputs
4. Measure: pre-filter rejection rate

### Phase 3: Review Queue (Week 3)

1. Configure Anvil queue with FigForge.ReviewSchema
2. Build Ingot LiveView for review
3. Start collecting accept/reject/revision data
4. Measure: acceptance rate, revision patterns

### Phase 4: Close the Loop (Week 4)

1. Implement Anvil.Optimizer
2. Run first DSPex optimization with collected data
3. Deploy optimized prompt
4. Measure: acceptance rate improvement

### Phase 5: Iteration (Ongoing)

1. Continue review → optimize cycle
2. Track metrics over time
3. Add new figure types as needed
4. Monitor for regression

---

## 12. Success Criteria

| Metric | Initial | Target | Autonomous |
|--------|---------|--------|------------|
| First-shot acceptance | ~30% | 60% | 90% |
| Overall acceptance | ~50% | 80% | 95% |
| Measurement pass rate | 70% | 95% | 99% |
| Average review time | 5 min | 2 min | 0 (no review) |
| Revision rate | 30% | 15% | 5% |

When the system consistently achieves "Autonomous" metrics, it can be trusted to generate figures without human review for routine cases, with spot-checking for quality assurance.

---

## 13. Open Questions

1. **DSPex integration depth**: How tightly should the optimizer integrate with DSPex? Direct API or through Snakepit?

2. **Revision capture UX**: What's the best way to capture SVG edits in Ingot? Inline editor vs. copy-paste?

3. **Multi-style optimization**: Should there be separate optimized prompts per journal style, or one prompt that handles all styles?

4. **Negative example handling**: How much weight should rejected examples get in training? Too much may cause overcorrection.

5. **Versioning strategy**: How to handle prompt version rollback if optimization regresses?

---

## 14. References

- ADR-001: Postgres Storage Layer
- ADR-002: Queue Assignment Policies
- ADR-003: Label Schema Versioning
- ADR-005: Deterministic Export
- ADR-010: ForgeBridge Integration
- DSPex Documentation
- Nature Submission Guidelines: https://www.nature.com/nature/for-authors/formatting-guide
- Science Figure Guidelines: https://www.science.org/content/page/instructions-preparing-initial-manuscript
