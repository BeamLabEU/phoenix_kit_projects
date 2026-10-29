defmodule PhoenixKitProjects.GettextCatalogueTest do
  @moduledoc """
  The translation catalogues against `default.pot` and against how Gettext
  reads them.

  A plural entry with SOME of its forms empty is untranslated as a whole:
  Gettext falls back to the English msgid for every count, the filled form
  included. `"+%{count} more"` shipped that way in five locales when the Time
  page turned it into a plural (so the Overview's "+N more" went English too).
  An empty-msgstr count cannot tell such an entry from a deliberately
  untranslated one, so this checks the shape directly.
  """

  use ExUnit.Case, async: true

  alias Expo.Message.Plural
  alias Expo.Message.Singular

  @gettext_dir Path.expand("../../priv/gettext", __DIR__)
  @locales ~w(de es et fr it pl ru)
  # Translated in full: every msgid has a translation.
  @complete_locales ~w(et ru)

  defp messages(path), do: Expo.PO.parse_file!(path).messages

  defp po(locale), do: Path.join([@gettext_dir, locale, "LC_MESSAGES", "default.po"])

  defp id(%{msgid: msgid}), do: IO.iodata_to_binary(msgid)

  defp forms(%Plural{msgstr: msgstr}),
    do: msgstr |> Map.values() |> Enum.map(&IO.iodata_to_binary/1)

  defp forms(%Singular{msgstr: msgstr}), do: [IO.iodata_to_binary(msgstr)]

  test "every locale carries every msgid of default.pot" do
    pot = @gettext_dir |> Path.join("default.pot") |> messages() |> MapSet.new(&id/1)

    for locale <- @locales do
      ids = locale |> po() |> messages() |> MapSet.new(&id/1)
      assert MapSet.difference(pot, ids) |> MapSet.to_list() == [], "#{locale} lacks msgids"
    end
  end

  test "no plural entry is half translated" do
    for locale <- @locales do
      partial =
        for %Plural{} = m <- messages(po(locale)),
            filled = Enum.count(forms(m), &(&1 != "")),
            filled > 0 and filled < length(forms(m)),
            do: id(m)

      assert partial == [], "#{locale}: partly filled plural forms #{inspect(partial)}"
    end
  end

  test "the complete locales have no empty translation" do
    for locale <- @complete_locales do
      empty = for m <- messages(po(locale)), "" in forms(m), do: id(m)
      assert empty == [], "#{locale}: empty msgstr #{inspect(empty)}"
    end
  end

  test "\"+N more\" is translated in every locale, as a plural and as a plain gettext" do
    for locale <- @locales do
      Gettext.with_locale(PhoenixKitProjects.Gettext, locale, fn ->
        plural =
          Gettext.dngettext(
            PhoenixKitProjects.Gettext,
            "default",
            "+%{count} more",
            "+%{count} more",
            3
          )

        single =
          Gettext.dgettext(PhoenixKitProjects.Gettext, "default", "+%{count} more", count: 3)

        refute plural == "+3 more", "#{locale}: plural renders English"
        refute single == "+3 more", "#{locale}: singular lookup renders English"
      end)
    end
  end
end
