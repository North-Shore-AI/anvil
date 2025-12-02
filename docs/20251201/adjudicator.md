# Anvil.Adjudication: Dispute Resolution Layer

## Resolving Disagreement in Human Labeling Workflows

**Priority**: P2 - Medium (after Anvil core is stable)
**Status**: Design Specification
**Dependencies**: Anvil (core labeling), NSAI.Work (optional job integration)

---

## 1. The Problem

Anvil handles the "happy path" of labeling:
- Samples enter queues
- Labelers receive assignments
- Labels are submitted and validated
- Agreement metrics are computed

But what happens when labelers disagree?

| Scenario | Current Anvil Behavior | What's Needed |
|----------|----------------------|---------------|
| Two labelers give different labels | Recorded, agreement computed | Someone decides which is correct |
| Agreement below threshold | Metric flagged | Systematic resolution workflow |
| Ambiguous sample | Labelers struggle | Expert review, possible sample rejection |
| Labeler error suspected | No detection | Quality review, possible retraining |

**The gap**: Anvil tracks disagreement but doesn't resolve it. Adjudication is a different workflow—you're not labeling a sample, you're arbitrating between existing labels.

---

## 2. The Solution: Anvil.Adjudication

A thin layer on top of Anvil that handles dispute detection, queuing, and resolution:

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                              Anvil Core                                      │
│  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐        │
│  │   Queue     │  │ Assignment  │  │    Label    │  │  Agreement  │        │
│  └──────┬──────┘  └──────┬──────┘  └──────┬──────┘  └──────┬──────┘        │
│         │                │                │                │               │
└─────────┼────────────────┼────────────────┼────────────────┼───────────────┘
          │                │                │                │
          │                │                │                ▼
          │                │                │    ┌───────────────────────┐
          │                │                │    │   Dispute Detector    │
          │                │                │    │  (Agreement < θ)      │
          │                │                │    └───────────┬───────────┘
          │                │                │                │
          │                │                ▼                ▼
          │                │    ┌─────────────────────────────────────────┐
          │                │    │           Anvil.Adjudication            │
          │                │    │  ┌─────────────┐  ┌─────────────┐       │
          │                │    │  │   Dispute   │  │ Resolution  │       │
          │                │    │  │    Queue    │  │   Policy    │       │
          │                │    │  └─────────────┘  └─────────────┘       │
          │                │    │  ┌─────────────┐  ┌─────────────┐       │
          │                │    │  │ Adjudicator │  │   Verdict   │       │
          │                │    │  │ Assignment  │  │   Record    │       │
          │                │    │  └─────────────┘  └─────────────┘       │
          │                │    └──────────────────────┬──────────────────┘
          │                │                           │
          │                │                           ▼
          │                │              ┌─────────────────────────┐
          │                └──────────────│   Resolved Label        │
          │                               │   (back to Anvil)       │
          └───────────────────────────────└─────────────────────────┘
```

---

## 3. Core Concepts

### 3.1 Dispute

A dispute arises when labels for the same sample cannot be automatically reconciled:

```elixir
defmodule Anvil.Adjudication.Dispute do
  @moduledoc """
  A dispute represents a sample where labelers disagreed
  beyond acceptable thresholds.
  """

  @type trigger :: 
    :agreement_below_threshold   # Computed agreement too low
    | :explicit_disagreement     # Labels are mutually exclusive
    | :labeler_flag              # Labeler marked as ambiguous
    | :quality_flag              # QA process flagged for review
    | :escalation                # Lower-tier adjudicator escalated

  @type status :: 
    :pending      # Awaiting adjudication
    | :assigned   # Adjudicator working on it
    | :resolved   # Verdict rendered
    | :escalated  # Sent to higher authority
    | :rejected   # Sample deemed unlabelable

  @type t :: %__MODULE__{
    id: String.t(),
    sample_id: String.t(),
    queue_id: String.t(),
    
    # The conflicting labels
    labels: [Anvil.Label.t()],
    
    # Why this became a dispute
    trigger: trigger(),
    trigger_metadata: map(),  # e.g., %{agreement_score: 0.34, threshold: 0.7}
    
    # Agreement analysis
    agreement_scores: %{
      metric: atom(),       # :cohens_kappa, :fleiss_kappa, etc.
      score: float(),
      by_field: %{String.t() => float()}  # Per-field agreement if applicable
    },
    
    # Status
    status: status(),
    priority: :low | :normal | :high | :urgent,
    
    # Assignment
    adjudicator_id: String.t() | nil,
    assigned_at: DateTime.t() | nil,
    
    # Resolution
    verdict: Verdict.t() | nil,
    resolved_at: DateTime.t() | nil,
    
    # Audit
    created_at: DateTime.t(),
    escalation_history: [Escalation.t()],
    
    metadata: map()
  }

  defstruct [
    :id, :sample_id, :queue_id, :labels, :trigger, 
    trigger_metadata: %{}, agreement_scores: %{},
    status: :pending, priority: :normal,
    :adjudicator_id, :assigned_at, :verdict, :resolved_at,
    :created_at, escalation_history: [], metadata: %{}
  ]
