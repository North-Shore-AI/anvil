defmodule Anvil.Schema.FieldTest do
  use Supertester.ExUnitFoundation, isolation: :full_isolation

  alias Anvil.Schema.Field

  describe "types/0" do
    test "returns all supported field types" do
      types = Field.types()
      assert :text in types
      assert :select in types
      assert :multiselect in types
      assert :range in types
      assert :number in types
      assert :boolean in types
      assert :date in types
      assert :datetime in types
    end
  end

  describe "validate/2 - text fields" do
    test "validates text values" do
      field = %Field{name: "notes", type: :text, required: true}
      assert :ok = Field.validate(field, "some text")
    end

    test "validates text with pattern" do
      field = %Field{name: "email", type: :text, required: true, pattern: ~r/@/}
      assert :ok = Field.validate(field, "user@example.com")
      assert {:error, _} = Field.validate(field, "invalid")
    end

    test "rejects non-text values" do
      field = %Field{name: "notes", type: :text, required: true}
      assert {:error, _} = Field.validate(field, 123)
    end
  end

  describe "validate/2 - select fields" do
    test "validates values in options" do
      field = %Field{name: "category", type: :select, required: true, options: ["a", "b", "c"]}
      assert :ok = Field.validate(field, "a")
      assert :ok = Field.validate(field, "c")
    end

    test "rejects values not in options" do
      field = %Field{name: "category", type: :select, required: true, options: ["a", "b"]}
      assert {:error, msg} = Field.validate(field, "c")
      assert msg =~ "must be one of"
    end
  end

  describe "validate/2 - multiselect fields" do
    test "validates list of values in options" do
      field = %Field{
        name: "tags",
        type: :multiselect,
        required: true,
        options: ["tag1", "tag2", "tag3"]
      }

      assert :ok = Field.validate(field, ["tag1", "tag2"])
      assert :ok = Field.validate(field, ["tag3"])
    end

    test "rejects invalid values" do
      field = %Field{
        name: "tags",
        type: :multiselect,
        required: true,
        options: ["tag1", "tag2"]
      }

      assert {:error, _} = Field.validate(field, ["tag1", "invalid"])
    end

    test "rejects non-list values" do
      field = %Field{name: "tags", type: :multiselect, required: true, options: ["a"]}
      assert {:error, _} = Field.validate(field, "not a list")
    end
  end

  describe "validate/2 - range fields" do
    test "validates integers within range" do
      field = %Field{name: "score", type: :range, required: true, min: 1, max: 5}
      assert :ok = Field.validate(field, 1)
      assert :ok = Field.validate(field, 3)
      assert :ok = Field.validate(field, 5)
    end

    test "rejects values outside range" do
      field = %Field{name: "score", type: :range, required: true, min: 1, max: 5}
      assert {:error, msg} = Field.validate(field, 0)
      assert msg =~ "at least 1"
      assert {:error, msg} = Field.validate(field, 6)
      assert msg =~ "at most 5"
    end

    test "rejects non-integer values" do
      field = %Field{name: "score", type: :range, required: true, min: 1, max: 5}
      assert {:error, _} = Field.validate(field, 3.5)
    end
  end

  describe "validate/2 - number fields" do
    test "validates numbers within range" do
      field = %Field{name: "value", type: :number, required: true, min: 0.0, max: 1.0}
      assert :ok = Field.validate(field, 0.5)
      assert :ok = Field.validate(field, 1)
      assert :ok = Field.validate(field, 0.0)
    end

    test "rejects values outside range" do
      field = %Field{name: "value", type: :number, required: true, min: 0.0, max: 1.0}
      assert {:error, _} = Field.validate(field, -0.1)
      assert {:error, _} = Field.validate(field, 1.1)
    end
  end

  describe "validate/2 - boolean fields" do
    test "validates boolean values" do
      field = %Field{name: "confirmed", type: :boolean, required: true}
      assert :ok = Field.validate(field, true)
      assert :ok = Field.validate(field, false)
    end

    test "rejects non-boolean values" do
      field = %Field{name: "confirmed", type: :boolean, required: true}
      assert {:error, _} = Field.validate(field, "true")
      assert {:error, _} = Field.validate(field, 1)
    end
  end

  describe "validate/2 - date fields" do
    test "validates Date structs" do
      field = %Field{name: "birthday", type: :date, required: true}
      assert :ok = Field.validate(field, ~D[2024-01-15])
    end

    test "validates ISO8601 date strings" do
      field = %Field{name: "birthday", type: :date, required: true}
      assert :ok = Field.validate(field, "2024-01-15")
    end

    test "rejects invalid date strings" do
      field = %Field{name: "birthday", type: :date, required: true}
      assert {:error, _} = Field.validate(field, "not a date")
    end
  end

  describe "validate/2 - datetime fields" do
    test "validates DateTime structs" do
      field = %Field{name: "timestamp", type: :datetime, required: true}
      assert :ok = Field.validate(field, ~U[2024-01-15 10:30:00Z])
    end

    test "validates ISO8601 datetime strings" do
      field = %Field{name: "timestamp", type: :datetime, required: true}
      assert :ok = Field.validate(field, "2024-01-15T10:30:00Z")
    end

    test "rejects invalid datetime strings" do
      field = %Field{name: "timestamp", type: :datetime, required: true}
      assert {:error, _} = Field.validate(field, "not a datetime")
    end
  end

  describe "validate/2 - required field handling" do
    test "rejects nil for required fields" do
      field = %Field{name: "required_field", type: :text, required: true}
      assert {:error, "is required"} = Field.validate(field, nil)
    end

    test "allows nil for optional fields" do
      field = %Field{name: "optional_field", type: :text, required: false}
      assert :ok = Field.validate(field, nil)
    end
  end
end
