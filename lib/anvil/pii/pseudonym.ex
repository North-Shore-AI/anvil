defmodule Anvil.PII.Pseudonym do
  @moduledoc """
  Labeler pseudonymization for privacy-preserving exports.

  This module generates stable pseudonyms for labelers that:
  - Are consistent within a tenant (same labeler always gets same pseudonym)
  - Are unlinkable across tenants (different pseudonym per tenant)
  - Cannot be reversed to recover the original external_id
  - Are suitable for publication in research datasets

  ## Security Properties

  - Uses HMAC-SHA256 for cryptographically secure hashing
  - Requires a secret key configured at application level
  - Includes tenant_id in hash to prevent cross-tenant linking
  - Truncates hash to 16 characters for readability

  ## Examples

      iex> Anvil.PII.Pseudonym.generate("user123", "tenant456")
      "labeler_a1b2c3d4e5f6g7h8"

      iex> Anvil.PII.Pseudonym.generate("user123", "tenant456")
      "labeler_a1b2c3d4e5f6g7h8"  # Same result (stable)

      iex> Anvil.PII.Pseudonym.generate("user123", "tenant789")
      "labeler_x9y8z7w6v5u4t3s2"  # Different result (tenant-specific)
  """

  @pseudonym_prefix "labeler_"
  @hash_length 16

  @doc """
  Generates a stable pseudonym for a labeler.

  ## Parameters

  - `external_id` - The labeler's external identifier (e.g., OIDC sub claim)
  - `tenant_id` - The tenant ID (optional, defaults to "default")

  ## Returns

  A pseudonym string in the format "labeler_XXXXXXXXXXXXXXXX" where X is a hex digit.

  ## Examples

      iex> Anvil.PII.Pseudonym.generate("user@example.com", "acme-corp")
      "labeler_7a3b9f2c1e4d8a6b"
  """
  @spec generate(String.t(), String.t() | nil) :: String.t()
  def generate(external_id, tenant_id \\ "default") do
    secret = get_secret()
    payload = "#{tenant_id}:#{external_id}"

    hash =
      :crypto.mac(:hmac, :sha256, secret, payload)
      |> Base.encode16(case: :lower)
      |> String.slice(0, @hash_length)

    @pseudonym_prefix <> hash
  end

  @doc """
  Validates that a string is a valid pseudonym format.

  ## Examples

      iex> Anvil.PII.Pseudonym.valid_format?("labeler_a1b2c3d4e5f6g7h8")
      true

      iex> Anvil.PII.Pseudonym.valid_format?("invalid")
      false

      iex> Anvil.PII.Pseudonym.valid_format?("labeler_short")
      false
  """
  @spec valid_format?(String.t()) :: boolean()
  def valid_format?(pseudonym) when is_binary(pseudonym) do
    case String.split_at(pseudonym, String.length(@pseudonym_prefix)) do
      {@pseudonym_prefix, hash} ->
        String.length(hash) == @hash_length && Regex.match?(~r/^[0-9a-f]+$/, hash)

      _ ->
        false
    end
  end

  def valid_format?(_), do: false

  @doc """
  Returns the pseudonym for a labeler, generating one if not present.

  This is the main entry point for ensuring labelers have pseudonyms.
  It will update the labeler record if a pseudonym needs to be generated.

  ## Parameters

  - `labeler` - An `Anvil.Schema.Labeler` struct

  ## Returns

  `{:ok, pseudonym}` or `{:error, reason}`

  ## Examples

      iex> labeler = %Labeler{external_id: "user123", tenant_id: "tenant1", pseudonym: nil}
      iex> Anvil.PII.Pseudonym.ensure_pseudonym(labeler)
      {:ok, "labeler_a1b2c3d4e5f6g7h8"}
  """
  @spec ensure_pseudonym(Anvil.Schema.Labeler.t()) ::
          {:ok, String.t()} | {:error, term()}
  def ensure_pseudonym(%Anvil.Schema.Labeler{pseudonym: pseudonym} = _labeler)
      when not is_nil(pseudonym) do
    {:ok, pseudonym}
  end

  def ensure_pseudonym(%Anvil.Schema.Labeler{} = labeler) do
    pseudonym = generate(labeler.external_id, labeler.tenant_id)

    case Anvil.Repo.update(Ecto.Changeset.change(labeler, %{pseudonym: pseudonym})) do
      {:ok, updated_labeler} -> {:ok, updated_labeler.pseudonym}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Returns the labeler identifier to use in exports.

  Always returns the pseudonym, never the external_id or internal UUID.
  Generates a pseudonym if one doesn't exist.

  ## Examples

      iex> labeler = %Labeler{pseudonym: "labeler_abc123"}
      iex> Anvil.PII.Pseudonym.export_identifier(labeler)
      {:ok, "labeler_abc123"}
  """
  @spec export_identifier(Anvil.Schema.Labeler.t()) :: {:ok, String.t()} | {:error, term()}
  def export_identifier(labeler) do
    ensure_pseudonym(labeler)
  end

  @doc """
  Rotates the pseudonym secret and regenerates all pseudonyms.

  WARNING: This breaks the linkage with previous exports. Only use when
  required for security purposes (e.g., secret compromise).

  This function should be called manually and will update all labeler records.

  ## Parameters

  - `new_secret` - The new secret to use for pseudonym generation

  ## Returns

  `{:ok, count}` where count is the number of labelers updated, or `{:error, reason}`
  """
  @spec rotate_secret(String.t()) :: {:ok, non_neg_integer()} | {:error, term()}
  def rotate_secret(new_secret) when byte_size(new_secret) >= 32 do
    # Update application config
    Application.put_env(:anvil, :pseudonym_secret, new_secret)

    # Regenerate all pseudonyms
    labelers = Anvil.Repo.all(Anvil.Schema.Labeler)

    results =
      Enum.map(labelers, fn labeler ->
        new_pseudonym = generate(labeler.external_id, labeler.tenant_id)

        Anvil.Repo.update(Ecto.Changeset.change(labeler, %{pseudonym: new_pseudonym}))
      end)

    success_count =
      Enum.count(results, fn
        {:ok, _} -> true
        {:error, _} -> false
      end)

    {:ok, success_count}
  end

  def rotate_secret(_), do: {:error, :secret_too_short}

  # Private functions

  defp get_secret do
    case Application.get_env(:anvil, :pseudonym_secret) do
      nil ->
        # Generate a default secret for development/testing
        # In production, this should be configured explicitly
        "anvil_default_pseudonym_secret_DO_NOT_USE_IN_PRODUCTION"

      secret ->
        secret
    end
  end
end
