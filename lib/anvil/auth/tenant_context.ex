defmodule Anvil.Auth.TenantContext do
  @moduledoc """
  Multi-tenant isolation utilities for Anvil.

  Provides helper functions for enforcing tenant boundaries across
  all operations. Prevents cross-tenant data access by validating
  tenant_id matches between resources and actors.

  ## Tenant Isolation Principles

  1. **Default Deny**: All cross-tenant access is forbidden by default
  2. **Explicit Validation**: Every operation must validate tenant context
  3. **Filter at Source**: Apply tenant filters as early as possible
  4. **Audit Trail**: Log all tenant boundary violations

  ## Usage

  In context modules:

      def get_queue(id, labeler) do
        queue = Repo.get!(Queue, id)

        with :ok <- TenantContext.validate_tenant(queue, labeler) do
          {:ok, queue}
        end
      end

  In queries:

      def list_queues(labeler) do
        from(q in Queue)
        |> where([q], q.tenant_id == ^labeler.tenant_id)
        |> Repo.all()
      end
  """

  @type tenant_id :: String.t()
  @type tenant_resource :: %{tenant_id: tenant_id()}
  @type actor :: %{tenant_id: tenant_id()}
  @type error_reason :: :tenant_mismatch | :forbidden_cross_tenant_access

  @doc """
  Validates that a resource belongs to the actor's tenant.

  Returns `:ok` if tenant_ids match, `{:error, :tenant_mismatch}` otherwise.

  ## Examples

      iex> queue = %{id: "q1", tenant_id: "tenant-1"}
      iex> labeler = %{id: "l1", tenant_id: "tenant-1"}
      iex> TenantContext.validate_tenant(queue, labeler)
      :ok

      iex> queue = %{id: "q1", tenant_id: "tenant-1"}
      iex> labeler = %{id: "l1", tenant_id: "tenant-2"}
      iex> TenantContext.validate_tenant(queue, labeler)
      {:error, :tenant_mismatch}
  """
  @spec validate_tenant(tenant_resource(), actor()) :: :ok | {:error, error_reason()}
  def validate_tenant(resource, actor) do
    resource_tenant = extract_tenant_id(resource)
    actor_tenant = extract_tenant_id(actor)

    if resource_tenant == actor_tenant and not is_nil(resource_tenant) do
      :ok
    else
      {:error, :tenant_mismatch}
    end
  end

  @doc """
  Validates that all resources in a list belong to the actor's tenant.

  Returns `:ok` if all resources match, `{:error, :tenant_mismatch}` if any don't.

  ## Examples

      iex> resources = [
      ...>   %{id: "r1", tenant_id: "tenant-1"},
      ...>   %{id: "r2", tenant_id: "tenant-1"}
      ...> ]
      iex> labeler = %{id: "l1", tenant_id: "tenant-1"}
      iex> TenantContext.validate_tenant_list(resources, labeler)
      :ok
  """
  @spec validate_tenant_list([tenant_resource()], actor()) :: :ok | {:error, error_reason()}
  def validate_tenant_list(resources, actor) do
    actor_tenant = extract_tenant_id(actor)

    all_match? =
      Enum.all?(resources, fn resource ->
        extract_tenant_id(resource) == actor_tenant
      end)

    if all_match? do
      :ok
    else
      {:error, :tenant_mismatch}
    end
  end

  @doc """
  Filters a list of resources to only include those matching the actor's tenant.

  ## Examples

      iex> resources = [
      ...>   %{id: "r1", tenant_id: "tenant-1"},
      ...>   %{id: "r2", tenant_id: "tenant-2"}
      ...> ]
      iex> labeler = %{id: "l1", tenant_id: "tenant-1"}
      iex> filtered = TenantContext.filter_by_tenant(resources, labeler)
      iex> length(filtered)
      1
  """
  @spec filter_by_tenant([tenant_resource()], actor()) :: [tenant_resource()]
  def filter_by_tenant(resources, actor) do
    actor_tenant = extract_tenant_id(actor)

    Enum.filter(resources, fn resource ->
      extract_tenant_id(resource) == actor_tenant
    end)
  end

  @doc """
  Checks if two resources belong to the same tenant.

  ## Examples

      iex> r1 = %{id: "r1", tenant_id: "tenant-1"}
      iex> r2 = %{id: "r2", tenant_id: "tenant-1"}
      iex> TenantContext.same_tenant?(r1, r2)
      true
  """
  @spec same_tenant?(tenant_resource(), tenant_resource()) :: boolean()
  def same_tenant?(resource1, resource2) do
    tenant1 = extract_tenant_id(resource1)
    tenant2 = extract_tenant_id(resource2)

    not is_nil(tenant1) and tenant1 == tenant2
  end

  @doc """
  Ensures strict tenant isolation with forbidden error.

  Returns `:ok` if access allowed, `{:error, :forbidden_cross_tenant_access}` otherwise.
  Use this for operations that should never cross tenant boundaries.

  ## Options
    - `:error` - Custom error atom to return (default: :forbidden_cross_tenant_access)

  ## Examples

      iex> queue = %{id: "q1", tenant_id: "tenant-1"}
      iex> labeler = %{id: "l1", tenant_id: "tenant-1"}
      iex> TenantContext.ensure_tenant_isolation(queue, labeler)
      :ok
  """
  @spec ensure_tenant_isolation(tenant_resource(), actor(), keyword()) ::
          :ok | {:error, error_reason()}
  def ensure_tenant_isolation(resource, actor, opts \\ []) do
    error_atom = Keyword.get(opts, :error, :forbidden_cross_tenant_access)

    case validate_tenant(resource, actor) do
      :ok -> :ok
      {:error, _} -> {:error, error_atom}
    end
  end

  @doc """
  Adds tenant_id filter to a keyword list of query conditions.

  ## Examples

      iex> conditions = [status: :active]
      iex> TenantContext.tenant_scope(conditions, "tenant-1")
      [tenant_id: "tenant-1", status: :active]
  """
  @spec tenant_scope(keyword(), tenant_id()) :: keyword()
  def tenant_scope(conditions, tenant_id) when is_list(conditions) do
    Keyword.put(conditions, :tenant_id, tenant_id)
  end

  @doc """
  Extracts tenant_id from a resource or actor.

  Works with both structs and maps. Returns nil if tenant_id not found.

  ## Examples

      iex> resource = %{id: "r1", tenant_id: "tenant-1"}
      iex> TenantContext.extract_tenant_id(resource)
      "tenant-1"
  """
  @spec extract_tenant_id(tenant_resource() | actor()) :: tenant_id() | nil
  def extract_tenant_id(%{tenant_id: tenant_id}), do: tenant_id
  def extract_tenant_id(_), do: nil
end