end
```

### 3.2 Verdict

The adjudicator's decision:

```elixir
defmodule Anvil.Adjudication.Verdict do
  @moduledoc """
  The resolution of a dispute.
  """

  @type resolution_type ::
    :select_existing    # Pick one of the existing labels
    | :create_new       # Adjudicator provides correct label
    | :merge            # Combine aspects of multiple labels
    | :reject_sample    # Sample is unlabelable/ambiguous
    | :escalate         # Send to higher authority
    | :split            # Sample needs decomposition (rare)

  @type t :: %__MODULE__{
    id: String.t(),
    dispute_id: String.t(),
    adjudicator_id: String.t(),
    
    # What was decided
    resolution_type: resolution_type(),
    
    # The resulting label (for :select_existing, :create_new, :merge)
    resolved_label: Anvil.Label.t() | nil,
    
    # Which existing label was selected (for :select_existing)
    selected_label_id: String.t() | nil,
    
    # Reasoning
    rationale: String.t(),
    confidence: :low | :medium | :high,
    
    # For :escalate
    escalation_reason: String.t() | nil,
    escalation_tier: integer() | nil,
    
    # For :reject_sample
    rejection_reason: String.t() | nil,
    rejection_category: atom() | nil,  # :ambiguous, :malformed, :out_of_scope, etc.
    
    # Timing
    deliberation_time_ms: non_neg_integer(),
    created_at: DateTime.t(),
    
    metadata: map()
  }

  defstruct [
    :id, :dispute_id, :adjudicator_id, :resolution_type,
    :resolved_label, :selected_label_id, :rationale, 
    confidence: :medium, :escalation_reason, :escalation_tier,
    :rejection_reason, :rejection_category, :deliberation_time_ms,
    :created_at, metadata: %{}
  ]
end
```

### 3.3 Adjudicator

Who can resolve disputes (different from regular labelers):

```elixir
defmodule Anvil.Adjudication.Adjudicator do
  @moduledoc """
  An adjudicator is authorized to resolve disputes.
  May be a senior labeler, domain expert, or automated system.
  """

  @type adjudicator_type :: :human | :model | :rule_based | :consensus

  @type t :: %__MODULE__{
    id: String.t(),
    type: adjudicator_type(),
    
    # Human adjudicators
    user_id: String.t() | nil,
    
    # Model adjudicators (LLM-as-judge)
    model_config: map() | nil,
    
    # Qualifications
    tier: integer(),  # 1 = junior, 2 = senior, 3 = expert, etc.
    domains: [atom()],  # What areas they can adjudicate
    
    # Performance tracking
    verdicts_rendered: non_neg_integer(),
    verdicts_appealed: non_neg_integer(),
    average_deliberation_ms: float(),
    
    # Availability
    active: boolean(),
    max_concurrent_disputes: non_neg_integer(),
    current_assignments: non_neg_integer(),
    
    metadata: map()
  }

  defstruct [
    :id, type: :human, :user_id, :model_config,
    tier: 1, domains: [], verdicts_rendered: 0, verdicts_appealed: 0,
    average_deliberation_ms: 0.0, active: true, max_concurrent_disputes: 10,
    current_assignments: 0, metadata: %{}
  ]
