defmodule Anvil.Schema.Field do
  @moduledoc """
  Represents a field in a label schema.

  Supports various field types with appropriate validation rules.
  """

  @type field_type ::
          :text
          | :select
          | :multiselect
          | :range
          | :number
          | :boolean
          | :date
          | :datetime

  @type t :: %__MODULE__{
          name: String.t(),
          type: field_type(),
          required: boolean(),
          options: [String.t()] | nil,
          min: number() | nil,
          max: number() | nil,
          pattern: Regex.t() | nil,
          default: any(),
          description: String.t() | nil,
          metadata: map()
        }

  defstruct [
    :name,
    :type,
    :required,
    :options,
    :min,
    :max,
    :pattern,
    :default,
    :description,
    metadata: %{}
  ]

  @doc """
  Returns a list of all supported field types.
  """
  @spec types() :: [field_type()]
  def types do
    [:text, :select, :multiselect, :range, :number, :boolean, :date, :datetime]
  end

  @doc """
  Validates a value against this field's constraints.
  """
  @spec validate(t(), any()) :: :ok | {:error, String.t()}
  def validate(%__MODULE__{required: true}, nil) do
    {:error, "is required"}
  end

  def validate(%__MODULE__{required: false}, nil), do: :ok

  def validate(%__MODULE__{type: :text, pattern: pattern}, value) when is_binary(value) do
    if pattern && !Regex.match?(pattern, value) do
      {:error, "does not match required pattern"}
    else
      :ok
    end
  end

  def validate(%__MODULE__{type: :text}, value) when not is_binary(value) do
    {:error, "must be text"}
  end

  def validate(%__MODULE__{type: :select, options: options}, value) when is_binary(value) do
    if value in options do
      :ok
    else
      {:error, "must be one of: #{Enum.join(options, ", ")}"}
    end
  end

  def validate(%__MODULE__{type: :select}, value) when not is_binary(value) do
    {:error, "must be a string"}
  end

  def validate(%__MODULE__{type: :multiselect, options: options}, values)
      when is_list(values) do
    invalid = Enum.reject(values, &(&1 in options))

    if Enum.empty?(invalid) do
      :ok
    else
      {:error, "invalid options: #{Enum.join(invalid, ", ")}"}
    end
  end

  def validate(%__MODULE__{type: :multiselect}, value) when not is_list(value) do
    {:error, "must be a list"}
  end

  def validate(%__MODULE__{type: :range, min: min, max: max}, value)
      when is_integer(value) do
    cond do
      min && value < min -> {:error, "must be at least #{min}"}
      max && value > max -> {:error, "must be at most #{max}"}
      true -> :ok
    end
  end

  def validate(%__MODULE__{type: :range}, value) when not is_integer(value) do
    {:error, "must be an integer"}
  end

  def validate(%__MODULE__{type: :number, min: min, max: max}, value)
      when is_number(value) do
    cond do
      min && value < min -> {:error, "must be at least #{min}"}
      max && value > max -> {:error, "must be at most #{max}"}
      true -> :ok
    end
  end

  def validate(%__MODULE__{type: :number}, value) when not is_number(value) do
    {:error, "must be a number"}
  end

  def validate(%__MODULE__{type: :boolean}, value) when is_boolean(value), do: :ok

  def validate(%__MODULE__{type: :boolean}, _value) do
    {:error, "must be true or false"}
  end

  def validate(%__MODULE__{type: :date}, %Date{}), do: :ok

  def validate(%__MODULE__{type: :date}, value) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, _} -> :ok
      {:error, _} -> {:error, "must be a valid date (YYYY-MM-DD)"}
    end
  end

  def validate(%__MODULE__{type: :date}, _value) do
    {:error, "must be a date"}
  end

  def validate(%__MODULE__{type: :datetime}, %DateTime{}), do: :ok

  def validate(%__MODULE__{type: :datetime}, value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, _, _} -> :ok
      {:error, _} -> {:error, "must be a valid datetime (ISO8601)"}
    end
  end

  def validate(%__MODULE__{type: :datetime}, _value) do
    {:error, "must be a datetime"}
  end
end
