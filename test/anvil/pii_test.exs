defmodule Anvil.PIITest do
  use Supertester.ExUnitFoundation, isolation: :full_isolation

  alias Anvil.PII

  describe "pii_level/1" do
    test "returns PII level from metadata" do
      assert PII.pii_level(%{pii: :none}) == :none
      assert PII.pii_level(%{pii: :possible}) == :possible
      assert PII.pii_level(%{pii: :likely}) == :likely
      assert PII.pii_level(%{pii: :definite}) == :definite
    end

    test "defaults to :none when not specified" do
      assert PII.pii_level(%{}) == :none
      assert PII.pii_level(%{other: "field"}) == :none
    end
  end

  describe "retention_policy/1" do
    test "returns retention days from metadata" do
      assert PII.retention_policy(%{retention_days: 90}) == 90
      assert PII.retention_policy(%{retention_days: 365}) == 365
      assert PII.retention_policy(%{retention_days: :indefinite}) == :indefinite
    end

    test "defaults to :indefinite when not specified" do
      assert PII.retention_policy(%{}) == :indefinite
      assert PII.retention_policy(%{other: "field"}) == :indefinite
    end
  end

  describe "redaction_policy/1" do
    test "returns explicit redaction policy from metadata" do
      assert PII.redaction_policy(%{redaction_policy: :preserve}) == :preserve
      assert PII.redaction_policy(%{redaction_policy: :strip}) == :strip
      assert PII.redaction_policy(%{redaction_policy: :truncate}) == :truncate
      assert PII.redaction_policy(%{redaction_policy: :hash}) == :hash
      assert PII.redaction_policy(%{redaction_policy: :regex_redact}) == :regex_redact
    end

    test "defaults based on PII level" do
      assert PII.redaction_policy(%{pii: :none}) == :preserve
      assert PII.redaction_policy(%{pii: :possible}) == :truncate
      assert PII.redaction_policy(%{pii: :likely}) == :strip
      assert PII.redaction_policy(%{pii: :definite}) == :strip
    end
  end

  describe "should_redact?/2" do
    test "never redacts with :none mode" do
      refute PII.should_redact?(%{pii: :definite, redaction_policy: :strip}, :none)
    end

    test "redacts based on policy with :automatic mode" do
      refute PII.should_redact?(%{redaction_policy: :preserve}, :automatic)
      assert PII.should_redact?(%{redaction_policy: :strip}, :automatic)
      assert PII.should_redact?(%{redaction_policy: :truncate}, :automatic)
    end

    test "redacts all PII fields with :aggressive mode" do
      refute PII.should_redact?(%{pii: :none}, :aggressive)
      assert PII.should_redact?(%{pii: :possible}, :aggressive)
      assert PII.should_redact?(%{pii: :likely}, :aggressive)
      assert PII.should_redact?(%{pii: :definite}, :aggressive)
    end
  end

  describe "has_pii_risk?/1" do
    test "returns true for fields with PII risk" do
      assert PII.has_pii_risk?(%{pii: :possible})
      assert PII.has_pii_risk?(%{pii: :likely})
      assert PII.has_pii_risk?(%{pii: :definite})
    end

    test "returns false for fields without PII risk" do
      refute PII.has_pii_risk?(%{pii: :none})
      refute PII.has_pii_risk?(%{})
    end
  end

  describe "expiration_date/2" do
    test "calculates expiration date based on retention policy" do
      submitted_at = ~U[2025-01-01 00:00:00Z]
      metadata = %{retention_days: 90}

      expiration = PII.expiration_date(metadata, submitted_at)
      assert expiration == ~U[2025-04-01 00:00:00Z]
    end

    test "returns nil for indefinite retention" do
      submitted_at = ~U[2025-01-01 00:00:00Z]
      metadata = %{retention_days: :indefinite}

      assert PII.expiration_date(metadata, submitted_at) == nil
    end
  end

  describe "expired?/3" do
    test "returns true when field is expired" do
      submitted_at = ~U[2024-01-01 00:00:00Z]
      now = ~U[2025-12-01 00:00:00Z]
      metadata = %{retention_days: 90}

      assert PII.expired?(metadata, submitted_at, now)
    end

    test "returns false when field is not expired" do
      submitted_at = ~U[2025-11-01 00:00:00Z]
      now = ~U[2025-12-01 00:00:00Z]
      metadata = %{retention_days: 90}

      refute PII.expired?(metadata, submitted_at, now)
    end

    test "returns false for indefinite retention" do
      submitted_at = ~U[2020-01-01 00:00:00Z]
      now = ~U[2025-12-01 00:00:00Z]
      metadata = %{retention_days: :indefinite}

      refute PII.expired?(metadata, submitted_at, now)
    end
  end

  describe "validate_metadata/1" do
    test "validates valid metadata" do
      assert PII.validate_metadata(%{
               pii: :possible,
               retention_days: 90,
               redaction_policy: :truncate
             }) == :ok
    end

    test "rejects invalid PII level" do
      assert {:error, _} = PII.validate_metadata(%{pii: :invalid})
    end

    test "rejects invalid retention_days" do
      assert {:error, _} = PII.validate_metadata(%{retention_days: -1})
      assert {:error, _} = PII.validate_metadata(%{retention_days: "invalid"})
    end

    test "rejects invalid redaction_policy" do
      assert {:error, _} = PII.validate_metadata(%{redaction_policy: :invalid})
    end
  end
end