end
```

---

## 4. Dispute Detection

### 4.1 Detection Policies

```elixir
defmodule Anvil.Adjudication.DetectionPolicy do
  @moduledoc """
  Configures when labels become disputes.
  """

  @type t :: %__MODULE__{
    # Minimum labels before checking agreement
    min_labels_required: non_neg_integer(),
    
    # Agreement thresholds (dispute if below)
    agreement_threshold: float(),  # Overall
    field_thresholds: %{String.t() => float()},  # Per-field overrides
    
    # Agreement metric to use
    metric: :cohens_kappa | :fleiss_kappa | :krippendorff_alpha | :percent_agreement,
    
    # Additional triggers
    detect_on_labeler_flag: boolean(),
    detect_on_time_variance: boolean(),  # If one label took 10x longer
    time_variance_threshold: float(),
    
    # Automatic resolution (skip adjudication)
    auto_resolve_if_supermajority: boolean(),
    supermajority_threshold: float(),  # e.g., 0.8 = 80% agree
    
    metadata: map()
  }

  defstruct [
    min_labels_required: 2,
    agreement_threshold: 0.7,
    field_thresholds: %{},
    metric: :cohens_kappa,
    detect_on_labeler_flag: true,
    detect_on_time_variance: false,
    time_variance_threshold: 5.0,
    auto_resolve_if_supermajority: true,
    supermajority_threshold: 0.8,
    metadata: %{}
  ]
end
```

### 4.2 Detector Behaviour

```elixir
defmodule Anvil.Adjudication.Detector do
  @moduledoc """
  Behaviour for dispute detection strategies.
  """

  alias Anvil.{Label, Sample}
  alias Anvil.Adjudication.{Dispute, DetectionPolicy}

  @doc "Check if labels for a sample constitute a dispute."
  @callback detect(
    sample :: Sample.t(),
    labels :: [Label.t()],
    policy :: DetectionPolicy.t()
  ) :: {:ok, :no_dispute} | {:dispute, Dispute.trigger(), map()}

  @doc "Batch detection across many samples."
  @callback detect_batch(
    samples_with_labels :: [{Sample.t(), [Label.t()]}],
    policy :: DetectionPolicy.t()
  ) :: [Dispute.t()]
end

defmodule Anvil.Adjudication.Detector.Default do
  @behaviour Anvil.Adjudication.Detector

  @impl true
  def detect(sample, labels, policy) when length(labels) < policy.min_labels_required do
    {:ok, :no_dispute}
  end

  def detect(sample, labels, policy) do
    agreement = compute_agreement(labels, policy.metric)
    
    cond do
      # Check for supermajority auto-resolve
      policy.auto_resolve_if_supermajority and supermajority?(labels, policy) ->
        {:ok, :no_dispute}
      
      # Check overall agreement
      agreement < policy.agreement_threshold ->
        {:dispute, :agreement_below_threshold, %{
          agreement_score: agreement,
          threshold: policy.agreement_threshold,
          metric: policy.metric
        }}
      
      # Check per-field thresholds
      field_dispute = check_field_thresholds(labels, policy) ->
        {:dispute, :agreement_below_threshold, field_dispute}
      
      # Check labeler flags
      policy.detect_on_labeler_flag and any_flagged?(labels) ->
        {:dispute, :labeler_flag, %{flagged_by: flagged_labelers(labels)}}
      
      true ->
        {:ok, :no_dispute}
    end
  end

  defp compute_agreement(labels, :cohens_kappa) when length(labels) == 2 do
    Anvil.Agreement.cohens_kappa(labels)
  end

  defp compute_agreement(labels, :fleiss_kappa) do
    Anvil.Agreement.fleiss_kappa(labels)
  end

  defp compute_agreement(labels, :percent_agreement) do
    Anvil.Agreement.percent_agreement(labels)
  end
