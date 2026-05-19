defmodule PhoenixKitProjects.Schemas.DependencyTest do
  @moduledoc """
  Pure changeset tests for `Schemas.Dependency`. DB-backed coverage
  (cycle detection, cross-project rejection) lives in
  `projects_context_test.exs`.
  """

  use ExUnit.Case, async: true

  alias PhoenixKitProjects.Schemas.Dependency

  describe "changeset/2" do
    test "both fields are required" do
      cs = Dependency.changeset(%Dependency{}, %{})
      refute cs.valid?
      assert {:assignment_uuid, {_, _}} = List.keyfind(cs.errors, :assignment_uuid, 0)
      assert {:depends_on_uuid, {_, _}} = List.keyfind(cs.errors, :depends_on_uuid, 0)
    end

    test "valid when both uuids are present and distinct" do
      cs =
        Dependency.changeset(%Dependency{}, %{
          "assignment_uuid" => UUIDv7.generate(),
          "depends_on_uuid" => UUIDv7.generate()
        })

      assert cs.valid?
    end

    test "rejects self-referencing dependency" do
      uuid = UUIDv7.generate()

      cs =
        Dependency.changeset(%Dependency{}, %{
          "assignment_uuid" => uuid,
          "depends_on_uuid" => uuid
        })

      refute cs.valid?
      assert {:depends_on_uuid, {msg, _}} = List.keyfind(cs.errors, :depends_on_uuid, 0)
      assert msg =~ "itself"
    end

    test "self-reference check needs both fields present" do
      # Only one field set — self-ref guard shouldn't fire; the
      # required-validation should be the failure
      cs =
        Dependency.changeset(%Dependency{}, %{
          "assignment_uuid" => UUIDv7.generate()
        })

      refute cs.valid?

      case List.keyfind(cs.errors, :depends_on_uuid, 0) do
        {:depends_on_uuid, {msg, _}} -> refute msg =~ "itself"
        nil -> :ok
      end
    end
  end
end
