# ADR-010: Forge Integration and Sample Management

## Status
Accepted

## Context

Anvil manages labeling workflows, but the **samples** (data to be labeled) originate from **Forge**, the NSAI sample management system. This creates a fundamental integration dependency:

**Sample Lifecycle**:
1. **Forge** ingests raw data (text, images, model outputs) and versions samples
2. **Anvil** creates queues referencing Forge samples via `sample_id`
3. **Labelers** request assignments → Anvil must fetch sample content from Forge
4. **Labels** are submitted → associated with specific sample versions for reproducibility
5. **Exports** include both labels (Anvil) and sample content (Forge) for ML training

**Integration Requirements**:

| Requirement | Rationale |
|-------------|-----------|
| **Referential Integrity** | Prevent labeling deleted/non-existent samples |
| **Version Pinning** | Labels must reference specific sample versions (content may evolve) |
| **Performance** | Fetching sample content cannot block assignment dispatch (target <50ms) |
| **Data Locality** | Avoid cross-service joins; cache hot samples in Anvil |
| **Schema Isolation** | Anvil should not directly depend on Forge's Ecto schemas (prevent coupling) |
| **Fault Tolerance** | Degraded mode if Forge is unavailable (serve cached samples) |
| **Lineage Tracking** | Dataset exports must include Forge sample version metadata |

**Deployment Topologies** to support:

1. **Shared Postgres** (preferred for NSAI monorepo):
   - Forge and Anvil in same DB cluster, separate schemas (`forge` / `anvil`)
   - Foreign keys possible across schemas
   - Transactional consistency guarantees

2. **Separate Databases**:
   - Forge and Anvil in different Postgres instances
   - No foreign keys; eventual consistency via events
   - Required for independent scaling/deployment

3. **Service-Oriented** (future):
   - Forge as HTTP/gRPC service, Anvil as client
   - Network calls for sample fetching
   - Requires caching, circuit breakers

Current Anvil v0.1 has no Forge integration:
- Samples assumed to exist in-memory or mocked
- No version tracking or referential integrity
- Cannot support reproducible exports

## Decision

We will implement a **Forge Bridge** abstraction layer with pluggable backends (direct DB access, HTTP API, cached proxy) and explicit sample version pinning.

### 1. Forge Bridge Interface

**Core Abstraction**:

```elixir
defmodule Anvil.ForgeBridge do
  @moduledoc """
  Abstract interface for fetching samples from Forge.
  Supports multiple backends (direct DB, HTTP, cached).
  """

  @callback fetch_sample(sample_id :: binary(), opts :: keyword()) ::
    {:ok, sample_dto} | {:error, :not_found | :forge_unavailable | reason}

  @callback fetch_samples(sample_ids :: [binary()], opts :: keyword()) ::
    {:ok, [sample_dto]} | {:error, reason}

  @callback verify_sample_exists(sample_id :: binary()) :: boolean()

  @callback fetch_sample_version(sample_id :: binary()) :: {:ok, version_tag} | {:error, reason}

  # Sample DTO (Data Transfer Object)
  defmodule SampleDTO do
    @enforce_keys [:id, :content, :version]
    defstruct [
      :id,                # Sample UUID
      :content,           # Sample payload (text, image URL, etc.)
      :version,           # Forge version tag (e.g., "v2024-12-01" or content hash)
      :metadata,          # Optional metadata (tags, source, created_at)
      :asset_urls         # Pre-signed URLs for media assets
    ]
  end

  # Delegate to configured backend
  def fetch_sample(sample_id, opts \\ []) do
    backend().fetch_sample(sample_id, opts)
  end

  defp backend do
    Application.get_env(:anvil, :forge_bridge_backend, Anvil.ForgeBridge.DirectDB)
  end
end
```

### 2. Backend Implementations

#### Option A: Direct Database Access (Shared Postgres)

**Use Case**: NSAI monorepo deployment with single Postgres cluster