end
```

---

## 5. Dispute Queue

### 5.1 Queue Configuration

```elixir
defmodule Anvil.Adjudication.DisputeQueue do
  @moduledoc """
  A queue of disputes awaiting adjudication.
  Separate from labeling queues—different workflow, different UI.
  """

  @type assignment_strategy ::
    :round_robin           # Rotate among available adjudicators
    | :expertise_match     # Match dispute domain to adjudicator domains
    | :load_balanced       # Assign to least-busy adjudicator
    | :tiered              # Route by dispute complexity to appropriate tier

  @type t :: %__MODULE__{
    id: String.t(),
    name: String.t(),
    
    # Which labeling queue(s) this handles disputes for
    source_queue_ids: [String.t()],
    
    # Detection policy
    detection_policy: DetectionPolicy.t(),
    
    # Assignment
    assignment_strategy: assignment_strategy(),
    eligible_adjudicators: [String.t()] | :all,
    min_adjudicator_tier: integer(),
    
    # Escalation
    escalation_queue_id: String.t() | nil,  # Where escalations go
    auto_escalate_after_ms: non_neg_integer() | nil,  # Timeout
    
    # Stats
    pending_count: non_neg_integer(),
    assigned_count: non_neg_integer(),
    resolved_today: non_neg_integer(),
    average_resolution_time_ms: float(),
    
    metadata: map()
  }

  defstruct [
    :id, :name, source_queue_ids: [], 
    detection_policy: %DetectionPolicy{},
    assignment_strategy: :load_balanced,
    eligible_adjudicators: :all, min_adjudicator_tier: 1,
    :escalation_queue_id, :auto_escalate_after_ms,
    pending_count: 0, assigned_count: 0, resolved_today: 0,
    average_resolution_time_ms: 0.0, metadata: %{}
  ]
end
```

### 5.2 Assignment Logic

```elixir
defmodule Anvil.Adjudication.Assigner do
  @moduledoc """
  Assigns disputes to adjudicators.
  """

  alias Anvil.Adjudication.{Dispute, DisputeQueue, Adjudicator}

  @doc "Get next dispute for an adjudicator."
  @spec fetch_next(Adjudicator.t(), DisputeQueue.t()) :: 
    {:ok, Dispute.t()} | {:error, :none_available}
  def fetch_next(adjudicator, queue) do
    with :ok <- check_eligibility(adjudicator, queue),
         :ok <- check_capacity(adjudicator),
         {:ok, dispute} <- find_matching_dispute(adjudicator, queue) do
      assign_dispute(dispute, adjudicator)
    end
  end

  defp find_matching_dispute(adjudicator, queue) do
    # Prioritize by:
    # 1. Priority (urgent > high > normal > low)
    # 2. Age (older disputes first)
    # 3. Domain match (if adjudicator has domains)
    
    Dispute
    |> where([d], d.queue_id == ^queue.id)
    |> where([d], d.status == :pending)
    |> where([d], is_nil(d.adjudicator_id))
    |> maybe_filter_by_domain(adjudicator.domains)
    |> order_by([d], [desc: d.priority, asc: d.created_at])
    |> limit(1)
    |> Repo.one()
    |> case do
      nil -> {:error, :none_available}
      dispute -> {:ok, dispute}
    end
  end

  defp assign_dispute(dispute, adjudicator) do
    dispute
    |> Dispute.changeset(%{
      adjudicator_id: adjudicator.id,
      assigned_at: DateTime.utc_now(),
      status: :assigned
    })
    |> Repo.update()
  end
end
```

---

## 6. Resolution Policies

### 6.1 What Adjudicators See

```elixir
defmodule Anvil.Adjudication.DisputeView do
  @moduledoc """
  What gets presented to an adjudicator.
  Different from labeling view—shows the conflict, not just the sample.
  """

  @type t :: %__MODULE__{
    dispute: Dispute.t(),
    sample: Anvil.Sample.t(),
    
    # The conflicting labels (anonymized or not, configurable)
    labels: [LabelView.t()],
    
    # Agreement analysis
    agreement_breakdown: %{
      overall: float(),
      by_field: %{String.t() => %{score: float(), values: [term()]}}
    },
    
    # Context
    schema: Anvil.LabelSchema.t(),
    guidelines: String.t() | nil,
    similar_resolved_disputes: [ResolvedExample.t()],
    
    # What actions are available
    available_actions: [:select_existing, :create_new, :reject_sample, :escalate]
  }

  defstruct [
    :dispute, :sample, :labels, :agreement_breakdown,
    :schema, :guidelines, similar_resolved_disputes: [],
    available_actions: [:select_existing, :create_new, :reject_sample, :escalate]
  ]
