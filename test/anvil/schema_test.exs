defmodule Anvil.SchemaTest do
  use Supertester.ExUnitFoundation, isolation: :full_isolation

  alias Anvil.Schema
  alias Anvil.Schema.Field

  describe "new/1" do
    test "creates a schema with default version" do
      schema = Schema.new(name: "test")
      assert schema.name == "test"
      assert schema.version == "1.0"
      assert schema.fields == []
    end

    test "creates a schema with fields" do
      fields = [
        %Field{name: "category", type: :select, required: true, options: ["a", "b"]}
      ]

      schema = Schema.new(name: "test", fields: fields)
      assert length(schema.fields) == 1
      assert hd(schema.fields).name == "category"
    end
  end

  describe "validate/2" do
    test "validates correct values" do
      schema =
        Schema.new(
          name: "test",
          fields: [
            %Field{name: "category", type: :select, required: true, options: ["a", "b"]},
            %Field{name: "score", type: :range, required: true, min: 1, max: 5}
          ]
        )

      assert {:ok, values} = Schema.validate(schema, %{"category" => "a", "score" => 3})
      assert values == %{"category" => "a", "score" => 3}
    end

    test "returns errors for invalid values" do
      schema =
        Schema.new(
          name: "test",
          fields: [
            %Field{name: "category", type: :select, required: true, options: ["a", "b"]}
          ]
        )

      assert {:error, errors} = Schema.validate(schema, %{"category" => "c"})
      assert length(errors) == 1
      assert hd(errors).field == "category"
    end

    test "returns errors for missing required fields" do
      schema =
        Schema.new(
          name: "test",
          fields: [
            %Field{name: "category", type: :select, required: true, options: ["a", "b"]}
          ]
        )

      assert {:error, errors} = Schema.validate(schema, %{})
      assert length(errors) == 1
      assert hd(errors).field == "category"
      assert hd(errors).error == "is required"
    end

    test "allows missing optional fields" do
      schema =
        Schema.new(
          name: "test",
          fields: [
            %Field{name: "notes", type: :text, required: false}
          ]
        )

      assert {:ok, _} = Schema.validate(schema, %{})
    end
  end

  describe "get_field/2" do
    test "returns field by name" do
      schema =
        Schema.new(
          name: "test",
          fields: [
            %Field{name: "category", type: :select, required: true, options: ["a", "b"]}
          ]
        )

      assert %Field{name: "category"} = Schema.get_field(schema, "category")
    end

    test "returns nil for non-existent field" do
      schema = Schema.new(name: "test", fields: [])
      assert Schema.get_field(schema, "nonexistent") == nil
    end
  end

  describe "required_fields/1" do
    test "returns all required field names" do
      schema =
        Schema.new(
          name: "test",
          fields: [
            %Field{name: "a", type: :text, required: true},
            %Field{name: "b", type: :text, required: false},
            %Field{name: "c", type: :text, required: true}
          ]
        )

      assert Schema.required_fields(schema) == ["a", "c"]
    end
  end

  describe "optional_fields/1" do
    test "returns all optional field names" do
      schema =
        Schema.new(
          name: "test",
          fields: [
            %Field{name: "a", type: :text, required: true},
            %Field{name: "b", type: :text, required: false},
            %Field{name: "c", type: :text, required: false}
          ]
        )

      assert Schema.optional_fields(schema) == ["b", "c"]
    end
  end
end