```elixir
defmodule Anvil.ForgeBridge.DirectDB do
  @behaviour Anvil.ForgeBridge

  alias Anvil.Repo
  import Ecto.Query

  @impl true
  def fetch_sample(sample_id, _opts) do
    # Query Forge schema directly (cross-schema query)
    case Repo.one(from s in "forge.samples", where: s.id == ^sample_id, select: s) do
      nil ->
        {:error, :not_found}

      sample_row ->
        {:ok, to_dto(sample_row)}
    end
  end

  @impl true
  def fetch_samples(sample_ids, opts) do
    # Batch query for performance
    samples =
      from(s in "forge.samples", where: s.id in ^sample_ids)
      |> Repo.all()

    {:ok, Enum.map(samples, &to_dto/1)}
  end

  @impl true
  def verify_sample_exists(sample_id) do
    Repo.exists?(from s in "forge.samples", where: s.id == ^sample_id)
  end

  @impl true
  def fetch_sample_version(sample_id) do
    case Repo.one(from s in "forge.samples", where: s.id == ^sample_id, select: s.version_tag) do
      nil -> {:error, :not_found}
      version -> {:ok, version}
    end
  end

  defp to_dto(%{id: id, content: content, version_tag: version, metadata: metadata}) do
    %ForgeBridge.SampleDTO{
      id: id,
      content: content,
      version: version,
      metadata: metadata,
      asset_urls: generate_asset_urls(metadata)
    }
  end

  defp generate_asset_urls(%{"asset_keys" => keys}) do
    # Generate pre-signed S3 URLs for assets
    Enum.map(keys, fn key ->
      ExAws.S3.presigned_url(s3_client(), :get, bucket(), key, expires_in: 3600)
    end)
  end
  defp generate_asset_urls(_), do: []
end
```

**Foreign Key Setup** (if using Option A):

```sql
-- In Anvil migration
CREATE TABLE anvil.assignments (
  id UUID PRIMARY KEY,
  queue_id UUID REFERENCES anvil.queues(id),
  sample_id UUID REFERENCES forge.samples(id),  -- Cross-schema FK
  -- ...
);

-- Ensure Forge samples are not deleted if referenced by assignments
ALTER TABLE forge.samples
ADD CONSTRAINT no_delete_if_labeled
CHECK (NOT EXISTS (
  SELECT 1 FROM anvil.assignments WHERE sample_id = id
));
```

**Pros**:
- No network overhead; single DB query (<5ms)
- Transactional consistency (sample + assignment created atomically)
- Referential integrity via foreign keys

**Cons**:
- Tight coupling between Anvil and Forge schemas
- Forge schema changes may break Anvil queries
- Cannot deploy Forge and Anvil to separate databases

#### Option B: HTTP API Client (Separate Services)

**Use Case**: Microservices deployment, independent scaling

```elixir
defmodule Anvil.ForgeBridge.HTTPClient do
  @behaviour Anvil.ForgeBridge

  @impl true
  def fetch_sample(sample_id, opts) do
    url = "#{forge_base_url()}/api/samples/#{sample_id}"
    headers = [{"Authorization", "Bearer #{api_token()}"}]

    case HTTPoison.get(url, headers, timeout: 5_000) do
      {:ok, %{status_code: 200, body: body}} ->
        {:ok, Jason.decode!(body, keys: :atoms) |> to_dto()}

      {:ok, %{status_code: 404}} ->
        {:error, :not_found}

      {:ok, %{status_code: status}} ->
        {:error, {:http_error, status}}

      {:error, %HTTPoison.Error{reason: reason}} ->
        Logger.error("Forge API unavailable: #{inspect(reason)}")
        {:error, :forge_unavailable}
    end
  end

  defp forge_base_url, do: Application.fetch_env!(:anvil, :forge_base_url)
  defp api_token, do: Application.fetch_env!(:anvil, :forge_api_token)

  defp to_dto(map) do
    %ForgeBridge.SampleDTO{
      id: map.id,
      content: map.content,
      version: map.version_tag,
      metadata: map.metadata,
      asset_urls: map.asset_urls
    }
  end
end
```

**Pros**:
- Independent deployment and scaling
- Clear service boundaries
- Language-agnostic (Forge could be rewritten in another language)

**Cons**:
- Network latency (~10-50ms per request)
- Requires API versioning and backward compatibility
- Circuit breaker needed for fault tolerance
- No transactional consistency (eventual consistency only)

#### Option C: Cached Proxy (Hybrid)

**Use Case**: Performance-critical paths with fallback