end

defmodule Anvil.Adjudication.LabelView do
  @moduledoc "Anonymized or attributed view of a label in dispute."

  @type t :: %__MODULE__{
    label_id: String.t(),
    values: map(),
    
    # May be anonymized
    labeler_id: String.t() | :anonymous,
    labeler_tier: integer() | nil,
    
    # Timing (relevant for adjudication)
    time_spent_ms: non_neg_integer(),
    
    # Any notes the labeler left
    notes: String.t() | nil
  }

  defstruct [:label_id, :values, :labeler_id, :labeler_tier, :time_spent_ms, :notes]
end
```

### 6.2 Resolution Behaviour

```elixir
defmodule Anvil.Adjudication.Resolver do
  @moduledoc """
  Behaviour for resolution strategies.
  
  Allows pluggable resolution: human, LLM-as-judge, rule-based, etc.
  """

  alias Anvil.Adjudication.{Dispute, Verdict, DisputeView}

  @doc "Resolve a dispute, producing a verdict."
  @callback resolve(view :: DisputeView.t(), opts :: keyword()) ::
    {:ok, Verdict.t()} | {:error, term()}

  @doc "Validate a verdict before committing."
  @callback validate_verdict(verdict :: Verdict.t(), dispute :: Dispute.t()) ::
    :ok | {:error, term()}
end

defmodule Anvil.Adjudication.Resolver.Human do
  @moduledoc "Human adjudicator resolution (UI-driven)."
  @behaviour Anvil.Adjudication.Resolver

  @impl true
  def resolve(_view, _opts) do
    # This is driven by UI—the human submits a verdict form
    {:error, :ui_driven}
  end

  @impl true
  def validate_verdict(verdict, dispute) do
    with :ok <- validate_resolution_type(verdict, dispute),
         :ok <- validate_rationale(verdict),
         :ok <- validate_label_if_needed(verdict, dispute) do
      :ok
    end
  end

  defp validate_rationale(%{rationale: r}) when byte_size(r) < 10 do
    {:error, :rationale_too_short}
  end
  defp validate_rationale(_), do: :ok
end

defmodule Anvil.Adjudication.Resolver.LLMJudge do
  @moduledoc """
  LLM-as-judge for automated adjudication.
  
  Use with caution—best for clear-cut disputes or as tiebreaker.
  """
  @behaviour Anvil.Adjudication.Resolver

  @impl true
  def resolve(view, opts) do
    prompt = build_adjudication_prompt(view)
    
    model = opts[:model] || "gpt-4o"
    
    case call_llm(model, prompt) do
      {:ok, response} -> parse_verdict(response, view.dispute)
      error -> error
    end
  end

  defp build_adjudication_prompt(view) do
    """
    You are an expert adjudicator resolving a labeling disagreement.

    ## Sample
    #{inspect(view.sample.data)}

    ## Labeling Schema
    #{inspect(view.schema)}

    ## Conflicting Labels
    #{format_labels(view.labels)}

    ## Agreement Analysis
    #{format_agreement(view.agreement_breakdown)}

    ## Task
    Determine the correct label. You must:
    1. Select one of the existing labels, OR create the correct label
    2. Provide a rationale (2-3 sentences)
    3. Rate your confidence (low/medium/high)

    Respond in JSON format:
    {
      "resolution": "select_existing" | "create_new" | "reject_sample",
      "selected_label_id": "..." (if select_existing),
      "correct_values": {...} (if create_new),
      "rationale": "...",
      "confidence": "low" | "medium" | "high"
    }
    """
  end
end

