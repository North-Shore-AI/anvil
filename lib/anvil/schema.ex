defmodule Anvil.Schema do
  @moduledoc """
  Defines the structure and validation rules for labels.

  Schemas are domain-agnostic and support various field types for
  diverse annotation tasks.
  """

  alias Anvil.Schema.Field

  @type t :: %__MODULE__{
          name: String.t(),
          version: String.t(),
          fields: [Field.t()],
          metadata: map()
        }

  defstruct [
    :name,
    version: "1.0",
    fields: [],
    metadata: %{}
  ]

  @doc """
  Creates a new schema with the given options.

  ## Examples

      iex> schema = Anvil.Schema.new(
      ...>   name: "sentiment",
      ...>   fields: [
      ...>     %Anvil.Schema.Field{
      ...>       name: "score",
      ...>       type: :range,
      ...>       required: true,
      ...>       min: 1,
      ...>       max: 5
      ...>     }
      ...>   ]
      ...> )
      iex> schema.name
      "sentiment"
  """
  @spec new(keyword()) :: t()
  def new(opts) do
    struct(__MODULE__, opts)
  end

  @doc """
  Validates a map of values against the schema.

  Returns `{:ok, values}` if valid, or `{:error, errors}` with a list
  of validation errors.

  ## Examples

      iex> schema = Anvil.Schema.new(
      ...>   name: "test",
      ...>   fields: [
      ...>     %Anvil.Schema.Field{name: "category", type: :select, required: true, options: ["a", "b"]}
      ...>   ]
      ...> )
      iex> Anvil.Schema.validate(schema, %{"category" => "a"})
      {:ok, %{"category" => "a"}}
      iex> Anvil.Schema.validate(schema, %{"category" => "c"})
      {:error, [%{field: "category", error: "must be one of: a, b"}]}
  """
  @spec validate(t(), map()) :: {:ok, map()} | {:error, [map()]}
  def validate(%__MODULE__{fields: fields}, values) do
    errors =
      fields
      |> Enum.map(fn field ->
        value = Map.get(values, field.name)

        case Field.validate(field, value) do
          :ok -> nil
          {:error, message} -> %{field: field.name, error: message}
        end
      end)
      |> Enum.reject(&is_nil/1)

    if Enum.empty?(errors) do
      {:ok, values}
    else
      {:error, errors}
    end
  end

  @doc """
  Returns the field with the given name, or nil if not found.
  """
  @spec get_field(t(), String.t()) :: Field.t() | nil
  def get_field(%__MODULE__{fields: fields}, name) do
    Enum.find(fields, &(&1.name == name))
  end

  @doc """
  Returns all required field names.
  """
  @spec required_fields(t()) :: [String.t()]
  def required_fields(%__MODULE__{fields: fields}) do
    fields
    |> Enum.filter(& &1.required)
    |> Enum.map(& &1.name)
  end

  @doc """
  Returns all optional field names.
  """
  @spec optional_fields(t()) :: [String.t()]
  def optional_fields(%__MODULE__{fields: fields}) do
    fields
    |> Enum.reject(& &1.required)
    |> Enum.map(& &1.name)
  end
end
