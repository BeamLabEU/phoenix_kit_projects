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
  alias PhoenixKitProjects.Web.Helpers, as: WebHelpers

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

  # ── Code against catalogue ───────────────────────────────────────

  @lib Path.expand("../../lib", __DIR__)

  # A literal argument of a gettext-family call: `gettext("…")`,
  # `pgettext("ctx", "…")`, `ngettext("…", "…", n)`, `gettext_noop("…")`
  # and the `*_with_backend` forms this module's own backend is named in.
  @str ~S{"((?:[^"\\]|\\.)*)"}
  @call_re Regex.compile!(
             "\\b(?:gettext|gettext_noop|ngettext|dgettext)\\(\\s*" <> @str,
             "s"
           )
  @pcall_re Regex.compile!(
              "\\b(?:pgettext|pngettext|pgettext_noop)\\(\\s*" <> @str <> "\\s*,\\s*" <> @str,
              "s"
            )
  @backend_re Regex.compile!(
                "\\b(?:gettext|ngettext)_with_backend\\(\\s*PhoenixKitProjects\\.Gettext\\s*,\\s*" <>
                  @str,
                "s"
              )
  @pbackend_re Regex.compile!(
                 "\\bpn?gettext_with_backend\\(\\s*PhoenixKitProjects\\.Gettext\\s*,\\s*" <>
                   @str <> "\\s*,\\s*" <> @str,
                 "s"
               )

  defp unescape(s), do: s |> String.replace("\\\"", "\"") |> String.replace("\\\\", "\\")

  # `{msgctxt, msgid}` of every literal gettext call in `lib/` that goes to
  # THIS backend (l10n.ex's plain calls go to core's and are skipped).
  defp code_msgids do
    for file <- Path.wildcard(Path.join(@lib, "**/*.ex")),
        src = File.read!(file),
        core_backend? = String.contains?(src, "use Gettext, backend: PhoenixKitWeb.Gettext"),
        id <- msgids_in(src, core_backend?),
        into: MapSet.new(),
        do: id
  end

  defp msgids_in(src, core_backend?) do
    plain =
      if core_backend?,
        do: [],
        else:
          for([_, id] <- Regex.scan(@call_re, src), do: {nil, unescape(id)}) ++
            for([_, ctx, id] <- Regex.scan(@pcall_re, src), do: {unescape(ctx), unescape(id)})

    plain ++
      for([_, id] <- Regex.scan(@backend_re, src), do: {nil, unescape(id)}) ++
      for [_, ctx, id] <- Regex.scan(@pbackend_re, src), do: {unescape(ctx), unescape(id)}
  end

  defp pot_ids do
    @gettext_dir
    |> Path.join("default.pot")
    |> messages()
    |> MapSet.new(fn m -> {m.msgctxt && IO.iodata_to_binary(m.msgctxt), id(m)} end)
  end

  test "every gettext literal in lib/ is a msgid of default.pot (run extract + merge)" do
    missing = code_msgids() |> MapSet.difference(pot_ids()) |> Enum.sort()
    assert missing == [], "not in default.pot: #{inspect(missing)}"
  end

  # Labels declared as DATA — maps the gettext macros never see — reach a
  # catalogue only through `gettext_noop/1` or `Web.GettextManifest`. The
  # contributed Hours tab rendered English in every locale because the
  # strip drew `tab.label` raw; this pins both halves: each declared label
  # is a msgid, and it has a translation in the complete locales.
  defp declared_labels do
    exts = PhoenixKitProjects.phoenix_kit_project_extensions()
    perms = PhoenixKitProjects.permission_metadata()

    ext_labels =
      Enum.flat_map(exts, fn ext ->
        [ext[:name], ext[:description]] ++
          Enum.map(ext[:flags] || [], & &1.label) ++ Enum.map(ext[:tabs] || [], & &1.label)
      end)

    tab_labels =
      Enum.map(
        PhoenixKitProjects.admin_tabs() ++
          PhoenixKitProjects.settings_tabs() ++ PhoenixKitProjects.user_dashboard_tabs(),
        & &1.label
      )

    perm_labels =
      [perms.label, perms.description] ++
        Enum.flat_map(perms.sub_permissions, &[&1.label, &1.description])

    presets = Enum.flat_map(PhoenixKitProjects.Features.presets(), &[&1.name, &1.description])
    blocks = Enum.map(PhoenixKitProjects.Features.creation_blocks(), & &1.label)
    categories = Enum.map(PhoenixKitProjects.Extensions.Registry.categories(), &elem(&1, 1))

    (ext_labels ++ tab_labels ++ perm_labels ++ presets ++ blocks ++ categories)
    |> Enum.filter(&is_binary/1)
    |> Enum.uniq()
  end

  test "every label declared as data is a msgid of default.pot" do
    ids = MapSet.new(pot_ids(), &elem(&1, 1))
    missing = Enum.reject(declared_labels(), &MapSet.member?(ids, &1))
    assert missing == [], "declared but in no catalogue: #{inspect(missing)}"
  end

  test "every label declared as data renders translated in the complete locales" do
    for locale <- @complete_locales do
      Gettext.with_locale(PhoenixKitProjects.Gettext, locale, fn ->
        untranslated =
          Enum.filter(declared_labels(), fn label ->
            WebHelpers.translate_catalog(label) == label and
              not same_in_translation?(locale, label)
          end)

        assert untranslated == [], "#{locale}: #{inspect(untranslated)}"
      end)
    end
  end

  # A msgstr that is deliberately the msgid ("API", "Gantt") is translated.
  defp same_in_translation?(locale, label) do
    locale |> po() |> messages() |> Enum.any?(&(id(&1) == label and forms(&1) == [label]))
  end

  # The status vocabulary the owner agreed (boss's list, item 1): ONE name
  # per status wherever it is shown, and each step into it phrased on the
  # status's own root. A catalogue edit that drifts from it fails here.
  # ru "В ожидании" (panel review 2026-10-31): a bare "Ожидает" has no
  # subject as a column or a filter; the phrase is the one "Оставить в
  # ожидании" already uses and needs no gender.
  alias PhoenixKitProjects.Web.Components.AssignmentStatusBadge, as: Words

  @vocabulary %{
    "ru" => {
      ["В ожидании", "Можно начинать", "В работе", "Выполнена"],
      ["Разрешить начать", "Взять в работу", "Отметить выполненной", "Открыть заново"]
    },
    "et" => {
      ["Ootel", "Saab alustada", "Töös", "Tehtud"],
      ["Luba alustada", "Võta töösse", "Märgi tehtuks", "Ava uuesti"]
    }
  }

  test "task statuses and their steps use the agreed words" do
    for {locale, {statuses, actions}} <- @vocabulary do
      Gettext.with_locale(PhoenixKitProjects.Gettext, locale, fn ->
        assert Enum.map(~w(waiting todo in_progress done), &Words.label/1) == statuses

        assert Enum.map([:allow_start, :start, :mark_done, :reopen], &Words.action_label/1) ==
                 actions
      end)
    end

    Gettext.with_locale(PhoenixKitProjects.Gettext, "ru", fn ->
      assert Words.label("done", true) == "Выполнен"
      assert Words.action_label(:mark_done, true) == "Отметить выполненным"
      assert Words.on_hold_label(false) == "Приостановлена"
      assert Words.on_hold_label(true) == "Приостановлен"
    end)
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
