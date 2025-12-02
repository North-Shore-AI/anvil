defmodule Anvil.PII do
  @moduledoc """
  PII (Personally Identifiable Information) field annotation handling.

  This module provides functions for managing PII metadata on schema fields,
  including PII levels, retention policies, and redaction strategies.

  ## PII Levels

  - `:none` - No PII expected (e.g., boolean labels, enums)
  - `:possible` - May contain PII (free-text fields with guidelines to avoid PII)
  - `:likely` - Expected to contain PII (e.g., labeler feedback, error reports)
  - `:definite` - Always contains PII (e.g., labeler email, IP address)

  ## Retention Policies

  - `:indefinite` - Keep forever (structural labels with no PII)
  - `<integer>` - Days until eligible for deletion (e.g., 90, 365)

  ## Redaction Policies

  - `:preserve` - Keep field unchanged (explicit opt-in)
  - `:strip` - Remove field entirely
  - `:truncate` - Truncate to first N characters
  - `:hash` - Hash value (preserves uniqueness for grouping)
  - `:regex_redact` - Apply regex-based redaction patterns

  ## Examples

      iex> field_metadata = %{pii: :possible, retention_days: 365, redaction_policy: :truncate}
      iex> Anvil.PII.pii_level(field_metadata)
      :possible

      iex> Anvil.PII.redaction_policy(field_metadata)
      :truncate
  """

  @type pii_level :: :none | :possible | :likely | :definite
  @type retention_policy :: :indefinite | pos_integer()
  @type redaction_policy :: :preserve | :strip | :truncate | :hash | :regex_redact

  @doc """
  Returns the PII level for a field based on its metadata.

  Defaults to `:none` if not specified.
  """
  @spec pii_level(map()) :: pii_level()
  def pii_level(metadata) when is_map(metadata) do
    case Map.get(metadata, :pii) do
      level when level in [:none, :possible, :likely, :definite] -> level
      _ -> :none
    end
  end

  @doc """
  Returns the retention policy for a field based on its metadata.

  Defaults to `:indefinite` if not specified.
  """
  @spec retention_policy(map()) :: retention_policy()
  def retention_policy(metadata) when is_map(metadata) do
    case Map.get(metadata, :retention_days) do
      :indefinite -> :indefinite
      days when is_integer(days) and days > 0 -> days
      _ -> :indefinite
    end
  end

  @doc """
  Returns the redaction policy for a field based on its metadata.

  Defaults to automatic policy based on PII level if not specified:
  - `:none` -> `:preserve`
  - `:possible` -> `:truncate`
  - `:likely` -> `:strip`
  - `:definite` -> `:strip`
  """
  @spec redaction_policy(map()) :: redaction_policy()
  def redaction_policy(metadata) when is_map(metadata) do
    case Map.get(metadata, :redaction_policy) do
      policy when policy in [:preserve, :strip, :truncate, :hash, :regex_redact] ->
        policy

      _ ->
        # Default policy based on PII level
        case pii_level(metadata) do
          :none -> :preserve
          :possible -> :truncate
          :likely -> :strip
          :definite -> :strip
        end
    end
  end

  @doc """
  Checks if a field should be redacted during export based on redaction mode.

  ## Redaction Modes

  - `:none` - No redaction (trusted internal exports)
  - `:automatic` - Apply schema-defined redaction policies
  - `:aggressive` - Strip all fields with PII level `:possible` or higher

  ## Examples

      iex> field_meta = %{pii: :none}
      iex> Anvil.PII.should_redact?(field_meta, :automatic)
      false

      iex> field_meta = %{pii: :possible, redaction_policy: :truncate}
      iex> Anvil.PII.should_redact?(field_meta, :automatic)
      true

      iex> field_meta = %{pii: :possible}
      iex> Anvil.PII.should_redact?(field_meta, :aggressive)
      true
  """
  @spec should_redact?(map(), :none | :automatic | :aggressive) :: boolean()
  def should_redact?(_metadata, :none), do: false

  def should_redact?(metadata, :automatic) do
    redaction_policy(metadata) != :preserve
  end

  def should_redact?(metadata, :aggressive) do
    pii_level(metadata) in [:possible, :likely, :definite]
  end

  @doc """
  Returns true if the field has any PII risk (level other than :none).
  """
  @spec has_pii_risk?(map()) :: boolean()
  def has_pii_risk?(metadata) do
    pii_level(metadata) != :none
  end

  @doc """
  Calculates the expiration date for a field based on retention policy.

  Returns `nil` for indefinite retention.

  ## Examples

      iex> submitted_at = ~U[2025-01-01 00:00:00Z]
      iex> metadata = %{retention_days: 90}
      iex> Anvil.PII.expiration_date(metadata, submitted_at)
      ~U[2025-04-01 00:00:00Z]

      iex> metadata = %{retention_days: :indefinite}
      iex> Anvil.PII.expiration_date(metadata, ~U[2025-01-01 00:00:00Z])
      nil
  """
  @spec expiration_date(map(), DateTime.t()) :: DateTime.t() | nil
  def expiration_date(metadata, submitted_at) do
    case retention_policy(metadata) do
      :indefinite -> nil
      days when is_integer(days) -> DateTime.add(submitted_at, days, :day)
    end
  end

  @doc """
  Checks if a field is expired based on retention policy.

  ## Examples

      iex> submitted_at = ~U[2024-01-01 00:00:00Z]
      iex> now = ~U[2025-12-01 00:00:00Z]
      iex> metadata = %{retention_days: 90}
      iex> Anvil.PII.expired?(metadata, submitted_at, now)
      true

      iex> metadata = %{retention_days: :indefinite}
      iex> Anvil.PII.expired?(metadata, submitted_at, now)
      false
  """
  @spec expired?(map(), DateTime.t(), DateTime.t()) :: boolean()
  def expired?(metadata, submitted_at, now \\ DateTime.utc_now()) do
    case expiration_date(metadata, submitted_at) do
      nil -> false
      expiry -> DateTime.compare(now, expiry) == :gt
    end
  end

  @doc """
  Validates PII metadata structure.

  Returns `:ok` if valid, `{:error, reason}` otherwise.
  """
  @spec validate_metadata(map()) :: :ok | {:error, String.t()}
  def validate_metadata(metadata) when is_map(metadata) do
    with :ok <- validate_pii_level(Map.get(metadata, :pii)),
         :ok <- validate_retention_days(Map.get(metadata, :retention_days)),
         :ok <- validate_redaction_policy(Map.get(metadata, :redaction_policy)) do
      :ok
    end
  end

  defp validate_pii_level(nil), do: :ok
  defp validate_pii_level(level) when level in [:none, :possible, :likely, :definite], do: :ok
  defp validate_pii_level(_), do: {:error, "invalid PII level"}

  defp validate_retention_days(nil), do: :ok
  defp validate_retention_days(:indefinite), do: :ok
  defp validate_retention_days(days) when is_integer(days) and days > 0, do: :ok
  defp validate_retention_days(_), do: {:error, "invalid retention_days"}

  defp validate_redaction_policy(nil), do: :ok

  defp validate_redaction_policy(policy)
       when policy in [:preserve, :strip, :truncate, :hash, :regex_redact],
       do: :ok

  defp validate_redaction_policy(_), do: {:error, "invalid redaction_policy"}
end
