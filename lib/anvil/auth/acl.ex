defmodule Anvil.Auth.ACL do
  @moduledoc """
  Access Control List (ACL) management for queue memberships.

  Implements queue-level access control with roles:
  - `:labeler` - Can request assignments and submit labels
  - `:reviewer` - Can view all labels, audit, and export data
  - `:owner` - Can manage queue membership and settings

  Supports time-limited access with expiration and revocation.
  """

  defmodule QueueMembership do
    @moduledoc """
    Represents a labeler's membership in a queue with specific role and permissions.
    """

    @type role :: :labeler | :reviewer | :owner

    @type t :: %__MODULE__{
            queue_id: String.t(),
            labeler_id: String.t(),
            role: role(),
            tenant_id: String.t(),
            granted_by: String.t() | nil,
            granted_at: DateTime.t() | nil,
            expires_at: DateTime.t() | nil,
            revoked_at: DateTime.t() | nil
          }

    @enforce_keys [:queue_id, :labeler_id, :role, :tenant_id]
    defstruct [
      :queue_id,
      :labeler_id,
      :role,
      :tenant_id,
      :granted_by,
      :granted_at,
      :expires_at,
      :revoked_at
    ]
  end

  alias __MODULE__.QueueMembership

  @type labeler :: %{id: String.t(), tenant_id: String.t()}
  @type queue :: %{id: String.t(), tenant_id: String.t()}
  @type error_reason ::
          :not_member
          | :membership_revoked
          | :membership_expired
          | :insufficient_permissions
          | :tenant_mismatch

  @doc """
  Checks if a labeler can label in a queue.

  Requires active membership with `:labeler`, `:reviewer`, or `:owner` role.

  ## Examples

      iex> membership = %QueueMembership{
      ...>   queue_id: "q1",
      ...>   labeler_id: "l1",
      ...>   role: :labeler,
      ...>   tenant_id: "t1",
      ...>   expires_at: nil,
      ...>   revoked_at: nil
      ...> }
      iex> labeler = %{id: "l1", tenant_id: "t1"}
      iex> queue = %{id: "q1", tenant_id: "t1"}
      iex> Anvil.Auth.ACL.can_label?(labeler, queue, [membership])
      :ok
  """
  @spec can_label?(labeler(), queue(), [QueueMembership.t()]) :: :ok | {:error, error_reason()}
  def can_label?(labeler, queue, memberships) do
    check_membership(labeler, queue, memberships, [:labeler, :reviewer, :owner])
  end

  @doc """
  Checks if a labeler can audit/view all labels in a queue.

  Requires active membership with `:reviewer` or `:owner` role.

  ## Examples

      iex> membership = %QueueMembership{
      ...>   queue_id: "q1",
      ...>   labeler_id: "l1",
      ...>   role: :reviewer,
      ...>   tenant_id: "t1",
      ...>   expires_at: nil,
      ...>   revoked_at: nil
      ...> }
      iex> labeler = %{id: "l1", tenant_id: "t1"}
      iex> queue = %{id: "q1", tenant_id: "t1"}
      iex> Anvil.Auth.ACL.can_audit?(labeler, queue, [membership])
      :ok
  """
  @spec can_audit?(labeler(), queue(), [QueueMembership.t()]) :: :ok | {:error, error_reason()}
  def can_audit?(labeler, queue, memberships) do
    check_membership(labeler, queue, memberships, [:reviewer, :owner])
  end

  @doc """
  Checks if a labeler can export data from a queue.

  Requires active membership with `:reviewer` or `:owner` role.

  ## Examples

      iex> membership = %QueueMembership{
      ...>   queue_id: "q1",
      ...>   labeler_id: "l1",
      ...>   role: :owner,
      ...>   tenant_id: "t1",
      ...>   expires_at: nil,
      ...>   revoked_at: nil
      ...> }
      iex> labeler = %{id: "l1", tenant_id: "t1"}
      iex> queue = %{id: "q1", tenant_id: "t1"}
      iex> Anvil.Auth.ACL.can_export?(labeler, queue, [membership])
      :ok
  """
  @spec can_export?(labeler(), queue(), [QueueMembership.t()]) :: :ok | {:error, error_reason()}
  def can_export?(labeler, queue, memberships) do
    check_membership(labeler, queue, memberships, [:reviewer, :owner])
  end

  @doc """
  Checks if a labeler can manage a queue (membership, settings).

  Requires active membership with `:owner` role.

  ## Examples

      iex> membership = %QueueMembership{
      ...>   queue_id: "q1",
      ...>   labeler_id: "l1",
      ...>   role: :owner,
      ...>   tenant_id: "t1",
      ...>   expires_at: nil,
      ...>   revoked_at: nil
      ...> }
      iex> labeler = %{id: "l1", tenant_id: "t1"}
      iex> queue = %{id: "q1", tenant_id: "t1"}
      iex> Anvil.Auth.ACL.can_manage?(labeler, queue, [membership])
      :ok
  """
  @spec can_manage?(labeler(), queue(), [QueueMembership.t()]) :: :ok | {:error, error_reason()}
  def can_manage?(labeler, queue, memberships) do
    check_membership(labeler, queue, memberships, [:owner])
  end

  @doc """
  Grants queue access to a labeler.

  ## Examples

      iex> params = %{
      ...>   queue_id: "q1",
      ...>   labeler_id: "l1",
      ...>   role: :labeler,
      ...>   tenant_id: "t1",
      ...>   granted_by: "admin1"
      ...> }
      iex> {:ok, membership} = Anvil.Auth.ACL.grant_access(params)
      iex> membership.role
      :labeler
  """
  @spec grant_access(map()) :: {:ok, QueueMembership.t()} | {:error, term()}
  def grant_access(params) do
    with :ok <- validate_grant_params(params) do
      membership = %QueueMembership{
        queue_id: params.queue_id,
        labeler_id: params.labeler_id,
        role: params.role,
        tenant_id: params.tenant_id,
        granted_by: params[:granted_by],
        granted_at: DateTime.utc_now(),
        expires_at: params[:expires_at],
        revoked_at: nil
      }

      {:ok, membership}
    end
  end

  @doc """
  Revokes queue access for a labeler.

  ## Examples

      iex> membership = %QueueMembership{
      ...>   queue_id: "q1",
      ...>   labeler_id: "l1",
      ...>   role: :labeler,
      ...>   tenant_id: "t1",
      ...>   expires_at: nil,
      ...>   revoked_at: nil
      ...> }
      iex> {:ok, revoked} = Anvil.Auth.ACL.revoke_access(membership)
      iex> revoked.revoked_at != nil
      true
  """
  @spec revoke_access(QueueMembership.t()) :: {:ok, QueueMembership.t()}
  def revoke_access(%QueueMembership{} = membership) do
    revoked = %{membership | revoked_at: DateTime.utc_now()}
    {:ok, revoked}
  end

  @doc """
  Checks if a membership is currently active.

  A membership is active if:
  - It has not been revoked
  - It has not expired

  ## Examples

      iex> membership = %QueueMembership{
      ...>   queue_id: "q1",
      ...>   labeler_id: "l1",
      ...>   role: :labeler,
      ...>   tenant_id: "t1",
      ...>   expires_at: nil,
      ...>   revoked_at: nil
      ...> }
      iex> Anvil.Auth.ACL.active?(membership)
      true
  """
  @spec active?(QueueMembership.t()) :: boolean()
  def active?(%QueueMembership{revoked_at: revoked_at, expires_at: expires_at}) do
    not_revoked = is_nil(revoked_at)
    not_expired = is_nil(expires_at) or DateTime.compare(expires_at, DateTime.utc_now()) == :gt

    not_revoked and not_expired
  end

  @doc """
  Filters a list of memberships to only active ones.

  ## Examples

      iex> active = %QueueMembership{
      ...>   queue_id: "q1",
      ...>   labeler_id: "l1",
      ...>   role: :labeler,
      ...>   tenant_id: "t1",
      ...>   expires_at: nil,
      ...>   revoked_at: nil
      ...> }
      iex> revoked = %QueueMembership{
      ...>   queue_id: "q2",
      ...>   labeler_id: "l1",
      ...>   role: :labeler,
      ...>   tenant_id: "t1",
      ...>   expires_at: nil,
      ...>   revoked_at: DateTime.utc_now()
      ...> }
      iex> result = Anvil.Auth.ACL.filter_active([active, revoked])
      iex> length(result)
      1
  """
  @spec filter_active([QueueMembership.t()]) :: [QueueMembership.t()]
  def filter_active(memberships) do
    Enum.filter(memberships, &active?/1)
  end

  # Private helpers

  @spec check_membership(labeler(), queue(), [QueueMembership.t()], [QueueMembership.role()]) ::
          :ok | {:error, error_reason()}
  defp check_membership(labeler, queue, memberships, allowed_roles) do
    # Check tenant match first
    if labeler.tenant_id != queue.tenant_id do
      {:error, :tenant_mismatch}
    else
      # Find membership for this labeler and queue
      membership =
        Enum.find(memberships, fn m ->
          m.queue_id == queue.id and m.labeler_id == labeler.id
        end)

      case membership do
        nil ->
          {:error, :not_member}

        %QueueMembership{revoked_at: revoked_at} when not is_nil(revoked_at) ->
          {:error, :membership_revoked}

        %QueueMembership{expires_at: expires_at} when not is_nil(expires_at) ->
          if DateTime.compare(expires_at, DateTime.utc_now()) == :lt do
            {:error, :membership_expired}
          else
            check_role(membership.role, allowed_roles)
          end

        %QueueMembership{role: role} ->
          check_role(role, allowed_roles)
      end
    end
  end

  @spec check_role(QueueMembership.role(), [QueueMembership.role()]) ::
          :ok | {:error, :insufficient_permissions}
  defp check_role(role, allowed_roles) do
    if role in allowed_roles do
      :ok
    else
      {:error, :insufficient_permissions}
    end
  end

  @spec validate_grant_params(map()) :: :ok | {:error, term()}
  defp validate_grant_params(params) do
    required = [:queue_id, :labeler_id, :role, :tenant_id]

    missing = Enum.filter(required, fn key -> not Map.has_key?(params, key) end)

    if missing == [] do
      :ok
    else
      {:error, {:missing_required_fields, missing}}
    end
  end
end
