defmodule Anvil.Auth.SignedURL do
  @moduledoc """
  Time-limited signed URLs for secure asset access.

  Generates cryptographically signed URLs with expiration timestamps
  for accessing sensitive resources (samples, artifacts, etc).

  URLs contain:
  - Resource identifier
  - Expiration timestamp
  - HMAC signature (prevents tampering)

  ## Example

      # Generate signed URL (expires in 1 hour)
      {:ok, url} = SignedURL.generate("sample-123", secret, expires_in: 3600)

      # Verify URL before serving asset
      case SignedURL.verify(url, secret) do
        {:ok, resource_id} -> serve_asset(resource_id)
        {:error, :expired} -> {:error, :url_expired}
        {:error, :invalid_signature} -> {:error, :unauthorized}
      end
  """

  @type resource_id :: String.t()
  @type secret :: String.t()
  @type url :: String.t()
  @type opts :: keyword()
  @type error_reason :: :malformed_url | :invalid_signature | :expired

  @default_expires_in 3600

  @doc """
  Generates a signed URL for a resource.

  ## Options
    - `:expires_in` - Expiration time in seconds (default: 3600 / 1 hour)
    - `:tenant_id` - Include tenant ID in signature for multi-tenant isolation
    - `:base_url` - Base URL for the resource (default: "http://localhost/assets")

  ## Examples

      iex> {:ok, url} = SignedURL.generate("sample-123", "secret-key")
      iex> String.contains?(url, "sample-123")
      true

      iex> {:ok, url} = SignedURL.generate("sample-123", "secret", expires_in: 7200)
      iex> String.contains?(url, "signature=")
      true
  """
  @spec generate(resource_id(), secret(), opts()) :: {:ok, url()}
  def generate(resource_id, secret, opts \\ []) do
    expires_in = Keyword.get(opts, :expires_in, @default_expires_in)
    tenant_id = Keyword.get(opts, :tenant_id)
    base_url = Keyword.get(opts, :base_url, "http://localhost/assets")

    expires_at = DateTime.utc_now() |> DateTime.add(expires_in, :second) |> DateTime.to_unix()

    # Build signature payload
    payload = build_payload(resource_id, expires_at, tenant_id)
    signature = sign(payload, secret)

    # Build URL with query parameters
    url = "#{base_url}/#{resource_id}?expires=#{expires_at}&signature=#{signature}"

    {:ok, url}
  end

  @doc """
  Verifies a signed URL and returns the resource ID if valid.

  ## Options
    - `:tenant_id` - Expected tenant ID (must match signature)

  ## Examples

      iex> {:ok, url} = SignedURL.generate("sample-123", "secret")
      iex> SignedURL.verify(url, "secret")
      {:ok, "sample-123"}

      iex> SignedURL.verify("invalid-url", "secret")
      {:error, :malformed_url}
  """
  @spec verify(url(), secret(), opts()) :: {:ok, resource_id()} | {:error, error_reason()}
  def verify(url, secret, opts \\ []) do
    with {:ok, {resource_id, expires_at, signature}} <- parse_url(url),
         :ok <- check_expiration(expires_at),
         :ok <- verify_signature(resource_id, expires_at, signature, secret, opts) do
      {:ok, resource_id}
    end
  end

  @doc """
  Extracts the resource ID from a signed URL without verification.

  ## Examples

      iex> {:ok, url} = SignedURL.generate("sample-123", "secret")
      iex> SignedURL.extract_resource_id(url)
      {:ok, "sample-123"}
  """
  @spec extract_resource_id(url()) :: {:ok, resource_id()} | {:error, :malformed_url}
  def extract_resource_id(url) do
    case parse_url(url) do
      {:ok, {resource_id, _expires_at, _signature}} -> {:ok, resource_id}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Checks if a signed URL has expired.

  ## Examples

      iex> {:ok, url} = SignedURL.generate("sample-123", "secret", expires_in: 3600)
      iex> SignedURL.expired?(url)
      false
  """
  @spec expired?(url()) :: boolean()
  def expired?(url) do
    case parse_url(url) do
      {:ok, {_resource_id, expires_at, _signature}} ->
        now = DateTime.utc_now() |> DateTime.to_unix()
        now >= expires_at

      {:error, _} ->
        false
    end
  end

  @doc """
  Returns time remaining before URL expires (in seconds).

  Returns negative value if already expired.

  ## Examples

      iex> {:ok, url} = SignedURL.generate("sample-123", "secret", expires_in: 3600)
      iex> {:ok, remaining} = SignedURL.time_remaining(url)
      iex> remaining > 3595
      true
  """
  @spec time_remaining(url()) :: {:ok, integer()} | {:error, :malformed_url}
  def time_remaining(url) do
    case parse_url(url) do
      {:ok, {_resource_id, expires_at, _signature}} ->
        now = DateTime.utc_now() |> DateTime.to_unix()
        {:ok, expires_at - now}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Private helpers

  @spec parse_url(url()) ::
          {:ok, {resource_id(), integer(), String.t()}} | {:error, :malformed_url}
  defp parse_url(url) do
    with {:ok, uri} <- parse_uri(url),
         {:ok, resource_id} <- extract_resource_from_path(uri.path),
         {:ok, query_params} <- parse_query(uri.query),
         {:ok, expires_at} <- get_expires(query_params),
         {:ok, signature} <- get_signature(query_params) do
      {:ok, {resource_id, expires_at, signature}}
    else
      _ -> {:error, :malformed_url}
    end
  end

  defp parse_uri(url) when is_binary(url) do
    case URI.parse(url) do
      %URI{path: path, query: query} when not is_nil(path) and not is_nil(query) ->
        {:ok, %{path: path, query: query}}

      _ ->
        {:error, :malformed_url}
    end
  end

  defp parse_uri(_), do: {:error, :malformed_url}

  defp extract_resource_from_path(path) do
    case String.split(path, "/") |> List.last() do
      nil -> {:error, :malformed_url}
      "" -> {:error, :malformed_url}
      resource_id -> {:ok, resource_id}
    end
  end

  defp parse_query(query) when is_binary(query) do
    {:ok, URI.decode_query(query)}
  end

  defp get_expires(params) do
    case Map.get(params, "expires") do
      nil -> {:error, :malformed_url}
      expires_str -> parse_integer(expires_str)
    end
  end

  defp get_signature(params) do
    case Map.get(params, "signature") do
      nil -> {:error, :malformed_url}
      signature -> {:ok, signature}
    end
  end

  defp parse_integer(str) do
    case Integer.parse(str) do
      {int, ""} -> {:ok, int}
      _ -> {:error, :malformed_url}
    end
  end

  defp check_expiration(expires_at) do
    now = DateTime.utc_now() |> DateTime.to_unix()

    if now < expires_at do
      :ok
    else
      {:error, :expired}
    end
  end

  defp verify_signature(resource_id, expires_at, signature, secret, opts) do
    tenant_id = Keyword.get(opts, :tenant_id)
    payload = build_payload(resource_id, expires_at, tenant_id)
    expected_signature = sign(payload, secret)

    if secure_compare(signature, expected_signature) do
      :ok
    else
      {:error, :invalid_signature}
    end
  end

  defp build_payload(resource_id, expires_at, tenant_id) do
    base = "#{resource_id}:#{expires_at}"

    if tenant_id do
      "#{base}:#{tenant_id}"
    else
      base
    end
  end

  defp sign(payload, secret) do
    :crypto.mac(:hmac, :sha256, secret, payload)
    |> Base.encode16(case: :lower)
  end

  # Constant-time string comparison to prevent timing attacks
  defp secure_compare(a, b) when is_binary(a) and is_binary(b) do
    if byte_size(a) == byte_size(b) do
      secure_compare(a, b, 0) == 0
    else
      false
    end
  end

  defp secure_compare(<<a, rest_a::binary>>, <<b, rest_b::binary>>, acc) do
    import Bitwise
    secure_compare(rest_a, rest_b, acc ||| bxor(a, b))
  end

  defp secure_compare(<<>>, <<>>, acc), do: acc
end