defmodule Anvil.Adjudication.Resolver.MajorityRule do
  @moduledoc """
  Simple majority rule for unambiguous cases.
  
  If 3+ labelers and >66% agree, auto-resolve.
  """
  @behaviour Anvil.Adjudication.Resolver

  @impl true
  def resolve(view, opts) do
    threshold = opts[:threshold] || 0.66
    labels = view.labels
    
    case find_majority(labels, threshold) do
      {:ok, majority_label} ->
        {:ok, %Verdict{
          dispute_id: view.dispute.id,
          adjudicator_id: "system:majority_rule",
          resolution_type: :select_existing,
          selected_label_id: majority_label.label_id,
          rationale: "Automatic resolution: #{majority_percent(labels, majority_label)}% agreement",
          confidence: :high,
          deliberation_time_ms: 0,
          created_at: DateTime.utc_now()
        }}
      
      :no_majority ->
        {:error, :no_clear_majority}
    end
  end
end
```

---

## 7. Escalation

### 7.1 Escalation Structure

```elixir
defmodule Anvil.Adjudication.Escalation do
  @moduledoc """
  When an adjudicator can't or won't resolve, it escalates.
  """

  @type t :: %__MODULE__{
    id: String.t(),
    dispute_id: String.t(),
    
    # Who escalated
    from_adjudicator_id: String.t(),
    from_tier: integer(),
    
    # Where it went
    to_queue_id: String.t(),
    to_tier: integer(),
    
    # Why
    reason: String.t(),
    category: :too_complex | :domain_mismatch | :conflict_of_interest | :timeout | :other,
    
    created_at: DateTime.t()
  }

  defstruct [
    :id, :dispute_id, :from_adjudicator_id, :from_tier,
    :to_queue_id, :to_tier, :reason, :category, :created_at
  ]
end
```

### 7.2 Tiered Escalation

```elixir
defmodule Anvil.Adjudication.EscalationPolicy do
  @moduledoc """
  Configures escalation paths.
  """

  @type t :: %__MODULE__{
    # Tier definitions
    tiers: [TierConfig.t()],
    
    # Escalation rules
    max_escalations: non_neg_integer(),  # Before marking as unresolvable
    escalation_timeout_ms: non_neg_integer(),  # Auto-escalate if not resolved
    
    # Final tier handling
    final_tier_action: :require_resolution | :mark_ambiguous | :committee_vote
  }

  defstruct [
    tiers: [],
    max_escalations: 3,
    escalation_timeout_ms: :timer.hours(24),
    final_tier_action: :mark_ambiguous
  ]
end

defmodule Anvil.Adjudication.TierConfig do
  @type t :: %__MODULE__{
    tier: integer(),
    name: String.t(),
    queue_id: String.t(),
    min_adjudicator_tier: integer(),
    sla_ms: non_neg_integer()  # Expected resolution time
  }

  defstruct [:tier, :name, :queue_id, :min_adjudicator_tier, :sla_ms]
