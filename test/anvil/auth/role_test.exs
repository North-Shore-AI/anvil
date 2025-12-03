defmodule Anvil.Auth.RoleTest do
  use Supertester.ExUnitFoundation, isolation: :full_isolation

  alias Anvil.Auth.Role

  describe "valid?/1" do
    test "returns true for valid roles" do
      assert Role.valid?(:labeler)
      assert Role.valid?(:auditor)
      assert Role.valid?(:adjudicator)
      assert Role.valid?(:admin)
    end

    test "returns false for invalid roles" do
      refute Role.valid?(:invalid)
      refute Role.valid?(:superuser)
      refute Role.valid?(nil)
      refute Role.valid?("labeler")
    end
  end

  describe "all/0" do
    test "returns all valid roles" do
      roles = Role.all()
      assert :labeler in roles
      assert :auditor in roles
      assert :adjudicator in roles
      assert :admin in roles
      assert length(roles) == 4
    end
  end

  describe "hierarchy/0" do
    test "returns role hierarchy mapping" do
      hierarchy = Role.hierarchy()
      assert is_map(hierarchy)
      assert Map.has_key?(hierarchy, :labeler)
      assert Map.has_key?(hierarchy, :auditor)
      assert Map.has_key?(hierarchy, :adjudicator)
      assert Map.has_key?(hierarchy, :admin)
    end

    test "admin has highest hierarchy level" do
      hierarchy = Role.hierarchy()
      admin_level = hierarchy[:admin]

      Enum.each([:labeler, :auditor, :adjudicator], fn role ->
        assert hierarchy[role] < admin_level
      end)
    end
  end

  describe "can_override?/2" do
    test "higher role can override lower role" do
      assert Role.can_override?(:admin, :adjudicator)
      assert Role.can_override?(:admin, :auditor)
      assert Role.can_override?(:admin, :labeler)
      assert Role.can_override?(:adjudicator, :labeler)
      assert Role.can_override?(:adjudicator, :auditor)
    end

    test "equal role can override itself" do
      assert Role.can_override?(:labeler, :labeler)
      assert Role.can_override?(:admin, :admin)
    end

    test "lower role cannot override higher role" do
      refute Role.can_override?(:labeler, :adjudicator)
      refute Role.can_override?(:labeler, :admin)
      refute Role.can_override?(:auditor, :adjudicator)
      refute Role.can_override?(:auditor, :admin)
    end

    test "returns false for invalid roles" do
      refute Role.can_override?(:invalid, :labeler)
      refute Role.can_override?(:admin, :invalid)
    end
  end

  describe "permissions/1" do
    test "labeler has basic permissions" do
      perms = Role.permissions(:labeler)
      assert :request_assignment in perms
      assert :submit_label in perms
      assert :view_own_labels in perms
      refute :view_all_labels in perms
      refute :export_data in perms
    end

    test "auditor has read-only analysis permissions" do
      perms = Role.permissions(:auditor)
      assert :view_all_labels in perms
      assert :export_data in perms
      assert :compute_agreement in perms
      refute :override_label in perms
      refute :manage_queue in perms
    end

    test "adjudicator has conflict resolution permissions" do
      perms = Role.permissions(:adjudicator)
      assert :override_label in perms
      assert :resolve_conflicts in perms
      assert :view_all_labels in perms
      refute :manage_queue in perms
      refute :manage_labelers in perms
    end

    test "admin has all permissions" do
      perms = Role.permissions(:admin)
      assert :manage_queue in perms
      assert :manage_labelers in perms
      assert :grant_access in perms
      assert :revoke_access in perms
      assert :override_label in perms
      assert :export_data in perms
    end

    test "returns empty list for invalid role" do
      assert Role.permissions(:invalid) == []
    end
  end

  describe "has_permission?/2" do
    test "checks if role has specific permission" do
      assert Role.has_permission?(:labeler, :request_assignment)
      assert Role.has_permission?(:auditor, :export_data)
      assert Role.has_permission?(:adjudicator, :override_label)
      assert Role.has_permission?(:admin, :manage_queue)
    end

    test "returns false if role lacks permission" do
      refute Role.has_permission?(:labeler, :export_data)
      refute Role.has_permission?(:auditor, :override_label)
      refute Role.has_permission?(:labeler, :manage_queue)
    end

    test "returns false for invalid role" do
      refute Role.has_permission?(:invalid, :request_assignment)
    end

    test "returns false for invalid permission" do
      refute Role.has_permission?(:admin, :invalid_permission)
    end
  end

  describe "default/0" do
    test "returns :labeler as default role" do
      assert Role.default() == :labeler
    end
  end
end
