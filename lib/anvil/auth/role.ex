defmodule Anvil.Auth.Role do
  @moduledoc """
  Role definitions and hierarchy for Anvil access control.

  Defines four core roles:
  - `:labeler` - Request assignments, submit labels, view own labels
  - `:auditor` - View all labels, export data, compute agreement metrics (read-only)
  - `:adjudicator` - Resolve label conflicts, override labels, approve/reject labels
  - `:admin` - Manage queue membership, update policies, create queues, manage labelers

  Roles have a hierarchical relationship where higher roles inherit permissions from lower roles
  in the context of override operations.
  """

  @type role :: :labeler | :auditor | :adjudicator | :admin
  @type permission ::
          :request_assignment
          | :submit_label
          | :view_own_labels
          | :view_all_labels
          | :export_data
          | :compute_agreement
          | :override_label
          | :resolve_conflicts
          | :manage_queue
          | :manage_labelers
          | :grant_access
          | :revoke_access

  @roles [:labeler, :auditor, :adjudicator, :admin]

  @hierarchy %{
    labeler: 1,
    auditor: 2,
    adjudicator: 3,
    admin: 4
  }

  @permissions %{
    labeler: [
      :request_assignment,
      :submit_label,
      :view_own_labels
    ],
    auditor: [
      :view_all_labels,
      :export_data,
      :compute_agreement
    ],
    adjudicator: [
      :override_label,
      :resolve_conflicts,
      :view_all_labels,
      :export_data
    ],
    admin: [
      :manage_queue,
      :manage_labelers,
      :grant_access,
      :revoke_access,
      :override_label,
      :export_data,
      :view_all_labels,
      :compute_agreement
    ]
  }

  @doc """
  Returns all valid roles.

  ## Examples

      iex> Anvil.Auth.Role.all()
      [:labeler, :auditor, :adjudicator, :admin]
  """
  @spec all() :: [role()]
  def all, do: @roles

  @doc """
  Checks if a given value is a valid role.

  ## Examples

      iex> Anvil.Auth.Role.valid?(:labeler)
      true

      iex> Anvil.Auth.Role.valid?(:invalid)
      false
  """
  @spec valid?(any()) :: boolean()
  def valid?(role), do: role in @roles

  @doc """
  Returns the role hierarchy mapping.

  Higher numbers indicate higher privilege levels.

  ## Examples

      iex> hierarchy = Anvil.Auth.Role.hierarchy()
      iex> hierarchy[:admin] > hierarchy[:labeler]
      true
  """
  @spec hierarchy() :: %{role() => pos_integer()}
  def hierarchy, do: @hierarchy

  @doc """
  Checks if one role can override another role's decisions.

  Roles can override themselves or lower-level roles based on the hierarchy.

  ## Examples

      iex> Anvil.Auth.Role.can_override?(:admin, :labeler)
      true

      iex> Anvil.Auth.Role.can_override?(:labeler, :admin)
      false

      iex> Anvil.Auth.Role.can_override?(:adjudicator, :adjudicator)
      true
  """
  @spec can_override?(role(), role()) :: boolean()
  def can_override?(role1, role2) do
    with level1 when not is_nil(level1) <- @hierarchy[role1],
         level2 when not is_nil(level2) <- @hierarchy[role2] do
      level1 >= level2
    else
      _ -> false
    end
  end

  @doc """
  Returns the list of permissions for a given role.

  ## Examples

      iex> perms = Anvil.Auth.Role.permissions(:labeler)
      iex> :request_assignment in perms
      true
  """
  @spec permissions(role()) :: [permission()]
  def permissions(role) when role in @roles do
    Map.get(@permissions, role, [])
  end

  def permissions(_), do: []

  @doc """
  Checks if a role has a specific permission.

  ## Examples

      iex> Anvil.Auth.Role.has_permission?(:admin, :manage_queue)
      true

      iex> Anvil.Auth.Role.has_permission?(:labeler, :manage_queue)
      false
  """
  @spec has_permission?(role(), permission()) :: boolean()
  def has_permission?(role, permission) when role in @roles do
    permission in permissions(role)
  end

  def has_permission?(_, _), do: false

  @doc """
  Returns the default role for new labelers.

  ## Examples

      iex> Anvil.Auth.Role.default()
      :labeler
  """
  @spec default() :: role()
  def default, do: :labeler
end