end
```

---

## 8. Service API

```elixir
defmodule Anvil.Adjudication do
  @moduledoc """
  Public API for the adjudication layer.
  """

  alias Anvil.Adjudication.{
    Dispute, Verdict, DisputeQueue, Adjudicator,
    Detector, Assigner, DisputeView
  }

  # ─── Dispute Detection ───

  @doc "Detect disputes for a queue (typically called after labeling completes)."
  @spec detect_disputes(queue_id :: String.t()) :: {:ok, [Dispute.t()]}
  def detect_disputes(queue_id) do
    queue = get_queue!(queue_id)
    samples_with_labels = fetch_samples_needing_review(queue)
    
    disputes = Detector.Default.detect_batch(samples_with_labels, queue.detection_policy)
    
    {:ok, Enum.map(disputes, &create_dispute!/1)}
  end

  @doc "Manually flag a sample for adjudication."
  @spec flag_for_review(sample_id :: String.t(), reason :: String.t()) :: 
    {:ok, Dispute.t()}
  def flag_for_review(sample_id, reason) do
    # Create dispute with :quality_flag trigger
  end

  # ─── Adjudicator Assignment ───

  @doc "Get next dispute for an adjudicator to resolve."
  @spec fetch_dispute(adjudicator_id :: String.t()) :: 
    {:ok, DisputeView.t()} | {:error, :none_available}
  def fetch_dispute(adjudicator_id) do
    adjudicator = get_adjudicator!(adjudicator_id)
    queues = get_queues_for_adjudicator(adjudicator)
    
    Enum.find_value(queues, {:error, :none_available}, fn queue ->
      case Assigner.fetch_next(adjudicator, queue) do
        {:ok, dispute} -> {:ok, build_dispute_view(dispute)}
        _ -> nil
      end
    end)
  end

  # ─── Resolution ───

  @doc "Submit a verdict for a dispute."
  @spec submit_verdict(verdict :: Verdict.t()) :: 
    {:ok, Verdict.t()} | {:error, term()}
  def submit_verdict(%Verdict{} = verdict) do
    dispute = get_dispute!(verdict.dispute_id)
    
    with :ok <- validate_can_resolve(verdict.adjudicator_id, dispute),
         :ok <- Resolver.Human.validate_verdict(verdict, dispute),
         {:ok, verdict} <- save_verdict(verdict),
         {:ok, _} <- apply_resolution(verdict, dispute) do
      {:ok, verdict}
    end
  end

  @doc "Escalate a dispute."
  @spec escalate(dispute_id :: String.t(), reason :: String.t()) ::
    {:ok, Escalation.t()} | {:error, term()}
  def escalate(dispute_id, reason) do
    # Move to escalation queue
  end

  # ─── Queries ───

  @doc "Get disputes for a queue."
  @spec list_disputes(queue_id :: String.t(), opts :: keyword()) :: [Dispute.t()]
  def list_disputes(queue_id, opts \\ []) do
    # Filter by status, priority, age, etc.
  end

  @doc "Get adjudication statistics."
  @spec stats(queue_id :: String.t()) :: map()
  def stats(queue_id) do
    %{
      pending: count_pending(queue_id),
      assigned: count_assigned(queue_id),
      resolved_today: count_resolved_today(queue_id),
      average_resolution_time_ms: avg_resolution_time(queue_id),
      escalation_rate: escalation_rate(queue_id),
      resolution_breakdown: resolution_type_counts(queue_id)
    }
  end
end
```

---

## 9. Integration with Anvil Core

### 9.1 Hooks into Labeling Flow

```elixir
defmodule Anvil.Hooks do
  @moduledoc "Extension points for adjudication integration."

  @doc "Called when a label is submitted. May trigger dispute detection."
  def on_label_submitted(label, sample, queue) do
    all_labels = Anvil.get_labels_for_sample(sample.id)
    
    if length(all_labels) >= queue.redundancy_level do
      # Check for disputes
      case Anvil.Adjudication.Detector.Default.detect(sample, all_labels, queue.detection_policy) do
        {:dispute, trigger, metadata} ->
          Anvil.Adjudication.create_dispute!(sample, all_labels, trigger, metadata)
        {:ok, :no_dispute} ->
          # Proceed with normal flow
          :ok
      end
    end
  end

  @doc "Called when a verdict is applied. Updates the sample's final label."
  def on_verdict_applied(verdict, dispute) do
    case verdict.resolution_type do
      :select_existing ->
        Anvil.set_final_label(dispute.sample_id, verdict.selected_label_id)
      
      :create_new ->
        {:ok, label} = Anvil.create_label(dispute.sample_id, verdict.resolved_label)
        Anvil.set_final_label(dispute.sample_id, label.id)
      
      :reject_sample ->
        Anvil.mark_sample_rejected(dispute.sample_id, verdict.rejection_reason)
      
      :merge ->
        # Complex merge logic
        :ok
    end
  end
end
```

### 9.2 Agreement Metrics Connection

```elixir
defmodule Anvil.Agreement do
  # Existing agreement computation...

  @doc "Get agreement metrics with dispute context."
  def analyze_with_disputes(labels) do
    base_metrics = compute_all_metrics(labels)
    
    %{
      metrics: base_metrics,
      would_trigger_dispute: below_threshold?(base_metrics),
      disagreement_analysis: %{
        most_contested_fields: find_contested_fields(labels),
        labeler_clusters: cluster_by_agreement(labels),
        outlier_labels: find_outliers(labels)
      }
    }
  end