```elixir
defmodule Anvil.ForgeBridge.CachedProxy do
  @behaviour Anvil.ForgeBridge

  @cache_ttl :timer.minutes(15)

  @impl true
  def fetch_sample(sample_id, opts) do
    # Check cache first
    case Cachex.get(:forge_samples, sample_id) do
      {:ok, nil} ->
        # Cache miss, fetch from backend
        fetch_and_cache(sample_id, opts)

      {:ok, sample_dto} ->
        {:ok, sample_dto}

      {:error, _} ->
        # Cache error, bypass cache
        backend().fetch_sample(sample_id, opts)
    end
  end

  defp fetch_and_cache(sample_id, opts) do
    case backend().fetch_sample(sample_id, opts) do
      {:ok, sample_dto} = result ->
        Cachex.put(:forge_samples, sample_id, sample_dto, ttl: @cache_ttl)
        result

      error ->
        error
    end
  end

  defp backend do
    Application.get_env(:anvil, :forge_bridge_primary_backend, Anvil.ForgeBridge.DirectDB)
  end

  # Background cache warming for hot queues
  def warm_cache(queue_id) do
    sample_ids = Anvil.Queues.get_sample_ids(queue_id)

    Task.Supervisor.async_stream_nolink(
      Anvil.TaskSupervisor,
      sample_ids,
      fn sample_id -> fetch_sample(sample_id) end,
      max_concurrency: 10,
      timeout: 5_000
    )
    |> Stream.run()
  end
end
```

**Cache Invalidation**:
```elixir
# Invalidate cache when Forge publishes sample update event
Phoenix.PubSub.subscribe(Forge.PubSub, "sample_updates")

def handle_info({:sample_updated, sample_id}, state) do
  Cachex.del(:forge_samples, sample_id)
  {:noreply, state}
end
```

### 3. Sample Version Pinning

**Version Storage in Assignments**:

```elixir
schema "assignments" do
  belongs_to :queue, Queue
  field :sample_id, :binary_id
  field :sample_version, :string  # Forge version tag at assignment creation time

  # ...
end

# When creating assignment, capture current sample version
def create_assignment(queue_id, sample_id, labeler_id) do
  {:ok, sample} = ForgeBridge.fetch_sample(sample_id)

  %Assignment{}
  |> Assignment.changeset(%{
    queue_id: queue_id,
    sample_id: sample_id,
    sample_version: sample.version,  # Pin version
    labeler_id: labeler_id,
    status: :pending
  })
  |> Repo.insert()
end
```

**Version Verification in Exports**:

```elixir
defmodule Anvil.Export do
  def to_csv(queue_id, opts) do
    # Include sample version metadata in export manifest
    labels = stream_labels(queue_id, opts)

    sample_versions =
      labels
      |> Enum.map(& &1.assignment.sample_version)
      |> Enum.frequencies()

    manifest = %{
      queue_id: queue_id,
      schema_version_id: opts[:schema_version_id],
      sample_versions: sample_versions,  # e.g., %{"v2024-12-01" => 1450, "v2024-12-02" => 50}
      exported_at: DateTime.utc_now()
    }

    # Warn if multiple sample versions detected
    if map_size(sample_versions) > 1 do
      Logger.warn("Export contains multiple sample versions: #{inspect(sample_versions)}")
    end

    {:ok, manifest}
  end
end
```

### 4. DTO Layer (Schema Isolation)

**Why DTO?**
- Prevents direct dependency on Forge's Ecto schemas
- Allows Forge to evolve schemas without breaking Anvil
- Explicit contract for what data Anvil needs

**Sample DTO Definition**:

```elixir
defmodule Anvil.ForgeBridge.SampleDTO do
  @moduledoc """
  Data Transfer Object for samples fetched from Forge.
  Isolates Anvil from Forge's schema details.
  """

  @enforce_keys [:id, :content, :version]
  defstruct [
    :id,                # UUID
    :content,           # Primary sample content (text, JSON, etc.)
    :version,           # Version tag from Forge
    :metadata,          # Map of additional fields
    :asset_urls,        # List of pre-signed URLs for media
    :source,            # Source system (e.g., "gsm8k", "human_eval")
    :created_at         # Timestamp
  ]

  @type t :: %__MODULE__{
    id: binary(),
    content: map() | String.t(),
    version: String.t(),
    metadata: map(),
    asset_urls: [String.t()],
    source: String.t() | nil,
    created_at: DateTime.t() | nil
  }

  # Validation
  def validate(%__MODULE__{} = dto) do
    cond do
      is_nil(dto.id) -> {:error, :missing_id}
      is_nil(dto.content) -> {:error, :missing_content}
      is_nil(dto.version) -> {:error, :missing_version}
      true -> {:ok, dto}
    end
  end
end
```

**Usage in Assignment Dispatch**:

```elixir
defmodule Anvil.Assignments do
  def dispatch_next(queue_id, labeler_id) do
    with {:ok, assignment} <- Policy.select_assignment(queue_id, labeler_id),
         {:ok, sample_dto} <- ForgeBridge.fetch_sample(assignment.sample_id) do

      # Return assignment + sample DTO (no Forge schema dependency)
      {:ok, %{
        assignment: assignment,
        sample: sample_dto
      }}
    end
  end
end
```

### 5. Fault Tolerance and Circuit Breaking

**Circuit Breaker** (when using HTTP backend):

```elixir
defmodule Anvil.ForgeBridge.HTTPClient do
  use Fuse

  @fuse_name {:forge_api, __MODULE__}
  @fuse_opts {{:standard, 5, 10_000}, {:reset, 30_000}}
  # 5 failures in 10s window → open circuit for 30s

  @impl true
  def fetch_sample(sample_id, opts) do
    case Fuse.ask(@fuse_name, :sync) do
      :ok ->
        # Circuit closed, attempt request
        case do_fetch_sample(sample_id, opts) do
          {:ok, _} = result ->
            result

          {:error, _} = error ->
            Fuse.melt(@fuse_name)  # Increment failure count
            error
        end

      :blown ->
        # Circuit open, fail fast
        Logger.warn("Forge API circuit breaker open, using fallback")
        fetch_from_cache_or_fail(sample_id)
    end
  end

  defp fetch_from_cache_or_fail(sample_id) do
    case Cachex.get(:forge_samples, sample_id) do
      {:ok, sample_dto} when not is_nil(sample_dto) ->
        Logger.info("Serving stale cached sample #{sample_id} (Forge unavailable)")
        {:ok, sample_dto}

      _ ->
        {:error, :forge_unavailable}
    end
  end
end
```

**Graceful Degradation**:

```elixir
# When Forge is unavailable, still allow labelers to view cached samples
def dispatch_next(queue_id, labeler_id) do
  case Policy.select_assignment(queue_id, labeler_id) do
    {:ok, assignment} ->
      case ForgeBridge.fetch_sample(assignment.sample_id) do
        {:ok, sample} ->
          {:ok, %{assignment: assignment, sample: sample}}

        {:error, :forge_unavailable} ->
          # Serve stale sample from cache or reject gracefully
          Logger.warn("Forge unavailable, cannot dispatch assignment")
          {:error, :service_degraded}
      end

    {:error, _} = error ->
      error
  end
end
```

### 6. Lineage Tracking Integration

**Export Manifest with Forge Metadata**:

```elixir
defmodule Anvil.Export do
  def to_csv(queue_id, opts) do
    # ... export logic ...

    # Collect Forge sample metadata
    sample_metadata = collect_sample_metadata(labels)

    manifest = %{
      export_id: Ecto.UUID.generate(),
      queue_id: queue_id,
      anvil_schema_version_id: opts[:schema_version_id],
      forge_sample_versions: sample_metadata.versions,  # %{"sample_abc" => "v2024-12-01", ...}
      forge_sample_sources: sample_metadata.sources,    # %{"gsm8k" => 1200, "human_eval" => 300}
      row_count: length(labels),
      exported_at: DateTime.utc_now()
    }

    # Register in AITrace with full lineage
    AITrace.create_artifact(%{
      type: "labeled_dataset",
      name: "anvil_export_#{manifest.export_id}",
      version: "#{manifest.anvil_schema_version_id}_#{hash_sample_versions(manifest.forge_sample_versions)}",
      lineage: %{
        upstream: [
          %{type: "anvil_queue", id: queue_id},
          %{type: "anvil_schema_version", id: manifest.anvil_schema_version_id}
        ] ++ Enum.map(manifest.forge_sample_versions, fn {sample_id, version} ->
          %{type: "forge_sample", id: sample_id, version: version}
        end)
      }
    })

    {:ok, manifest}
  end

  defp collect_sample_metadata(labels) do
    sample_ids = Enum.map(labels, & &1.assignment.sample_id) |> Enum.uniq()

    # Batch fetch sample metadata from Forge
    {:ok, samples} = ForgeBridge.fetch_samples(sample_ids)

    %{
      versions: Map.new(samples, &{&1.id, &1.version}),
      sources: Enum.frequencies_by(samples, & &1.source)
    }
  end
end
```

## Consequences

### Positive

