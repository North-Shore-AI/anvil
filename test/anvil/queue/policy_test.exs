defmodule Anvil.Queue.PolicyTest do
  use Supertester.ExUnitFoundation, isolation: :full_isolation

  alias Anvil.Queue.Policy

  describe "RoundRobin" do
    test "cycles through samples in order" do
      samples = [%{id: "s1"}, %{id: "s2"}, %{id: "s3"}]
      {:ok, state} = Policy.RoundRobin.init(%{})

      {:ok, first} = Policy.RoundRobin.next_assignment(state, "labeler1", samples)
      assert first.id == "s1"

      state = Policy.RoundRobin.update_state(state, first)
      {:ok, second} = Policy.RoundRobin.next_assignment(state, "labeler1", samples)
      assert second.id == "s2"

      state = Policy.RoundRobin.update_state(state, second)
      {:ok, third} = Policy.RoundRobin.next_assignment(state, "labeler1", samples)
      assert third.id == "s3"

      # Wraps around
      state = Policy.RoundRobin.update_state(state, third)
      {:ok, fourth} = Policy.RoundRobin.next_assignment(state, "labeler1", samples)
      assert fourth.id == "s1"
    end

    test "returns error when no samples available" do
      {:ok, state} = Policy.RoundRobin.init(%{})

      assert {:error, :no_samples_available} =
               Policy.RoundRobin.next_assignment(state, "labeler1", [])
    end
  end

  describe "Random" do
    test "selects a random sample from available" do
      samples = [%{id: "s1"}, %{id: "s2"}, %{id: "s3"}]
      {:ok, state} = Policy.Random.init(%{})

      {:ok, sample} = Policy.Random.next_assignment(state, "labeler1", samples)
      assert sample.id in ["s1", "s2", "s3"]
    end

    test "returns error when no samples available" do
      {:ok, state} = Policy.Random.init(%{})

      assert {:error, :no_samples_available} =
               Policy.Random.next_assignment(state, "labeler1", [])
    end

    test "state remains unchanged after assignment" do
      samples = [%{id: "s1"}]
      {:ok, state} = Policy.Random.init(%{})

      {:ok, _sample} = Policy.Random.next_assignment(state, "labeler1", samples)
      updated_state = Policy.Random.update_state(state, %{id: "s1"})

      assert state == updated_state
    end
  end

  describe "WeightedExpertise" do
    test "filters by minimum expertise" do
      config = %{
        expertise_scores: %{"expert" => 0.9, "novice" => 0.3},
        min_expertise: 0.5
      }

      {:ok, state} = Policy.WeightedExpertise.init(config)

      samples = [%{id: "s1", difficulty: 0.8}]

      assert {:ok, _} = Policy.WeightedExpertise.next_assignment(state, "expert", samples)

      assert {:error, :labeler_below_threshold} =
               Policy.WeightedExpertise.next_assignment(state, "novice", samples)
    end

    test "selects sample matching labeler expertise" do
      config = %{
        expertise_scores: %{"intermediate" => 0.6},
        min_expertise: 0.0
      }

      {:ok, state} = Policy.WeightedExpertise.init(config)

      samples = [
        %{id: "easy", difficulty: 0.3},
        %{id: "medium", difficulty: 0.5},
        %{id: "hard", difficulty: 0.9}
      ]

      {:ok, sample} = Policy.WeightedExpertise.next_assignment(state, "intermediate", samples)
      # Should prefer easier samples when expertise is 0.6
      assert sample.id in ["easy", "medium"]
    end

    test "returns error when no samples available" do
      {:ok, state} = Policy.WeightedExpertise.init(%{})

      assert {:error, :no_samples_available} =
               Policy.WeightedExpertise.next_assignment(state, "labeler1", [])
    end
  end

  describe "Redundancy" do
    test "returns samples needing more labels" do
      config = %{
        labels_per_sample: 3,
        label_counts: %{"s1" => 2, "s2" => 0, "s3" => 3}
      }

      {:ok, state} = Policy.Redundancy.init(config)

      samples = [
        # needs 1 more
        %{id: "s1"},
        # needs 3 more
        %{id: "s2"},
        # complete
        %{id: "s3"}
      ]

      # Should prioritize s2 (fewest labels)
      {:ok, sample} = Policy.Redundancy.next_assignment(state, "labeler1", samples)
      assert sample.id == "s2"
    end

    test "returns no_samples when all samples have k labels" do
      config = %{
        labels_per_sample: 2,
        label_counts: %{"s1" => 2, "s2" => 2}
      }

      {:ok, state} = Policy.Redundancy.init(config)

      samples = [%{id: "s1"}, %{id: "s2"}]

      assert {:error, :no_samples_available} =
               Policy.Redundancy.next_assignment(state, "labeler1", samples)
    end

    test "prevents same labeler from labeling twice when configured" do
      config = %{
        labels_per_sample: 3,
        allow_same_labeler: false,
        label_counts: %{
          "s1" => 1,
          "s1_labelers" => ["labeler1"]
        }
      }

      {:ok, state} = Policy.Redundancy.init(config)

      samples = [%{id: "s1"}]

      # labeler1 already labeled s1, should not get it again
      assert {:error, :no_samples_available} =
               Policy.Redundancy.next_assignment(state, "labeler1", samples)
    end

    test "allows same labeler when configured" do
      config = %{
        labels_per_sample: 3,
        allow_same_labeler: true,
        label_counts: %{
          "s1" => 1,
          "s1_labelers" => ["labeler1"]
        }
      }

      {:ok, state} = Policy.Redundancy.init(config)

      samples = [%{id: "s1"}]

      # labeler1 can label s1 again
      {:ok, sample} = Policy.Redundancy.next_assignment(state, "labeler1", samples)
      assert sample.id == "s1"
    end
  end

  describe "Composite" do
    test "chains multiple policies together" do
      config = %{
        policies: [
          {:weighted_expertise, %{expertise_scores: %{"expert" => 0.9}, min_expertise: 0.5}},
          :round_robin
        ]
      }

      {:ok, state} = Policy.Composite.init(config)

      samples = [%{id: "s1"}, %{id: "s2"}]

      # Should apply expertise check first, then round-robin selection
      {:ok, sample} = Policy.Composite.next_assignment(state, "expert", samples)
      assert sample.id in ["s1", "s2"]
    end

    test "stops chain on error" do
      config = %{
        policies: [
          {:weighted_expertise, %{expertise_scores: %{"novice" => 0.3}, min_expertise: 0.5}},
          :round_robin
        ]
      }

      {:ok, state} = Policy.Composite.init(config)

      samples = [%{id: "s1"}]

      # Should fail on expertise check before reaching round-robin
      assert {:error, :labeler_below_threshold} =
               Policy.Composite.next_assignment(state, "novice", samples)
    end

    test "updates all policy states" do
      config = %{
        policies: [:round_robin, :redundancy]
      }

      {:ok, state} = Policy.Composite.init(config)

      sample = %{id: "s1"}
      updated_state = Policy.Composite.update_state(state, sample)

      assert length(updated_state.policies) == 2
    end
  end
end