end
```

---

## 10. Ingot UI Integration

The adjudication UI is distinct from the labeling UI:

```elixir
defmodule IngotWeb.AdjudicationLive do
  use IngotWeb, :live_view

  @impl true
  def mount(_params, session, socket) do
    adjudicator = get_adjudicator(session)
    
    socket = socket
    |> assign(:adjudicator, adjudicator)
    |> assign(:current_dispute, nil)
    |> assign(:stats, Anvil.Adjudication.stats_for_adjudicator(adjudicator.id))
    
    {:ok, socket}
  end

  @impl true
  def handle_event("fetch_next", _, socket) do
    case Anvil.Adjudication.fetch_dispute(socket.assigns.adjudicator.id) do
      {:ok, view} ->
        {:noreply, assign(socket, :current_dispute, view)}
      {:error, :none_available} ->
        {:noreply, put_flash(socket, :info, "No disputes awaiting adjudication")}
    end
  end

  @impl true
  def handle_event("submit_verdict", params, socket) do
    verdict = build_verdict(params, socket.assigns)
    
    case Anvil.Adjudication.submit_verdict(verdict) do
      {:ok, _verdict} ->
        socket = socket
        |> put_flash(:info, "Verdict submitted")
        |> assign(:current_dispute, nil)
        |> assign(:stats, Anvil.Adjudication.stats_for_adjudicator(socket.assigns.adjudicator.id))
        
        {:noreply, socket}
      
      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Error: #{inspect(reason)}")}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="adjudication-workspace">
      <.stats_panel stats={@stats} />
      
      <%= if @current_dispute do %>
        <.dispute_panel dispute={@current_dispute}>
          <:sample>
            <.sample_display sample={@current_dispute.sample} />
          </:sample>
          
          <:labels>
            <.conflicting_labels labels={@current_dispute.labels} />
          </:labels>
          
          <:agreement>
            <.agreement_breakdown breakdown={@current_dispute.agreement_breakdown} />
          </:agreement>
          
          <:actions>
            <.verdict_form 
              schema={@current_dispute.schema}
              labels={@current_dispute.labels}
              available_actions={@current_dispute.available_actions}
            />
          </:actions>
        </.dispute_panel>
      <% else %>
        <.empty_state>
          <button phx-click="fetch_next">Fetch Next Dispute</button>
        </.empty_state>
      <% end %>
    </div>
    """
  end
end
```

---

## 11. Telemetry

```elixir
# Adjudication events
[:anvil, :adjudication, :dispute, :created]
[:anvil, :adjudication, :dispute, :assigned]
[:anvil, :adjudication, :dispute, :resolved]
[:anvil, :adjudication, :dispute, :escalated]
[:anvil, :adjudication, :dispute, :timeout]

[:anvil, :adjudication, :verdict, :submitted]
[:anvil, :adjudication, :verdict, :appealed]

[:anvil, :adjudication, :queue, :depth]
[:anvil, :adjudication, :adjudicator, :active]
```

---

## 12. Summary

Anvil.Adjudication provides:

| Component | Purpose |
|-----------|---------|
| **Dispute** | Representation of labeler disagreement |
| **Verdict** | Adjudicator's resolution |
| **Adjudicator** | Who can resolve (human, model, rule-based) |
| **DisputeQueue** | Queue of disputes awaiting resolution |
| **DetectionPolicy** | When labels become disputes |
| **Detector** | Pluggable detection strategies |
| **Resolver** | Pluggable resolution strategies |
| **Escalation** | Tiered escalation for complex disputes |

**Key design decisions**:
- Separate from labeling queues (different workflow)
- Adjudicators see the conflict, not just the sample
- Pluggable resolution (human, LLM-judge, majority rule)
- Tiered escalation for complex cases
- Full audit trail of decisions

---

*"Agreement metrics tell you there's a problem. Adjudication fixes it."*
