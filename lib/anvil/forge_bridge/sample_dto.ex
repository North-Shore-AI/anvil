defmodule Anvil.ForgeBridge.SampleDTO do
  @moduledoc """
  Data Transfer Object for samples fetched from Forge.

  Isolates Anvil from Forge's internal schema details, allowing independent
  evolution of both systems.

  ## Fields

  - `id` - Sample UUID
  - `content` - Primary sample content (text, JSON, etc.)
  - `version` - Version tag from Forge (e.g., "v2024-12-01" or content hash)
  - `metadata` - Optional metadata map
  - `asset_urls` - Pre-signed URLs for media assets
  - `source` - Source system identifier (e.g., "gsm8k", "human_eval")
  - `created_at` - Sample creation timestamp

  ## Example

      %SampleDTO{
        id: "550e8400-e29b-41d4-a716-446655440000",
        content: %{"text" => "What is 2+2?", "answer" => "4"},
        version: "v2024-12-01-abc123",
        metadata: %{"difficulty" => "easy"},
        asset_urls: [],
        source: "gsm8k",
        created_at: ~U[2024-12-01 10:00:00Z]
      }
  """

  @enforce_keys [:id, :content, :version]
  defstruct [
    :id,
    :content,
    :version,
    :metadata,
    :asset_urls,
    :source,
    :created_at
  ]

  @type t :: %__MODULE__{
          id: binary(),
          content: map() | String.t(),
          version: String.t(),
          metadata: map() | nil,
          asset_urls: [String.t()] | nil,
          source: String.t() | nil,
          created_at: DateTime.t() | nil
        }

  @doc """
  Validates a SampleDTO struct.

  Returns `{:ok, dto}` if valid, `{:error, reason}` otherwise.

  ## Examples

      iex> dto = %SampleDTO{id: "abc", content: "test", version: "v1"}
      iex> SampleDTO.validate(dto)
      {:ok, %SampleDTO{}}

      iex> invalid = %SampleDTO{id: nil, content: "test", version: "v1"}
      iex> SampleDTO.validate(invalid)
      {:error, :missing_id}
  """
  @spec validate(t()) :: {:ok, t()} | {:error, atom()}
  def validate(%__MODULE__{} = dto) do
    cond do
      is_nil(dto.id) or dto.id == "" ->
        {:error, :missing_id}

      is_nil(dto.content) ->
        {:error, :missing_content}

      is_nil(dto.version) or dto.version == "" ->
        {:error, :missing_version}

      true ->
        {:ok, dto}
    end
  end

  @doc """
  Creates a SampleDTO from a map with atom or string keys.

  ## Examples

      iex> SampleDTO.from_map(%{
      ...>   "id" => "abc",
      ...>   "content" => "test",
      ...>   "version" => "v1"
      ...> })
      {:ok, %SampleDTO{id: "abc", content: "test", version: "v1"}}

      iex> SampleDTO.from_map(%{id: "missing content"})
      {:error, :invalid_dto}
  """
  @spec from_map(map()) :: {:ok, t()} | {:error, atom()}
  def from_map(map) when is_map(map) do
    dto = %__MODULE__{
      id: map[:id] || map["id"],
      content: map[:content] || map["content"],
      version: map[:version] || map["version"] || map[:version_tag] || map["version_tag"],
      metadata: map[:metadata] || map["metadata"],
      asset_urls: map[:asset_urls] || map["asset_urls"] || [],
      source: map[:source] || map["source"],
      created_at: map[:created_at] || map["created_at"]
    }

    validate(dto)
  rescue
    _ -> {:error, :invalid_dto}
  end
end
