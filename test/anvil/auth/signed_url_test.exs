defmodule Anvil.Auth.SignedURLTest do
  use Supertester.ExUnitFoundation, isolation: :full_isolation

  alias Anvil.Auth.SignedURL

  describe "generate/3" do
    test "generates signed URL with default expiration" do
      resource_id = "sample-123"
      secret = "test-secret-key"

      {:ok, url} = SignedURL.generate(resource_id, secret)

      assert is_binary(url)
      assert String.contains?(url, resource_id)
      assert String.contains?(url, "signature=")
      assert String.contains?(url, "expires=")
    end

    test "generates signed URL with custom expiration" do
      resource_id = "sample-123"
      secret = "test-secret-key"
      expires_in = 7200

      {:ok, url} = SignedURL.generate(resource_id, secret, expires_in: expires_in)

      assert is_binary(url)

      # Extract expiration timestamp
      [_, query] = String.split(url, "?")
      params = URI.decode_query(query)
      expires_ts = String.to_integer(params["expires"])

      # Check it's approximately 2 hours in future
      now = DateTime.utc_now() |> DateTime.to_unix()
      assert_in_delta expires_ts, now + expires_in, 5
    end

    test "includes tenant_id in signature when provided" do
      resource_id = "sample-123"
      secret = "test-secret-key"

      {:ok, url1} = SignedURL.generate(resource_id, secret, tenant_id: "tenant-1")
      {:ok, url2} = SignedURL.generate(resource_id, secret, tenant_id: "tenant-2")

      # Different tenant_ids should produce different signatures
      refute url1 == url2
    end

    test "different resources produce different signatures" do
      secret = "test-secret-key"

      {:ok, url1} = SignedURL.generate("sample-1", secret)
      {:ok, url2} = SignedURL.generate("sample-2", secret)

      refute url1 == url2
    end
  end

  describe "verify/3" do
    test "verifies valid signed URL" do
      resource_id = "sample-123"
      secret = "test-secret-key"

      {:ok, url} = SignedURL.generate(resource_id, secret)

      assert SignedURL.verify(url, secret) == {:ok, resource_id}
    end

    test "verifies URL with tenant_id" do
      resource_id = "sample-123"
      secret = "test-secret-key"
      tenant_id = "tenant-1"

      {:ok, url} = SignedURL.generate(resource_id, secret, tenant_id: tenant_id)

      assert SignedURL.verify(url, secret, tenant_id: tenant_id) == {:ok, resource_id}
    end

    test "rejects URL with wrong tenant_id" do
      resource_id = "sample-123"
      secret = "test-secret-key"

      {:ok, url} = SignedURL.generate(resource_id, secret, tenant_id: "tenant-1")

      assert SignedURL.verify(url, secret, tenant_id: "tenant-2") == {:error, :invalid_signature}
    end

    test "rejects URL with invalid signature" do
      resource_id = "sample-123"
      secret = "test-secret-key"

      {:ok, url} = SignedURL.generate(resource_id, secret)

      # Tamper with the URL
      tampered_url = String.replace(url, resource_id, "tampered-id")

      assert SignedURL.verify(tampered_url, secret) == {:error, :invalid_signature}
    end

    test "rejects URL with wrong secret" do
      resource_id = "sample-123"
      secret = "test-secret-key"

      {:ok, url} = SignedURL.generate(resource_id, secret)

      assert SignedURL.verify(url, "wrong-secret") == {:error, :invalid_signature}
    end

    test "rejects expired URL" do
      resource_id = "sample-123"
      secret = "test-secret-key"

      # Generate URL that expires in 1 second
      {:ok, url} = SignedURL.generate(resource_id, secret, expires_in: 1)

      # Wait for expiration (using a small buffer to avoid flakiness)
      Process.sleep(1100)

      assert SignedURL.verify(url, secret) == {:error, :expired}
    end

    test "rejects malformed URL" do
      secret = "test-secret-key"

      assert SignedURL.verify("not-a-url", secret) == {:error, :malformed_url}
      assert SignedURL.verify("http://example.com", secret) == {:error, :malformed_url}
    end

    test "rejects URL missing signature" do
      secret = "test-secret-key"
      url = "http://example.com/sample-123?expires=#{DateTime.utc_now() |> DateTime.to_unix()}"

      assert SignedURL.verify(url, secret) == {:error, :malformed_url}
    end

    test "rejects URL missing expiration" do
      secret = "test-secret-key"
      url = "http://example.com/sample-123?signature=abcd1234"

      assert SignedURL.verify(url, secret) == {:error, :malformed_url}
    end
  end

  describe "extract_resource_id/1" do
    test "extracts resource ID from valid URL" do
      resource_id = "sample-123"
      secret = "test-secret-key"

      {:ok, url} = SignedURL.generate(resource_id, secret)

      assert SignedURL.extract_resource_id(url) == {:ok, resource_id}
    end

    test "returns error for malformed URL" do
      assert SignedURL.extract_resource_id("not-a-url") == {:error, :malformed_url}
    end
  end

  describe "expired?/1" do
    test "returns false for non-expired URL" do
      resource_id = "sample-123"
      secret = "test-secret-key"

      {:ok, url} = SignedURL.generate(resource_id, secret, expires_in: 3600)

      refute SignedURL.expired?(url)
    end

    test "returns true for expired URL" do
      resource_id = "sample-123"
      secret = "test-secret-key"

      {:ok, url} = SignedURL.generate(resource_id, secret, expires_in: 1)
      Process.sleep(1100)

      assert SignedURL.expired?(url)
    end

    test "returns false for malformed URL (safe default)" do
      refute SignedURL.expired?("not-a-url")
    end
  end

  describe "time_remaining/1" do
    test "returns remaining time in seconds for valid URL" do
      resource_id = "sample-123"
      secret = "test-secret-key"
      expires_in = 3600

      {:ok, url} = SignedURL.generate(resource_id, secret, expires_in: expires_in)

      {:ok, remaining} = SignedURL.time_remaining(url)

      # Should be approximately 3600 seconds
      assert_in_delta remaining, expires_in, 5
    end

    test "returns negative value for expired URL" do
      resource_id = "sample-123"
      secret = "test-secret-key"

      {:ok, url} = SignedURL.generate(resource_id, secret, expires_in: 1)
      Process.sleep(1100)

      {:ok, remaining} = SignedURL.time_remaining(url)

      # Should be expired (0 or negative)
      assert remaining <= 0
    end

    test "returns error for malformed URL" do
      assert SignedURL.time_remaining("not-a-url") == {:error, :malformed_url}
    end
  end
end
