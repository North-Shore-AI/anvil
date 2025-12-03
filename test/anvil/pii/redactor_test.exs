defmodule Anvil.PII.RedactorTest do
  use Supertester.ExUnitFoundation, isolation: :full_isolation

  alias Anvil.PII.Redactor

  describe "redact/3 with :preserve policy" do
    test "preserves original value" do
      assert Redactor.redact("sensitive", :preserve) == "sensitive"
      assert Redactor.redact(42, :preserve) == 42
      assert Redactor.redact(true, :preserve) == true
    end
  end

  describe "redact/3 with :strip policy" do
    test "strips all values" do
      assert Redactor.redact("sensitive", :strip) == nil
      assert Redactor.redact(42, :strip) == nil
      assert Redactor.redact(true, :strip) == nil
    end
  end

  describe "redact/3 with :truncate policy" do
    test "truncates long strings to default length" do
      long_text = String.duplicate("a", 200)
      result = Redactor.redact(long_text, :truncate)

      assert String.length(result) == 100
      assert String.starts_with?(result, "aaa")
    end

    test "truncates to custom length" do
      result = Redactor.redact("hello world", :truncate, max_length: 5)
      assert result == "hello"
    end

    test "preserves short strings unchanged" do
      result = Redactor.redact("short", :truncate)
      assert result == "short"
    end

    test "preserves non-string values unchanged" do
      assert Redactor.redact(42, :truncate) == 42
    end
  end

  describe "redact/3 with :hash policy" do
    test "hashes string values" do
      result = Redactor.redact("test", :hash)

      assert is_binary(result)
      assert String.length(result) == 64
      assert String.match?(result, ~r/^[0-9a-f]+$/)
    end

    test "produces consistent hashes" do
      hash1 = Redactor.redact("test", :hash)
      hash2 = Redactor.redact("test", :hash)

      assert hash1 == hash2
    end

    test "produces different hashes for different values" do
      hash1 = Redactor.redact("test1", :hash)
      hash2 = Redactor.redact("test2", :hash)

      assert hash1 != hash2
    end

    test "supports salt for additional security" do
      hash1 = Redactor.redact("test", :hash, salt: "salt1")
      hash2 = Redactor.redact("test", :hash, salt: "salt2")

      assert hash1 != hash2
    end

    test "hashes non-string values by converting to string" do
      result = Redactor.redact(42, :hash)

      assert is_binary(result)
      assert String.length(result) == 64
    end
  end

  describe "redact/3 with :regex_redact policy" do
    test "redacts email addresses" do
      result = Redactor.redact("Contact me at test@example.com", :regex_redact)
      assert result == "Contact me at [EMAIL_REDACTED]"
    end

    test "redacts SSN" do
      result = Redactor.redact("SSN: 123-45-6789", :regex_redact)
      assert result == "SSN: [SSN_REDACTED]"
    end

    test "redacts phone numbers" do
      result = Redactor.redact("Call 555-123-4567", :regex_redact)
      assert result == "Call [PHONE_REDACTED]"
    end

    test "redacts credit card numbers" do
      result = Redactor.redact("Card: 4111-1111-1111-1111", :regex_redact)
      assert result == "Card: [CREDIT_CARD_REDACTED]"
    end

    test "supports custom patterns" do
      patterns = [{~r/SECRET/, "REDACTED"}]
      result = Redactor.redact("This is a SECRET message", :regex_redact, patterns: patterns)
      assert result == "This is a REDACTED message"
    end

    test "preserves non-string values unchanged" do
      assert Redactor.redact(42, :regex_redact) == 42
    end
  end

  describe "redact_payload/4" do
    test "preserves all fields with :none mode" do
      payload = %{"name" => "John", "age" => 30}
      metadata = %{"name" => %{pii: :definite, redaction_policy: :strip}}

      result = Redactor.redact_payload(payload, metadata, :none)
      assert result == payload
    end

    test "applies schema-defined policies with :automatic mode" do
      payload = %{"name" => "John", "age" => 30}

      metadata = %{
        "name" => %{pii: :definite, redaction_policy: :strip},
        "age" => %{pii: :none}
      }

      result = Redactor.redact_payload(payload, metadata, :automatic)
      assert result == %{"age" => 30}
    end

    test "strips all PII fields with :aggressive mode" do
      payload = %{"name" => "John", "notes" => "private", "valid" => true}

      metadata = %{
        "name" => %{pii: :definite, redaction_policy: :strip},
        "notes" => %{pii: :possible, redaction_policy: :strip},
        "valid" => %{pii: :none}
      }

      result = Redactor.redact_payload(payload, metadata, :aggressive)
      assert result == %{"valid" => true}
    end

    test "applies truncation to specified fields" do
      long_text = String.duplicate("a", 200)
      payload = %{"notes" => long_text}

      metadata = %{
        "notes" => %{pii: :possible, redaction_policy: :truncate}
      }

      result = Redactor.redact_payload(payload, metadata, :automatic, max_length: 50)
      assert String.length(result["notes"]) <= 100
    end

    test "handles missing field metadata gracefully" do
      payload = %{"unknown_field" => "value"}
      metadata = %{}

      result = Redactor.redact_payload(payload, metadata, :automatic)
      assert result == payload
    end
  end

  describe "detect_pii/1" do
    test "detects email addresses" do
      assert Redactor.detect_pii("test@example.com") == [:email]
    end

    test "detects SSN" do
      assert Redactor.detect_pii("123-45-6789") == [:ssn]
    end

    test "detects phone numbers" do
      assert Redactor.detect_pii("555-123-4567") == [:phone]
    end

    test "detects credit card numbers" do
      assert Redactor.detect_pii("4111 1111 1111 1111") == [:credit_card]
    end

    test "detects multiple PII types" do
      text = "Email: test@example.com, Phone: 555-123-4567"
      result = Redactor.detect_pii(text)

      assert :email in result
      assert :phone in result
    end

    test "returns empty list when no PII detected" do
      assert Redactor.detect_pii("No PII here") == []
    end

    test "handles non-string values" do
      assert Redactor.detect_pii(42) == []
      assert Redactor.detect_pii(nil) == []
    end
  end

  describe "default_patterns/0" do
    test "returns list of regex patterns" do
      patterns = Redactor.default_patterns()

      assert is_list(patterns)
      assert length(patterns) > 0

      Enum.each(patterns, fn {regex, replacement} ->
        assert Regex.regex?(regex)
        assert is_binary(replacement)
      end)
    end
  end
end