- **Flexibility**: Bridge abstraction supports multiple deployment topologies (shared DB, microservices, hybrid)
- **Performance**: Caching reduces Forge query load; batch fetching amortizes overhead
- **Isolation**: DTO layer prevents tight coupling; Forge and Anvil can evolve independently
- **Fault Tolerance**: Circuit breaker and cache fallback maintain availability during Forge outages
- **Reproducibility**: Sample version pinning ensures exported datasets reference exact sample content
- **Lineage**: Full provenance tracking from Forge samples → Anvil labels → ML training datasets
- **Testability**: Bridge interface enables mocking Forge in Anvil tests

### Negative

- **Complexity**: Multiple backend implementations increase maintenance burden
- **Consistency Trade-offs**: HTTP backend sacrifices transactional consistency for deployment flexibility
- **Caching Overhead**: Cache invalidation logic adds complexity; stale data risk if misconfigured
- **Latency**: HTTP backend adds ~10-50ms per sample fetch vs direct DB access
- **Version Sprawl**: Tracking sample versions per assignment increases storage and export complexity
- **Testing Matrix**: Must test against all backend implementations (DirectDB, HTTP, Cached)

### Neutral

- **Schema Evolution**: If Forge schema changes, only DTO mapping needs updating (not all Anvil code)
- **Multi-Forge**: Bridge abstraction enables fetching samples from multiple Forge instances (if needed)
- **Batch Optimization**: Consider GraphQL or custom batch API for efficient multi-sample fetching
- **Event-Driven Sync**: For separate DBs, consider event-driven sample replication (Forge publishes, Anvil subscribes)

## Implementation Notes

1. **Configuration**:
   ```elixir
   # config/config.exs
   config :anvil,
     forge_bridge_backend: Anvil.ForgeBridge.DirectDB

   # config/prod.exs (for microservices deployment)
   config :anvil,
     forge_bridge_backend: Anvil.ForgeBridge.CachedProxy,
     forge_bridge_primary_backend: Anvil.ForgeBridge.HTTPClient,
     forge_base_url: "https://forge.nsai.example.com",
     forge_api_token: System.fetch_env!("FORGE_API_TOKEN")
   ```

2. **Testing with Mocks**:
   ```elixir
   defmodule Anvil.ForgeBridge.Mock do
     @behaviour Anvil.ForgeBridge

     @impl true
     def fetch_sample(sample_id, _opts) do
       # Return fixture data
       {:ok, %SampleDTO{
         id: sample_id,
         content: "Mock sample content",
         version: "test_v1",
         metadata: %{},
         asset_urls: []
       }}
     end
   end

   # In tests
   # config/test.exs
   config :anvil, forge_bridge_backend: Anvil.ForgeBridge.Mock
   ```

3. **Telemetry Events**:
   ```elixir
   :telemetry.execute([:anvil, :forge_bridge, :fetch_sample, :start], %{}, %{sample_id: id})
   :telemetry.execute([:anvil, :forge_bridge, :fetch_sample, :stop], %{duration: ms}, %{backend: :direct_db})
   :telemetry.execute([:anvil, :forge_bridge, :cache_hit], %{}, %{sample_id: id})
   ```

4. **Performance Targets**:
   - DirectDB fetch: <5ms p99
   - HTTPClient fetch: <50ms p99 (with circuit breaker)
   - Cache hit: <1ms p99
   - Batch fetch (100 samples): <100ms

5. **Database Indexes** (for DirectDB backend):
   ```sql
   -- Forge side (ensure fast lookups)
   CREATE INDEX idx_forge_samples_version ON forge.samples(version_tag);

   -- Anvil side
   CREATE INDEX idx_assignments_sample_id ON anvil.assignments(sample_id);
   CREATE INDEX idx_assignments_sample_version ON anvil.assignments(sample_version);
   ```

6. **API Contract** (for HTTP backend):
   ```
   GET /api/samples/:id
   Response:
   {
     "id": "uuid",
     "content": {...},
     "version_tag": "v2024-12-01",
     "metadata": {...},
     "asset_urls": ["https://s3..."]
   }

   GET /api/samples?ids[]=uuid1&ids[]=uuid2  (batch fetch)
   Response:
   {
     "samples": [...]
   }
   ```

7. **Migration Strategy**:
   - Start with DirectDB backend for NSAI monorepo
   - Add CachedProxy wrapper for performance optimization
   - Implement HTTPClient backend when Forge/Anvil need independent deployment
   - Use feature flags to A/B test backend performance
