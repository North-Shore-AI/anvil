defmodule Anvil.Auth.ACLTest do
  use ExUnit.Case, async: true

  alias Anvil.Auth.ACL

  describe "QueueMembership struct" do
    test "creates membership with required fields" do
      membership = %ACL.QueueMembership{
        queue_id: "queue-1",
        labeler_id: "labeler-1",
        role: :labeler,
        tenant_id: "tenant-1"
      }

      assert membership.queue_id == "queue-1"
      assert membership.labeler_id == "labeler-1"
      assert membership.role == :labeler
      assert membership.tenant_id == "tenant-1"
    end

    test "has optional time-limited fields" do
      membership = %ACL.QueueMembership{
        queue_id: "queue-1",
        labeler_id: "labeler-1",
        role: :labeler,
        tenant_id: "tenant-1",
        expires_at: DateTime.utc_now(),
        revoked_at: nil
      }

      refute is_nil(membership.expires_at)
      assert is_nil(membership.revoked_at)
    end
  end

  describe "can_label?/2" do
    test "returns :ok when labeler has active membership with labeler role" do
      membership = %ACL.QueueMembership{
        queue_id: "queue-1",
        labeler_id: "labeler-1",
        role: :labeler,
        tenant_id: "tenant-1",
        expires_at: nil,
        revoked_at: nil
      }

      labeler = %{id: "labeler-1", tenant_id: "tenant-1"}
      queue = %{id: "queue-1", tenant_id: "tenant-1"}

      assert ACL.can_label?(labeler, queue, [membership]) == :ok
    end

    test "returns :ok when labeler has reviewer role" do
      membership = %ACL.QueueMembership{
        queue_id: "queue-1",
        labeler_id: "labeler-1",
        role: :reviewer,
        tenant_id: "tenant-1",
        expires_at: nil,
        revoked_at: nil
      }

      labeler = %{id: "labeler-1", tenant_id: "tenant-1"}
      queue = %{id: "queue-1", tenant_id: "tenant-1"}

      assert ACL.can_label?(labeler, queue, [membership]) == :ok
    end

    test "returns error when no membership exists" do
      labeler = %{id: "labeler-1", tenant_id: "tenant-1"}
      queue = %{id: "queue-1", tenant_id: "tenant-1"}

      assert ACL.can_label?(labeler, queue, []) == {:error, :not_member}
    end

    test "returns error when membership is revoked" do
      membership = %ACL.QueueMembership{
        queue_id: "queue-1",
        labeler_id: "labeler-1",
        role: :labeler,
        tenant_id: "tenant-1",
        expires_at: nil,
        revoked_at: DateTime.utc_now()
      }

      labeler = %{id: "labeler-1", tenant_id: "tenant-1"}
      queue = %{id: "queue-1", tenant_id: "tenant-1"}

      assert ACL.can_label?(labeler, queue, [membership]) == {:error, :membership_revoked}
    end

    test "returns error when membership is expired" do
      past_time = DateTime.add(DateTime.utc_now(), -3600, :second)

      membership = %ACL.QueueMembership{
        queue_id: "queue-1",
        labeler_id: "labeler-1",
        role: :labeler,
        tenant_id: "tenant-1",
        expires_at: past_time,
        revoked_at: nil
      }

      labeler = %{id: "labeler-1", tenant_id: "tenant-1"}
      queue = %{id: "queue-1", tenant_id: "tenant-1"}

      assert ACL.can_label?(labeler, queue, [membership]) == {:error, :membership_expired}
    end

    test "returns error when tenant_id mismatch" do
      membership = %ACL.QueueMembership{
        queue_id: "queue-1",
        labeler_id: "labeler-1",
        role: :labeler,
        tenant_id: "tenant-1",
        expires_at: nil,
        revoked_at: nil
      }

      labeler = %{id: "labeler-1", tenant_id: "tenant-2"}
      queue = %{id: "queue-1", tenant_id: "tenant-1"}

      assert ACL.can_label?(labeler, queue, [membership]) == {:error, :tenant_mismatch}
    end
  end

  describe "can_audit?/2" do
    test "returns :ok when labeler has reviewer role" do
      membership = %ACL.QueueMembership{
        queue_id: "queue-1",
        labeler_id: "auditor-1",
        role: :reviewer,
        tenant_id: "tenant-1",
        expires_at: nil,
        revoked_at: nil
      }

      auditor = %{id: "auditor-1", tenant_id: "tenant-1"}
      queue = %{id: "queue-1", tenant_id: "tenant-1"}

      assert ACL.can_audit?(auditor, queue, [membership]) == :ok
    end

    test "returns :ok when labeler has owner role" do
      membership = %ACL.QueueMembership{
        queue_id: "queue-1",
        labeler_id: "owner-1",
        role: :owner,
        tenant_id: "tenant-1",
        expires_at: nil,
        revoked_at: nil
      }

      owner = %{id: "owner-1", tenant_id: "tenant-1"}
      queue = %{id: "queue-1", tenant_id: "tenant-1"}

      assert ACL.can_audit?(owner, queue, [membership]) == :ok
    end

    test "returns error when labeler only has labeler role" do
      membership = %ACL.QueueMembership{
        queue_id: "queue-1",
        labeler_id: "labeler-1",
        role: :labeler,
        tenant_id: "tenant-1",
        expires_at: nil,
        revoked_at: nil
      }

      labeler = %{id: "labeler-1", tenant_id: "tenant-1"}
      queue = %{id: "queue-1", tenant_id: "tenant-1"}

      assert ACL.can_audit?(labeler, queue, [membership]) == {:error, :insufficient_permissions}
    end
  end

  describe "can_export?/2" do
    test "returns :ok when labeler has reviewer role" do
      membership = %ACL.QueueMembership{
        queue_id: "queue-1",
        labeler_id: "auditor-1",
        role: :reviewer,
        tenant_id: "tenant-1",
        expires_at: nil,
        revoked_at: nil
      }

      auditor = %{id: "auditor-1", tenant_id: "tenant-1"}
      queue = %{id: "queue-1", tenant_id: "tenant-1"}

      assert ACL.can_export?(auditor, queue, [membership]) == :ok
    end

    test "returns :ok when labeler has owner role" do
      membership = %ACL.QueueMembership{
        queue_id: "queue-1",
        labeler_id: "owner-1",
        role: :owner,
        tenant_id: "tenant-1",
        expires_at: nil,
        revoked_at: nil
      }

      owner = %{id: "owner-1", tenant_id: "tenant-1"}
      queue = %{id: "queue-1", tenant_id: "tenant-1"}

      assert ACL.can_export?(owner, queue, [membership]) == :ok
    end

    test "returns error when labeler only has labeler role" do
      membership = %ACL.QueueMembership{
        queue_id: "queue-1",
        labeler_id: "labeler-1",
        role: :labeler,
        tenant_id: "tenant-1",
        expires_at: nil,
        revoked_at: nil
      }

      labeler = %{id: "labeler-1", tenant_id: "tenant-1"}
      queue = %{id: "queue-1", tenant_id: "tenant-1"}

      assert ACL.can_export?(labeler, queue, [membership]) == {:error, :insufficient_permissions}
    end
  end

  describe "can_manage?/2" do
    test "returns :ok when labeler has owner role" do
      membership = %ACL.QueueMembership{
        queue_id: "queue-1",
        labeler_id: "owner-1",
        role: :owner,
        tenant_id: "tenant-1",
        expires_at: nil,
        revoked_at: nil
      }

      owner = %{id: "owner-1", tenant_id: "tenant-1"}
      queue = %{id: "queue-1", tenant_id: "tenant-1"}

      assert ACL.can_manage?(owner, queue, [membership]) == :ok
    end

    test "returns error when labeler has reviewer role" do
      membership = %ACL.QueueMembership{
        queue_id: "queue-1",
        labeler_id: "reviewer-1",
        role: :reviewer,
        tenant_id: "tenant-1",
        expires_at: nil,
        revoked_at: nil
      }

      reviewer = %{id: "reviewer-1", tenant_id: "tenant-1"}
      queue = %{id: "queue-1", tenant_id: "tenant-1"}

      assert ACL.can_manage?(reviewer, queue, [membership]) ==
               {:error, :insufficient_permissions}
    end

    test "returns error when labeler has labeler role" do
      membership = %ACL.QueueMembership{
        queue_id: "queue-1",
        labeler_id: "labeler-1",
        role: :labeler,
        tenant_id: "tenant-1",
        expires_at: nil,
        revoked_at: nil
      }

      labeler = %{id: "labeler-1", tenant_id: "tenant-1"}
      queue = %{id: "queue-1", tenant_id: "tenant-1"}

      assert ACL.can_manage?(labeler, queue, [membership]) == {:error, :insufficient_permissions}
    end
  end

  describe "grant_access/2" do
    test "creates new queue membership" do
      params = %{
        queue_id: "queue-1",
        labeler_id: "labeler-1",
        role: :labeler,
        tenant_id: "tenant-1",
        granted_by: "admin-1"
      }

      {:ok, membership} = ACL.grant_access(params)

      assert membership.queue_id == "queue-1"
      assert membership.labeler_id == "labeler-1"
      assert membership.role == :labeler
      assert membership.tenant_id == "tenant-1"
      assert membership.granted_by == "admin-1"
      assert membership.granted_at != nil
    end

    test "creates membership with expiration" do
      expires_at = DateTime.add(DateTime.utc_now(), 86400, :second)

      params = %{
        queue_id: "queue-1",
        labeler_id: "labeler-1",
        role: :labeler,
        tenant_id: "tenant-1",
        granted_by: "admin-1",
        expires_at: expires_at
      }

      {:ok, membership} = ACL.grant_access(params)

      assert membership.expires_at == expires_at
    end

    test "returns error when required fields missing" do
      params = %{queue_id: "queue-1"}

      assert {:error, _} = ACL.grant_access(params)
    end
  end

  describe "revoke_access/1" do
    test "marks membership as revoked" do
      membership = %ACL.QueueMembership{
        queue_id: "queue-1",
        labeler_id: "labeler-1",
        role: :labeler,
        tenant_id: "tenant-1",
        expires_at: nil,
        revoked_at: nil
      }

      {:ok, revoked} = ACL.revoke_access(membership)

      refute is_nil(revoked.revoked_at)
      assert DateTime.diff(revoked.revoked_at, DateTime.utc_now(), :second) <= 1
    end

    test "preserves other fields when revoking" do
      membership = %ACL.QueueMembership{
        queue_id: "queue-1",
        labeler_id: "labeler-1",
        role: :labeler,
        tenant_id: "tenant-1",
        granted_by: "admin-1",
        expires_at: nil,
        revoked_at: nil
      }

      {:ok, revoked} = ACL.revoke_access(membership)

      assert revoked.queue_id == membership.queue_id
      assert revoked.labeler_id == membership.labeler_id
      assert revoked.role == membership.role
      assert revoked.granted_by == membership.granted_by
    end
  end

  describe "active?/1" do
    test "returns true for active membership without expiration" do
      membership = %ACL.QueueMembership{
        queue_id: "queue-1",
        labeler_id: "labeler-1",
        role: :labeler,
        tenant_id: "tenant-1",
        expires_at: nil,
        revoked_at: nil
      }

      assert ACL.active?(membership) == true
    end

    test "returns true for active membership with future expiration" do
      future_time = DateTime.add(DateTime.utc_now(), 3600, :second)

      membership = %ACL.QueueMembership{
        queue_id: "queue-1",
        labeler_id: "labeler-1",
        role: :labeler,
        tenant_id: "tenant-1",
        expires_at: future_time,
        revoked_at: nil
      }

      assert ACL.active?(membership) == true
    end

    test "returns false when membership is revoked" do
      membership = %ACL.QueueMembership{
        queue_id: "queue-1",
        labeler_id: "labeler-1",
        role: :labeler,
        tenant_id: "tenant-1",
        expires_at: nil,
        revoked_at: DateTime.utc_now()
      }

      assert ACL.active?(membership) == false
    end

    test "returns false when membership is expired" do
      past_time = DateTime.add(DateTime.utc_now(), -3600, :second)

      membership = %ACL.QueueMembership{
        queue_id: "queue-1",
        labeler_id: "labeler-1",
        role: :labeler,
        tenant_id: "tenant-1",
        expires_at: past_time,
        revoked_at: nil
      }

      assert ACL.active?(membership) == false
    end
  end

  describe "filter_active/1" do
    test "filters out revoked and expired memberships" do
      active = %ACL.QueueMembership{
        queue_id: "queue-1",
        labeler_id: "labeler-1",
        role: :labeler,
        tenant_id: "tenant-1",
        expires_at: nil,
        revoked_at: nil
      }

      revoked = %ACL.QueueMembership{
        queue_id: "queue-2",
        labeler_id: "labeler-1",
        role: :labeler,
        tenant_id: "tenant-1",
        expires_at: nil,
        revoked_at: DateTime.utc_now()
      }

      expired = %ACL.QueueMembership{
        queue_id: "queue-3",
        labeler_id: "labeler-1",
        role: :labeler,
        tenant_id: "tenant-1",
        expires_at: DateTime.add(DateTime.utc_now(), -3600, :second),
        revoked_at: nil
      }

      result = ACL.filter_active([active, revoked, expired])

      assert length(result) == 1
      assert hd(result).queue_id == "queue-1"
    end

    test "returns empty list when all memberships are inactive" do
      revoked = %ACL.QueueMembership{
        queue_id: "queue-1",
        labeler_id: "labeler-1",
        role: :labeler,
        tenant_id: "tenant-1",
        expires_at: nil,
        revoked_at: DateTime.utc_now()
      }

      assert ACL.filter_active([revoked]) == []
    end

    test "returns all when all memberships are active" do
      m1 = %ACL.QueueMembership{
        queue_id: "queue-1",
        labeler_id: "labeler-1",
        role: :labeler,
        tenant_id: "tenant-1",
        expires_at: nil,
        revoked_at: nil
      }

      m2 = %ACL.QueueMembership{
        queue_id: "queue-2",
        labeler_id: "labeler-1",
        role: :reviewer,
        tenant_id: "tenant-1",
        expires_at: nil,
        revoked_at: nil
      }

      result = ACL.filter_active([m1, m2])
      assert length(result) == 2
    end
  end
end
