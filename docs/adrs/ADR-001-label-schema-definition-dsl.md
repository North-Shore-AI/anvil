# ADR-001: LabelSchema Definition DSL

## Status

Accepted

## Context

Anvil needs a flexible, domain-agnostic way to define label structures for diverse annotation tasks. Different use cases require different field types (text, select, range, etc.) and validation rules. We need a DSL that is:

1. Simple and intuitive for common cases
2. Extensible for complex validation requirements
3. Serializable for storage and transmission
4. Type-safe at runtime

## Decision

We will implement a struct-based DSL for defining label schemas with the following components:

### Schema Structure

```elixir
defmodule Anvil.Schema do
  defstruct [
    :name,
    :version,
    :fields,
    :metadata
  ]
end

defmodule Anvil.Schema.Field do
  defstruct [
    :name,
    :type,
    :required,
    :options,      # for select/multiselect
    :min,          # for range/number
    :max,          # for range/number
    :pattern,      # for text validation
    :default,
    :description,
    :metadata
  ]
end
```

### Supported Field Types

- `:text` - Free-form text input
- `:select` - Single choice from options
- `:multiselect` - Multiple choices from options
- `:range` - Integer within min/max bounds
- `:number` - Floating point number
- `:boolean` - True/false
- `:date` - Date only
- `:datetime` - Date and time

### API

```elixir
# Creating a schema
schema = Anvil.Schema.new(
  name: "image_classification",
  fields: [
    %Anvil.Schema.Field{
      name: "category",
      type: :select,
      required: true,
      options: ["cat", "dog", "bird"]
    }
  ]
)

# Validating values against a schema
Anvil.Schema.validate(schema, %{"category" => "cat"})
# => {:ok, %{"category" => "cat"}}

Anvil.Schema.validate(schema, %{"category" => "fish"})
# => {:error, [%{field: "category", error: "must be one of: cat, dog, bird"}]}
```

## Consequences

### Positive

- **Type Safety**: Validation happens at runtime with clear error messages
- **Flexibility**: Supports wide range of annotation tasks without modification
- **Serializable**: Can be stored as JSON/database records
- **Composable**: Fields can be reused across schemas
- **Versioned**: Schema versioning enables evolution without breaking changes

### Negative

- **No Compile-Time Checks**: Validation is runtime-only
- **Limited Complexity**: Very complex validation logic may require custom validators
- **Performance**: Validation has runtime overhead (mitigated by caching)

### Mitigation

- Provide comprehensive test coverage for validation logic
- Add benchmarks to ensure validation performance is acceptable
- Document extension points for custom validators
- Consider adding a macro-based DSL in future versions for compile-time checks

## Alternatives Considered

### 1. Ecto Schemas

**Rejected** because:
- Too tightly coupled to database layer
- Requires compile-time schema definition
- Not suitable for user-defined schemas at runtime

### 2. JSON Schema

**Rejected** because:
- Less idiomatic for Elixir
- Harder to extend with custom validation
- More verbose for simple cases

### 3. Protocol-Based Validation

**Rejected** because:
- Higher complexity for users
- Harder to serialize
- More boilerplate for common cases

## References

- [JSON Schema Specification](https://json-schema.org/)
- [Ecto Changeset Validation](https://hexdocs.pm/ecto/Ecto.Changeset.html)
- [Domain-Driven Design: Value Objects](https://martinfowler.com/bliki/ValueObject.html)
