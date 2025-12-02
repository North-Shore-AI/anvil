defmodule Anvil.PII.PseudonymTest do
  use ExUnit.Case, async: false

  alias Anvil.PII.Pseudonym
  alias Anvil.Repo
  alias Anvil.Schema.Labeler

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Anvil.Repo)
    :ok
  end

  describe "generate/2" do
    test "generates pseudonym with correct format" do
      pseudonym = Pseudonym.generate("user123", "tenant456")

      assert String.starts_with?(pseudonym, "labeler_")
      assert String.length(pseudonym) == 24
    end

    test "generates consistent pseudonyms for same input" do
      pseudonym1 = Pseudonym.generate("user123", "tenant456")
      pseudonym2 = Pseudonym.generate("user123", "tenant456")

      assert pseudonym1 == pseudonym2
    end

    test "generates different pseudonyms for different users" do
      pseudonym1 = Pseudonym.generate("user1", "tenant1")
      pseudonym2 = Pseudonym.generate("user2", "tenant1")

      assert pseudonym1 != pseudonym2
    end

    test "generates different pseudonyms for different tenants" do
      pseudonym1 = Pseudonym.generate("user1", "tenant1")
      pseudonym2 = Pseudonym.generate("user1", "tenant2")

      assert pseudonym1 != pseudonym2
    end

    test "defaults to 'default' tenant when not specified" do
      pseudonym1 = Pseudonym.generate("user1")
      pseudonym2 = Pseudonym.generate("user1", "default")

      assert pseudonym1 == pseudonym2
    end
  end

  describe "valid_format?/1" do
    test "validates correct pseudonym format" do
      # Generated pseudonyms are 16 hex chars after "labeler_"
      assert Pseudonym.valid_format?(Pseudonym.generate("test", "tenant"))
      assert Pseudonym.valid_format?("labeler_0123456789abcdef")
    end

    test "rejects invalid prefix" do
      refute Pseudonym.valid_format?("invalid_a1b2c3d4e5f6g7h8")
      refute Pseudonym.valid_format?("a1b2c3d4e5f6g7h8")
    end

    test "rejects invalid length" do
      refute Pseudonym.valid_format?("labeler_short")
      refute Pseudonym.valid_format?("labeler_toolongvalue1234567890")
    end

    test "rejects non-hex characters" do
      refute Pseudonym.valid_format?("labeler_XXXXXXXXXXXXXXXX")
      refute Pseudonym.valid_format?("labeler_hello world!")
    end

    test "handles non-string values" do
      refute Pseudonym.valid_format?(nil)
      refute Pseudonym.valid_format?(42)
    end
  end

  describe "ensure_pseudonym/1" do
    test "returns existing pseudonym if present" do
      labeler = %Labeler{
        external_id: "user123",
        tenant_id: "tenant1",
        pseudonym: "labeler_existing12345"
      }

      assert {:ok, "labeler_existing12345"} = Pseudonym.ensure_pseudonym(labeler)
    end

    test "generates and saves pseudonym if not present" do
      {:ok, labeler} =
        Repo.insert(%Labeler{
          id: Ecto.UUID.generate(),
          external_id: "user123",
          tenant_id: Ecto.UUID.generate(),
          pseudonym: nil
        })

      assert {:ok, pseudonym} = Pseudonym.ensure_pseudonym(labeler)
      assert String.starts_with?(pseudonym, "labeler_")

      # Verify it was saved to database
      updated_labeler = Repo.get!(Labeler, labeler.id)
      assert updated_labeler.pseudonym == pseudonym
    end
  end

  describe "export_identifier/1" do
    test "returns pseudonym for export" do
      labeler = %Labeler{
        external_id: "user123",
        tenant_id: "tenant1",
        pseudonym: "labeler_abc123def456"
      }

      assert {:ok, "labeler_abc123def456"} = Pseudonym.export_identifier(labeler)
    end

    test "generates pseudonym if not present" do
      {:ok, labeler} =
        Repo.insert(%Labeler{
          id: Ecto.UUID.generate(),
          external_id: "user456",
          tenant_id: Ecto.UUID.generate(),
          pseudonym: nil
        })

      assert {:ok, pseudonym} = Pseudonym.export_identifier(labeler)
      assert String.starts_with?(pseudonym, "labeler_")
    end
  end

  describe "rotate_secret/1" do
    test "rejects secrets that are too short" do
      assert {:error, :secret_too_short} = Pseudonym.rotate_secret("short")
    end

    test "rotates secret and regenerates pseudonyms" do
      # Create labelers
      tenant_id = Ecto.UUID.generate()

      {:ok, labeler1} =
        Repo.insert(%Labeler{
          id: Ecto.UUID.generate(),
          external_id: "user1",
          tenant_id: tenant_id,
          pseudonym: "labeler_old123456789"
        })

      {:ok, labeler2} =
        Repo.insert(%Labeler{
          id: Ecto.UUID.generate(),
          external_id: "user2",
          tenant_id: tenant_id,
          pseudonym: "labeler_old987654321"
        })

      # Generate a new secret (32+ characters)
      new_secret = String.duplicate("x", 32)

      # Rotate secret
      assert {:ok, count} = Pseudonym.rotate_secret(new_secret)
      assert count == 2

      # Verify pseudonyms were regenerated
      updated_labeler1 = Repo.get!(Labeler, labeler1.id)
      updated_labeler2 = Repo.get!(Labeler, labeler2.id)

      assert updated_labeler1.pseudonym != labeler1.pseudonym
      assert updated_labeler2.pseudonym != labeler2.pseudonym
      assert String.starts_with?(updated_labeler1.pseudonym, "labeler_")
      assert String.starts_with?(updated_labeler2.pseudonym, "labeler_")
    end
  end
end
