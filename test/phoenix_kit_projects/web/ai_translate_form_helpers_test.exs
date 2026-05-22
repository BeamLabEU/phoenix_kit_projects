defmodule PhoenixKitProjects.Web.AITranslateFormHelpersTest do
  @moduledoc """
  Unit coverage for the shared helpers extracted from project /
  template / task form LVs (missing-language detection +
  has-any-translation discriminator).

  Merge policy moved out of this helper module — the form LVs now
  use plain `Map.merge/2` directly because the UI is locked while
  any translation is in flight, removing the user-typed-during-job
  race that the old `merge_blank_fields_only/2` policy was meant
  to mitigate.
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
end
