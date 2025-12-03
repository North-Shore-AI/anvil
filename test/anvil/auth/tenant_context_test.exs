defmodule Anvil.Auth.TenantContextTest do
  use Supertester.ExUnitFoundation, isolation: :full_isolation

  alias Anvil.Auth.TenantContext

  # Mock data structures for testing
  defmodule TestResource do
    defstruct [:id, :tenant_id, :name]
  end

  describe "validate_tenant/2" do
    test "returns :ok when tenant_ids match" do
      resource = %TestResource{id: "r1", tenant_id: "tenant-1", name: "Test"}
      labeler = %{id: "l1", tenant_id: "tenant-1"}

      assert TenantContext.validate_tenant(resource, labeler) == :ok
    end

    test "returns error when tenant_ids don't match" do
      resource = %TestResource{id: "r1", tenant_id: "tenant-1", name: "Test"}
      labeler = %{id: "l1", tenant_id: "tenant-2"}

      assert TenantContext.validate_tenant(resource, labeler) ==
               {:error, :tenant_mismatch}
    end

    test "handles nil tenant_id in resource" do
      resource = %TestResource{id: "r1", tenant_id: nil, name: "Test"}
      labeler = %{id: "l1", tenant_id: "tenant-1"}

      assert TenantContext.validate_tenant(resource, labeler) ==
               {:error, :tenant_mismatch}
    end

    test "handles nil tenant_id in labeler" do
      resource = %TestResource{id: "r1", tenant_id: "tenant-1", name: "Test"}
      labeler = %{id: "l1", tenant_id: nil}

      assert TenantContext.validate_tenant(resource, labeler) ==
               {:error, :tenant_mismatch}
    end
  end

  describe "validate_tenant_list/2" do
    test "returns :ok when all resources belong to labeler's tenant" do
      resources = [
        %TestResource{id: "r1", tenant_id: "tenant-1", name: "Test1"},
        %TestResource{id: "r2", tenant_id: "tenant-1", name: "Test2"}
      ]

      labeler = %{id: "l1", tenant_id: "tenant-1"}

      assert TenantContext.validate_tenant_list(resources, labeler) == :ok
    end

    test "returns error when any resource has wrong tenant_id" do
      resources = [
        %TestResource{id: "r1", tenant_id: "tenant-1", name: "Test1"},
        %TestResource{id: "r2", tenant_id: "tenant-2", name: "Test2"}
      ]

      labeler = %{id: "l1", tenant_id: "tenant-1"}

      assert TenantContext.validate_tenant_list(resources, labeler) ==
               {:error, :tenant_mismatch}
    end

    test "returns :ok for empty list" do
      labeler = %{id: "l1", tenant_id: "tenant-1"}

      assert TenantContext.validate_tenant_list([], labeler) == :ok
    end
  end

  describe "filter_by_tenant/2" do
    test "filters resources to match labeler's tenant" do
      resources = [
        %TestResource{id: "r1", tenant_id: "tenant-1", name: "Test1"},
        %TestResource{id: "r2", tenant_id: "tenant-2", name: "Test2"},
        %TestResource{id: "r3", tenant_id: "tenant-1", name: "Test3"}
      ]

      labeler = %{id: "l1", tenant_id: "tenant-1"}

      result = TenantContext.filter_by_tenant(resources, labeler)

      assert length(result) == 2
      assert Enum.all?(result, fn r -> r.tenant_id == "tenant-1" end)
    end

    test "returns empty list when no matches" do
      resources = [
        %TestResource{id: "r1", tenant_id: "tenant-2", name: "Test1"},
        %TestResource{id: "r2", tenant_id: "tenant-3", name: "Test2"}
      ]

      labeler = %{id: "l1", tenant_id: "tenant-1"}

      assert TenantContext.filter_by_tenant(resources, labeler) == []
    end

    test "handles empty input list" do
      labeler = %{id: "l1", tenant_id: "tenant-1"}

      assert TenantContext.filter_by_tenant([], labeler) == []
    end
  end

  describe "same_tenant?/2" do
    test "returns true when both have same tenant_id" do
      resource1 = %TestResource{id: "r1", tenant_id: "tenant-1", name: "Test1"}
      resource2 = %TestResource{id: "r2", tenant_id: "tenant-1", name: "Test2"}

      assert TenantContext.same_tenant?(resource1, resource2)
    end

    test "returns false when tenant_ids differ" do
      resource1 = %TestResource{id: "r1", tenant_id: "tenant-1", name: "Test1"}
      resource2 = %TestResource{id: "r2", tenant_id: "tenant-2", name: "Test2"}

      refute TenantContext.same_tenant?(resource1, resource2)
    end

    test "returns false when either has nil tenant_id" do
      resource1 = %TestResource{id: "r1", tenant_id: "tenant-1", name: "Test1"}
      resource2 = %TestResource{id: "r2", tenant_id: nil, name: "Test2"}

      refute TenantContext.same_tenant?(resource1, resource2)
    end
  end

  describe "ensure_tenant_isolation/2" do
    test "returns :ok when accessing own tenant's resource" do
      resource = %TestResource{id: "r1", tenant_id: "tenant-1", name: "Test"}
      labeler = %{id: "l1", tenant_id: "tenant-1"}

      assert TenantContext.ensure_tenant_isolation(resource, labeler) == :ok
    end

    test "returns error when accessing other tenant's resource" do
      resource = %TestResource{id: "r1", tenant_id: "tenant-2", name: "Test"}
      labeler = %{id: "l1", tenant_id: "tenant-1"}

      assert TenantContext.ensure_tenant_isolation(resource, labeler) ==
               {:error, :forbidden_cross_tenant_access}
    end

    test "returns error with custom message" do
      resource = %TestResource{id: "r1", tenant_id: "tenant-2", name: "Test"}
      labeler = %{id: "l1", tenant_id: "tenant-1"}

      assert TenantContext.ensure_tenant_isolation(
               resource,
               labeler,
               error: :custom_error
             ) == {:error, :custom_error}
    end
  end

  describe "tenant_scope/2" do
    test "adds tenant filter to list of conditions" do
      tenant_id = "tenant-1"
      conditions = [status: :active, archived: false]

      result = TenantContext.tenant_scope(conditions, tenant_id)

      assert result[:tenant_id] == tenant_id
      assert result[:status] == :active
      assert result[:archived] == false
    end

    test "creates new conditions with tenant filter" do
      tenant_id = "tenant-1"

      result = TenantContext.tenant_scope([], tenant_id)

      assert result == [tenant_id: tenant_id]
    end

    test "overwrites existing tenant_id in conditions" do
      tenant_id = "tenant-1"
      conditions = [tenant_id: "tenant-2", status: :active]

      result = TenantContext.tenant_scope(conditions, tenant_id)

      assert result[:tenant_id] == tenant_id
      assert result[:status] == :active
    end
  end

  describe "extract_tenant_id/1" do
    test "extracts tenant_id from struct" do
      resource = %TestResource{id: "r1", tenant_id: "tenant-1", name: "Test"}

      assert TenantContext.extract_tenant_id(resource) == "tenant-1"
    end

    test "extracts tenant_id from map" do
      resource = %{id: "r1", tenant_id: "tenant-1", name: "Test"}

      assert TenantContext.extract_tenant_id(resource) == "tenant-1"
    end

    test "returns nil when tenant_id not present" do
      resource = %{id: "r1", name: "Test"}

      assert TenantContext.extract_tenant_id(resource) == nil
    end
  end
end
