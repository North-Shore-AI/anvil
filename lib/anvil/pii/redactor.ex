defmodule Anvil.PII.Redactor do
  @moduledoc """
  Redaction strategies for PII fields during export.

  This module applies various redaction policies to field values to protect
  sensitive information while preserving analytical value.

  ## Redaction Strategies

  - `:preserve` - Keep field unchanged (explicit opt-in)
  - `:strip` - Remove field entirely (returns nil)
  - `:truncate` - Truncate to first N characters
  - `:hash` - Hash value (preserves uniqueness for grouping)
  - `:regex_redact` - Apply regex-based redaction patterns

  ## Examples

      iex> Anvil.PII.Redactor.redact("sensitive text", :strip)
      nil

      iex> Anvil.PII.Redactor.redact("long text here", :truncate, max_length: 10)
      "long text "

      iex> Anvil.PII.Redactor.redact("test@example.com", :hash)
      "a7b2c3..." # SHA256 hash
  """

  @default_truncate_length 100

  defp default_pii_patterns do
    [
      {~r/\b[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Z|a-z]{2,}\b/, "[EMAIL_REDACTED]"},
      {~r/\b\d{3}-\d{2}-\d{4}\b/, "[SSN_REDACTED]"},
      {~r/\b\d{3}-\d{3}-\d{4}\b/, "[PHONE_REDACTED]"},
      {~r/\b(?:\d{4}[-\s]?){3}\d{4}\b/, "[CREDIT_CARD_REDACTED]"}
    ]
  end

  @type redaction_policy :: :preserve | :strip | :truncate | :hash | :regex_redact
  @type redaction_opts :: keyword()

  @doc """
  Applies a redaction policy to a field value.

  ## Options

  - `:max_length` - Maximum length for `:truncate` policy (default: 100)
  - `:patterns` - List of {regex, replacement} tuples for `:regex_redact` (default: common PII patterns)
  - `:salt` - Salt for hashing (default: nil)

  ## Examples

      iex> Anvil.PII.Redactor.redact("value", :preserve)
      "value"

      iex> Anvil.PII.Redactor.redact("value", :strip)
      nil

      iex> Anvil.PII.Redactor.redact("long text", :truncate, max_length: 4)
      "long"

      iex> Anvil.PII.Redactor.redact("test", :hash)
      "9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08"
  """
  @spec redact(any(), redaction_policy(), redaction_opts()) :: any()
  def redact(value, policy, opts \\ [])

  def redact(nil, _policy, _opts), do: nil

  def redact(value, :preserve, _opts), do: value

  def redact(_value, :strip, _opts), do: nil

  def redact(value, :truncate, opts) when is_binary(value) do
    max_length = Keyword.get(opts, :max_length, @default_truncate_length)
    String.slice(value, 0, max_length)
  end

  def redact(value, :truncate, _opts), do: value

  def redact(value, :hash, opts) when is_binary(value) do
    salt = Keyword.get(opts, :salt, "")
    salted_value = salt <> value

    :crypto.hash(:sha256, salted_value)
    |> Base.encode16(case: :lower)
  end

  def redact(value, :hash, opts) do
    value
    |> to_string()
    |> redact(:hash, opts)
  end

  def redact(value, :regex_redact, opts) when is_binary(value) do
    patterns = Keyword.get(opts, :patterns, default_pii_patterns())

    Enum.reduce(patterns, value, fn {pattern, replacement}, acc ->
      Regex.replace(pattern, acc, replacement)
    end)
  end

  def redact(value, :regex_redact, _opts), do: value

  @doc """
  Redacts a map of field values based on field metadata.

  ## Parameters

  - `payload` - Map of field names to values
  - `field_metadata_map` - Map of field names to metadata maps
  - `redaction_mode` - Redaction mode (`:none`, `:automatic`, `:aggressive`)
  - `opts` - Additional options passed to redaction functions

  ## Examples

      iex> payload = %{"name" => "John", "age" => 30}
      iex> metadata = %{
      ...>   "name" => %{pii: :definite, redaction_policy: :strip},
      ...>   "age" => %{pii: :none}
      ...> }
      iex> Anvil.PII.Redactor.redact_payload(payload, metadata, :automatic)
      %{"age" => 30}
  """
  @spec redact_payload(map(), map(), :none | :automatic | :aggressive, keyword()) :: map()
  def redact_payload(payload, field_metadata_map, redaction_mode, opts \\ [])

  def redact_payload(payload, _field_metadata_map, :none, _opts), do: payload

  def redact_payload(payload, field_metadata_map, redaction_mode, opts)
      when redaction_mode in [:automatic, :aggressive] do
    Enum.reduce(payload, %{}, fn {field_name, value}, acc ->
      field_metadata = Map.get(field_metadata_map, field_name, %{})

      if Anvil.PII.should_redact?(field_metadata, redaction_mode) do
        policy = Anvil.PII.redaction_policy(field_metadata)
        redacted_value = redact(value, policy, opts)

        # Only include field if not stripped
        if redacted_value == nil do
          acc
        else
          Map.put(acc, field_name, redacted_value)
        end
      else
        Map.put(acc, field_name, value)
      end
    end)
  end

  @doc """
  Detects potential PII in a string value using regex patterns.

  Returns a list of detected PII types.

  ## Examples

      iex> Anvil.PII.Redactor.detect_pii("Contact me at test@example.com")
      [:email]

      iex> Anvil.PII.Redactor.detect_pii("Call 555-123-4567")
      [:phone]

      iex> Anvil.PII.Redactor.detect_pii("No PII here")
      []
  """
  @spec detect_pii(String.t()) :: [atom()]
  def detect_pii(value) when is_binary(value) do
    patterns = [
      {:email, ~r/\b[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Z|a-z]{2,}\b/},
      {:ssn, ~r/\b\d{3}-\d{2}-\d{4}\b/},
      {:phone, ~r/\b\d{3}-\d{3}-\d{4}\b/},
      {:credit_card, ~r/\b(?:\d{4}[-\s]?){3}\d{4}\b/}
    ]

    Enum.reduce(patterns, [], fn {type, pattern}, acc ->
      if Regex.match?(pattern, value) do
        [type | acc]
      else
        acc
      end
    end)
    |> Enum.reverse()
  end

  def detect_pii(_value), do: []

  @doc """
  Returns the default PII detection patterns.

  Each pattern is a tuple of `{regex, replacement_text}`.
  """
  @spec default_patterns() :: [{Regex.t(), String.t()}]
  def default_patterns, do: default_pii_patterns()
end
