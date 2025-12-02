defmodule Anvil.AgreementTest do
  use Supertester.ExUnitFoundation, isolation: :full_isolation

  alias Anvil.{Label, Agreement}

  describe "Cohen's kappa" do
    test "computes perfect agreement" do
      labels = [
        %Label{id: "l1", sample_id: "s1", labeler_id: "r1", values: %{"cat" => "a"}},
        %Label{id: "l2", sample_id: "s1", labeler_id: "r2", values: %{"cat" => "a"}},
        %Label{id: "l3", sample_id: "s2", labeler_id: "r1", values: %{"cat" => "b"}},
        %Label{id: "l4", sample_id: "s2", labeler_id: "r2", values: %{"cat" => "b"}}
      ]

      {:ok, kappa} = Agreement.compute(labels, metric: :cohen)
      assert_in_delta kappa, 1.0, 0.01
    end

    test "computes no agreement beyond chance" do
      labels = [
        %Label{id: "l1", sample_id: "s1", labeler_id: "r1", values: %{"cat" => "a"}},
        %Label{id: "l2", sample_id: "s1", labeler_id: "r2", values: %{"cat" => "b"}},
        %Label{id: "l3", sample_id: "s2", labeler_id: "r1", values: %{"cat" => "b"}},
        %Label{id: "l4", sample_id: "s2", labeler_id: "r2", values: %{"cat" => "a"}}
      ]

      {:ok, kappa} = Agreement.compute(labels, metric: :cohen)
      # Should be close to 0 or negative
      assert kappa < 0.3
    end

    test "computes partial agreement" do
      labels = [
        %Label{id: "l1", sample_id: "s1", labeler_id: "r1", values: %{"cat" => "a"}},
        %Label{id: "l2", sample_id: "s1", labeler_id: "r2", values: %{"cat" => "a"}},
        %Label{id: "l3", sample_id: "s2", labeler_id: "r1", values: %{"cat" => "a"}},
        %Label{id: "l4", sample_id: "s2", labeler_id: "r2", values: %{"cat" => "a"}},
        %Label{id: "l5", sample_id: "s3", labeler_id: "r1", values: %{"cat" => "a"}},
        %Label{id: "l6", sample_id: "s3", labeler_id: "r2", values: %{"cat" => "b"}},
        %Label{id: "l7", sample_id: "s4", labeler_id: "r1", values: %{"cat" => "b"}},
        %Label{id: "l8", sample_id: "s4", labeler_id: "r2", values: %{"cat" => "a"}}
      ]

      {:ok, kappa} = Agreement.compute(labels, metric: :cohen)
      # 2 agreements out of 4 samples = 50% observed
      # With balanced categories, expected is ~50%, so kappa should be low
      assert kappa >= -0.5
      assert kappa < 1.0
    end

    test "requires exactly two raters" do
      labels = [
        %Label{id: "l1", sample_id: "s1", labeler_id: "r1", values: %{"cat" => "a"}},
        %Label{id: "l2", sample_id: "s1", labeler_id: "r2", values: %{"cat" => "a"}},
        %Label{id: "l3", sample_id: "s1", labeler_id: "r3", values: %{"cat" => "a"}}
      ]

      assert {:error, :requires_exactly_two_raters} =
               Agreement.Cohen.compute(labels)
    end
  end

  describe "Fleiss' kappa" do
    test "computes perfect agreement for multiple raters" do
      labels = [
        %Label{id: "l1", sample_id: "s1", labeler_id: "r1", values: %{"cat" => "a"}},
        %Label{id: "l2", sample_id: "s1", labeler_id: "r2", values: %{"cat" => "a"}},
        %Label{id: "l3", sample_id: "s1", labeler_id: "r3", values: %{"cat" => "a"}},
        %Label{id: "l4", sample_id: "s2", labeler_id: "r1", values: %{"cat" => "b"}},
        %Label{id: "l5", sample_id: "s2", labeler_id: "r2", values: %{"cat" => "b"}},
        %Label{id: "l6", sample_id: "s2", labeler_id: "r3", values: %{"cat" => "b"}}
      ]

      {:ok, kappa} = Agreement.Fleiss.compute(labels)
      assert_in_delta kappa, 1.0, 0.01
    end

    test "computes partial agreement" do
      labels = [
        %Label{id: "l1", sample_id: "s1", labeler_id: "r1", values: %{"cat" => "a"}},
        %Label{id: "l2", sample_id: "s1", labeler_id: "r2", values: %{"cat" => "a"}},
        %Label{id: "l3", sample_id: "s1", labeler_id: "r3", values: %{"cat" => "b"}},
        %Label{id: "l4", sample_id: "s2", labeler_id: "r1", values: %{"cat" => "b"}},
        %Label{id: "l5", sample_id: "s2", labeler_id: "r2", values: %{"cat" => "b"}},
        %Label{id: "l6", sample_id: "s2", labeler_id: "r3", values: %{"cat" => "b"}},
        %Label{id: "l7", sample_id: "s3", labeler_id: "r1", values: %{"cat" => "a"}},
        %Label{id: "l8", sample_id: "s3", labeler_id: "r2", values: %{"cat" => "b"}},
        %Label{id: "l9", sample_id: "s3", labeler_id: "r3", values: %{"cat" => "a"}}
      ]

      {:ok, kappa} = Agreement.Fleiss.compute(labels)
      # Mixed agreement, should be between 0 and 1
      assert kappa >= 0.0
      assert kappa < 1.0
    end

    test "works with more than two raters" do
      labels = [
        %Label{id: "l1", sample_id: "s1", labeler_id: "r1", values: %{"cat" => "a"}},
        %Label{id: "l2", sample_id: "s1", labeler_id: "r2", values: %{"cat" => "a"}},
        %Label{id: "l3", sample_id: "s1", labeler_id: "r3", values: %{"cat" => "a"}},
        %Label{id: "l4", sample_id: "s1", labeler_id: "r4", values: %{"cat" => "a"}}
      ]

      assert {:ok, _kappa} = Agreement.Fleiss.compute(labels)
    end
  end

  describe "Krippendorff's alpha" do
    test "computes perfect agreement" do
      labels = [
        %Label{id: "l1", sample_id: "s1", labeler_id: "r1", values: %{"cat" => "a"}},
        %Label{id: "l2", sample_id: "s1", labeler_id: "r2", values: %{"cat" => "a"}},
        %Label{id: "l3", sample_id: "s2", labeler_id: "r1", values: %{"cat" => "b"}},
        %Label{id: "l4", sample_id: "s2", labeler_id: "r2", values: %{"cat" => "b"}}
      ]

      {:ok, alpha} = Agreement.Krippendorff.compute(labels)
      assert_in_delta alpha, 1.0, 0.01
    end

    test "handles missing data" do
      # Only one rater for s2
      labels = [
        %Label{id: "l1", sample_id: "s1", labeler_id: "r1", values: %{"cat" => "a"}},
        %Label{id: "l2", sample_id: "s1", labeler_id: "r2", values: %{"cat" => "a"}},
        %Label{id: "l3", sample_id: "s2", labeler_id: "r1", values: %{"cat" => "b"}},
        %Label{id: "l4", sample_id: "s3", labeler_id: "r1", values: %{"cat" => "a"}},
        %Label{id: "l5", sample_id: "s3", labeler_id: "r2", values: %{"cat" => "a"}}
      ]

      assert {:ok, _alpha} = Agreement.Krippendorff.compute(labels)
    end

    test "supports different distance metrics" do
      labels = [
        %Label{id: "l1", sample_id: "s1", labeler_id: "r1", values: %{"cat" => "a"}},
        %Label{id: "l2", sample_id: "s1", labeler_id: "r2", values: %{"cat" => "a"}}
      ]

      assert {:ok, _} = Agreement.Krippendorff.compute(labels, metric: :nominal)
      assert {:ok, _} = Agreement.Krippendorff.compute(labels, metric: :ordinal)
      assert {:ok, _} = Agreement.Krippendorff.compute(labels, metric: :interval)
    end
  end

  describe "auto-selection" do
    test "selects Cohen's kappa for two raters" do
      labels = [
        %Label{id: "l1", sample_id: "s1", labeler_id: "r1", values: %{"cat" => "a"}},
        %Label{id: "l2", sample_id: "s1", labeler_id: "r2", values: %{"cat" => "a"}}
      ]

      assert {:ok, _} = Agreement.compute(labels)
    end

    test "selects Fleiss' kappa for more than two raters" do
      labels = [
        %Label{id: "l1", sample_id: "s1", labeler_id: "r1", values: %{"cat" => "a"}},
        %Label{id: "l2", sample_id: "s1", labeler_id: "r2", values: %{"cat" => "a"}},
        %Label{id: "l3", sample_id: "s1", labeler_id: "r3", values: %{"cat" => "a"}}
      ]

      assert {:ok, _} = Agreement.compute(labels)
    end
  end

  test "computes agreement efficiently for large datasets" do
    # Generate 100 samples with 3 raters each
    labels =
      for sample_id <- 1..100,
          rater_id <- 1..3 do
        %Label{
          id: "l_#{sample_id}_#{rater_id}",
          sample_id: "s#{sample_id}",
          labeler_id: "r#{rater_id}",
          values: %{"cat" => Enum.random(["a", "b", "c"])}
        }
      end

    # Just ensure it completes without error
    assert {:ok, _kappa} = Agreement.Fleiss.compute(labels)
  end

  describe "compute_for_field/3" do
    test "computes agreement for single dimension with perfect agreement" do
      labels = [
        %{sample_id: "s1", labeler_id: "l1", values: %{"coherence" => 4, "grounded" => 3}},
        %{sample_id: "s1", labeler_id: "l2", values: %{"coherence" => 4, "grounded" => 5}}
      ]

      {:ok, coherence_kappa} = Agreement.compute_for_field(labels, "coherence")
      # Both labelers gave coherence=4, so perfect agreement
      assert coherence_kappa == 1.0
    end

    test "handles labels with missing field values" do
      labels = [
        %{sample_id: "s1", labeler_id: "l1", values: %{"coherence" => 4, "grounded" => 3}},
        %{sample_id: "s1", labeler_id: "l2", values: %{"coherence" => 5}},
        # l3 has no coherence value
        %{sample_id: "s1", labeler_id: "l3", values: %{"grounded" => 3}}
      ]

      # Should compute agreement on coherence using only l1 and l2
      {:ok, _kappa} = Agreement.compute_for_field(labels, "coherence")
    end

    test "returns error when insufficient labels for a field" do
      labels = [
        %{sample_id: "s1", labeler_id: "l1", values: %{"coherence" => 4}}
        # Only one labeler has coherence value
      ]

      assert {:error, :insufficient_labels} = Agreement.compute_for_field(labels, "coherence")
    end

    test "returns error when all values are nil" do
      labels = [
        %{sample_id: "s1", labeler_id: "l1", values: %{"grounded" => 3}},
        %{sample_id: "s1", labeler_id: "l2", values: %{"grounded" => 5}}
      ]

      assert {:error, :insufficient_labels} = Agreement.compute_for_field(labels, "coherence")
    end
  end

  describe "compute_all_dimensions/3" do
    test "computes agreement for all fields in schema" do
      labels = [
        %{
          sample_id: "s1",
          labeler_id: "l1",
          values: %{"coherence" => 4, "grounded" => 3, "balance" => 2}
        },
        %{
          sample_id: "s1",
          labeler_id: "l2",
          values: %{"coherence" => 4, "grounded" => 3, "balance" => 4}
        }
      ]

      schema = %{fields: ["coherence", "grounded", "balance"]}

      result = Agreement.compute_all_dimensions(labels, schema)

      assert is_map(result)
      assert Map.has_key?(result, :coherence)
      assert Map.has_key?(result, :grounded)
      assert Map.has_key?(result, :balance)
    end

    test "handles empty fields list" do
      labels = [
        %{sample_id: "s1", labeler_id: "l1", values: %{"coherence" => 4}},
        %{sample_id: "s1", labeler_id: "l2", values: %{"coherence" => 5}}
      ]

      schema = %{fields: []}

      result = Agreement.compute_all_dimensions(labels, schema)
      assert result == %{}
    end
  end

  describe "summary/3" do
    test "returns comprehensive agreement summary" do
      labels = [
        %{
          sample_id: "s1",
          labeler_id: "l1",
          assignment_id: "a1",
          values: %{"coherence" => 4, "grounded" => 3}
        },
        %{
          sample_id: "s1",
          labeler_id: "l2",
          assignment_id: "a1",
          values: %{"coherence" => 4, "grounded" => 5}
        },
        %{
          sample_id: "s2",
          labeler_id: "l3",
          assignment_id: "a2",
          values: %{"coherence" => 3, "grounded" => 3}
        }
      ]

      schema = %{fields: ["coherence", "grounded"]}

      result = Agreement.summary(labels, schema)

      assert Map.has_key?(result, :overall)
      assert Map.has_key?(result, :by_dimension)
      assert result.sample_count == 2
      assert result.labeler_count == 3
      assert is_map(result.by_dimension)
    end
  end

  describe "Accumulator" do
    alias Anvil.Agreement.Accumulator

    test "new/0 creates empty accumulator" do
      acc = Accumulator.new()

      assert acc.confusion_matrix == %{}
      assert acc.label_counts == %{}
      assert acc.labeler_counts == %{}
      assert acc.last_updated == nil
    end

    test "add_label/2 updates labeler counts" do
      acc = Accumulator.new()
      label = %{labeler_id: "l1", values: %{"coherence" => 4}}

      acc = Accumulator.add_label(acc, label)

      assert acc.labeler_counts["l1"] == 1
      assert %DateTime{} = acc.last_updated
    end

    test "add_label/2 updates label counts for each field" do
      acc = Accumulator.new()
      label = %{labeler_id: "l1", values: %{"coherence" => 4, "grounded" => 3}}

      acc = Accumulator.add_label(acc, label)

      assert acc.label_counts[{"coherence", 4}] == 1
      assert acc.label_counts[{"grounded", 3}] == 1
    end

    test "add_label/2 accumulates multiple labels from same labeler" do
      acc = Accumulator.new()

      acc =
        acc
        |> Accumulator.add_label(%{labeler_id: "l1", values: %{"field" => "a"}})
        |> Accumulator.add_label(%{labeler_id: "l1", values: %{"field" => "b"}})

      assert acc.labeler_counts["l1"] == 2
    end

    test "compute_kappa/1 returns error for insufficient labelers" do
      acc = Accumulator.new()
      acc = Accumulator.add_label(acc, %{labeler_id: "l1", values: %{"field" => "a"}})

      assert {:error, :insufficient_labelers} = Accumulator.compute_kappa(acc)
    end

    test "compute_kappa/1 returns error for no labels" do
      acc = Accumulator.new()

      assert {:error, :no_labels} = Accumulator.compute_kappa(acc)
    end

    test "merge/2 combines two accumulators" do
      acc1 =
        Accumulator.new()
        |> Accumulator.add_label(%{labeler_id: "l1", values: %{"field" => "a"}})

      acc2 =
        Accumulator.new()
        |> Accumulator.add_label(%{labeler_id: "l2", values: %{"field" => "a"}})

      merged = Accumulator.merge(acc1, acc2)

      assert merged.labeler_counts["l1"] == 1
      assert merged.labeler_counts["l2"] == 1
      assert merged.label_counts[{"field", "a"}] == 2
    end

    test "merge/2 sums counts for overlapping keys" do
      acc1 =
        Accumulator.new()
        |> Accumulator.add_label(%{labeler_id: "l1", values: %{"field" => "a"}})

      acc2 =
        Accumulator.new()
        |> Accumulator.add_label(%{labeler_id: "l1", values: %{"field" => "b"}})

      merged = Accumulator.merge(acc1, acc2)

      assert merged.labeler_counts["l1"] == 2
    end
  end
end
