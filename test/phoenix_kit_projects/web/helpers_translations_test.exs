defmodule PhoenixKitProjects.Web.HelpersTranslationsTest do
  @moduledoc """
  The merge every multilang form saves through, and the language a nested
  LiveView restores. The forms themselves are in `multilang_forms_test.exs`.
  """
  use ExUnit.Case, async: true

  alias PhoenixKitProjects.L10n
  alias PhoenixKitProjects.Schemas.Project
  alias PhoenixKitProjects.Web.Helpers

  @fields ~w(name description)

  defp merge(attrs, record), do: Helpers.merge_translations_attrs(attrs, record, @fields)

  describe "merge_translations_attrs/3, translations" do
    test "a save that posts none keeps the in-flight map" do
      record = %Project{translations: %{"es-ES" => %{"name" => "Cocina"}}}

      assert merge(%{"name" => "Kitchen"}, record)["translations"] == record.translations
    end

    test "an emptied in-flight map is carried, so a removed override goes" do
      assert merge(%{"name" => "Kitchen"}, %Project{translations: %{}})["translations"] == %{}
    end

    test "a posted value replaces its own field only" do
      record = %Project{
        translations: %{
          "es-ES" => %{"name" => "Vieja", "description" => "Palabras"},
          "et" => %{"name" => "Kook"}
        }
      }

      attrs = %{"translations" => %{"es-ES" => %{"name" => "Nueva"}}}

      assert merge(attrs, record)["translations"] == %{
               "es-ES" => %{"name" => "Nueva", "description" => "Palabras"},
               "et" => %{"name" => "Kook"}
             }
    end

    test "a blank value removes its override, and an emptied language goes" do
      record = %Project{
        translations: %{"es-ES" => %{"name" => "Cocina"}, "et" => %{"name" => "Kook"}}
      }

      attrs = %{"translations" => %{"es-ES" => %{"name" => ""}, "et" => %{"name" => nil}}}

      assert merge(attrs, record)["translations"] == %{}
    end

    test "LiveView's `_unused_` keys and a malformed language are ignored" do
      record = %Project{translations: %{"es-ES" => %{"name" => "Cocina"}}}

      attrs = %{
        "translations" => %{
          "es-ES" => %{"_unused_name" => "", "name" => "Cocina"},
          "et" => "not a map"
        }
      }

      assert merge(attrs, record)["translations"] == %{"es-ES" => %{"name" => "Cocina"}}
    end
  end

  describe "merge_translations_attrs/3, primary fields" do
    test "a field this tab did not render keeps the in-flight value" do
      merged = merge(%{}, %Project{name: "Kitchen", description: "Words"})

      assert %{"name" => "Kitchen", "description" => "Words"} = merged
    end

    test "a field cleared in flight is carried as nil" do
      assert %{"description" => nil} = merge(%{}, %Project{name: "Kitchen", description: nil})
    end

    test "a posted field wins" do
      assert merge(%{"name" => "New"}, %Project{name: "Old"})["name"] == "New"
    end
  end

  describe "maybe_put_locale/1" do
    test "gives a dialect's base to the catalogues and keeps it for the content" do
      Helpers.maybe_put_locale(%{"locale" => "es-ES"})

      assert Gettext.get_locale(PhoenixKitWeb.Gettext) == "es"
      assert Gettext.get_locale(PhoenixKitProjects.Gettext) == "es"
      assert L10n.current_content_lang() == "es-ES"
    end

    test "takes a base code as it is" do
      Helpers.maybe_put_locale(%{"locale" => "et"})

      assert Gettext.get_locale(PhoenixKitWeb.Gettext) == "et"
      assert L10n.current_content_lang() == "et"
    end

    test "leaves a process that already has a language alone" do
      Gettext.put_locale(PhoenixKitWeb.Gettext, "et")

      assert Helpers.maybe_put_locale(%{"locale" => "es-ES"}) == nil
      assert L10n.current_content_lang() == "et"
    end

    test "ignores an absent and a blank locale" do
      assert Helpers.maybe_put_locale(%{}) == nil
      assert Helpers.maybe_put_locale(%{"locale" => ""}) == nil
      assert Process.get(PhoenixKitWeb.Gettext) == nil
    end
  end
end
