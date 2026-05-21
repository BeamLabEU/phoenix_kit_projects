defmodule PhoenixKitProjects.Web.AITranslateFormHelpersTest do
  @moduledoc """
  Unit coverage for the shared helpers extracted from project /
  template / task form LVs. The `merge_blank_fields_only/2` policy
  is load-bearing for the form UX — a translation that lands while
  the user is mid-edit must NOT silently overwrite typed text.
  Pinning that here so a future "Map.merge is simpler" refactor
  trips this test instead of shipping a regression.
  """

  use ExUnit.Case, async: true

  alias PhoenixKitProjects.Web.AITranslateFormHelpers, as: H

  describe "missing_languages/4" do
    test "rejects the primary language" do
      tabs = [%{code: "en"}, %{code: "es"}, %{code: "de"}]
      assert H.missing_languages(tabs, "en", %{}, ["name"]) == ["es", "de"]
    end

    test "rejects languages with at least one non-blank translatable field" do
      tabs = [%{code: "en"}, %{code: "es"}, %{code: "de"}]

      translations = %{
        "es" => %{"name" => "Proyecto"},
        "de" => %{}
      }

      assert H.missing_languages(tabs, "en", translations, ["name", "description"]) == ["de"]
    end

    test "all-blank fields still count as missing" do
      tabs = [%{code: "en"}, %{code: "es"}]
      translations = %{"es" => %{"name" => "", "description" => "   "}}
      assert H.missing_languages(tabs, "en", translations, ["name", "description"]) == ["es"]
    end

    test "nil translations map" do
      tabs = [%{code: "en"}, %{code: "es"}]
      assert H.missing_languages(tabs, "en", nil, ["name"]) == ["es"]
    end

    test "nil language_tabs" do
      assert H.missing_languages(nil, "en", %{}, ["name"]) == []
    end

    test "atom field names against string-keyed translations does NOT match (documented contract)" do
      # `Project.translatable_fields/0` returns `~w(name description)`
      # (strings). The translations JSONB column is string-keyed.
      # Passing atom field names (`[:name]`) would silently miss
      # every value — pin this so a future "let me try atoms"
      # refactor surfaces immediately.
      tabs = [%{code: "en"}, %{code: "es"}]

      assert H.missing_languages(
               tabs,
               "en",
               %{"es" => %{"name" => "Proyecto"}},
               [:name]
             ) == ["es"]
    end
  end

  describe "has_any_translation?/3" do
    test "true when at least one field has a non-blank value" do
      assert H.has_any_translation?(
               %{"es" => %{"name" => "Proyecto", "description" => ""}},
               "es",
               ["name", "description"]
             )
    end

    test "false when language map is empty" do
      refute H.has_any_translation?(%{"es" => %{}}, "es", ["name"])
    end

    test "false when every field value is blank" do
      refute H.has_any_translation?(
               %{"es" => %{"name" => "", "description" => "   "}},
               "es",
               ["name", "description"]
             )
    end

    test "false when lang key missing entirely" do
      refute H.has_any_translation?(%{"de" => %{"name" => "x"}}, "es", ["name"])
    end

    test "false on non-binary field values (e.g. accidentally stored numbers)" do
      refute H.has_any_translation?(%{"es" => %{"name" => 42}}, "es", ["name"])
    end
  end

  describe "merge_blank_fields_only/2 — user-typed values win over AI output" do
    test "fills blank fields with AI values" do
      assert H.merge_blank_fields_only(%{"name" => "", "description" => nil}, %{
               "name" => "Proyecto",
               "description" => "Una descripción"
             }) == %{"name" => "Proyecto", "description" => "Una descripción"}
    end

    test "does NOT overwrite a non-blank user-typed value" do
      # User typed "My Custom Name" into the `es.name` field while
      # the AI job was running. The AI returns "Proyecto" for name.
      # User input wins.
      result =
        H.merge_blank_fields_only(
          %{"name" => "My Custom Name"},
          %{"name" => "Proyecto", "description" => "Generated description"}
        )

      assert result == %{"name" => "My Custom Name", "description" => "Generated description"}
    end

    test "treats whitespace-only current values as blank (still gets the AI value)" do
      assert H.merge_blank_fields_only(%{"name" => "   "}, %{"name" => "Proyecto"}) ==
               %{"name" => "Proyecto"}
    end

    test "preserves current map fields the AI didn't return" do
      # AI only translated `name`; existing description stays put.
      assert H.merge_blank_fields_only(
               %{"name" => "", "description" => "Existing"},
               %{"name" => "Proyecto"}
             ) == %{"name" => "Proyecto", "description" => "Existing"}
    end

    test "non-binary current value (e.g. nil) gets filled" do
      assert H.merge_blank_fields_only(%{"name" => nil}, %{"name" => "x"}) ==
               %{"name" => "x"}
    end

    test "non-string current value other than nil is treated as set (preserved)" do
      # Defensive: if some upstream schema mismatch leaves an integer
      # in the translations map, we don't overwrite — surfaces the
      # bug instead of papering over it with AI output.
      assert H.merge_blank_fields_only(%{"name" => 42}, %{"name" => "x"}) ==
               %{"name" => 42}
    end
  end

  describe "merge_translation_fields/3 — overwrite-aware merge" do
    test "overwrite? false defers to blank-only merge (user edits win)" do
      assert H.merge_translation_fields(
               %{"name" => "My Custom Name"},
               %{"name" => "Proyecto", "description" => "Generada"},
               false
             ) == %{"name" => "My Custom Name", "description" => "Generada"}
    end

    test "overwrite? true lets AI output win over existing non-blank values" do
      # The "all" scope: the user explicitly asked to overwrite, so the
      # form must mirror the worker's persisted Map.merge — otherwise a
      # save would silently revert the just-written translation.
      assert H.merge_translation_fields(
               %{"name" => "Proyecto antiguo", "description" => "Vieja"},
               %{"name" => "Proyecto nuevo"},
               true
             ) == %{"name" => "Proyecto nuevo", "description" => "Vieja"}
    end

    test "overwrite? true still preserves fields the AI didn't return" do
      assert H.merge_translation_fields(
               %{"name" => "Old", "description" => "Keep me"},
               %{"name" => "New"},
               true
             ) == %{"name" => "New", "description" => "Keep me"}
    end

    test "overwrite? false fills blanks (parity with merge_blank_fields_only)" do
      assert H.merge_translation_fields(
               %{"name" => "", "description" => nil},
               %{"name" => "Proyecto", "description" => "Una descripción"},
               false
             ) == %{"name" => "Proyecto", "description" => "Una descripción"}
    end
  end
end
