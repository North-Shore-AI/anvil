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
end
