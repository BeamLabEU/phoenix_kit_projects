defmodule PhoenixKitProjects.Web.CSPInlineTagsTest do
  @moduledoc """
  The module works under a host's nonce Content-Security-Policy: every inline
  `<script>` / `<style>` it renders carries the nonce
  (`PhoenixKitProjects.Web.CSP`), it renders no inline event handler (no nonce
  covers an attribute), and every `<style>` its JS creates is stamped before
  it joins the document. Modelled on core's `csp_inline_tags_test.exs`.
  """
  use ExUnit.Case, async: true

  alias PhoenixKitProjects.Web.CSP

  @bundles ~w(phoenix_kit_projects.js phoenix_kit_projects_drafts.js)
  @doc_heredoc ~r/@(?:moduledoc|doc|typedoc)\s+(?:~[sS])?"""\n.*?\n\s*"""/s

  # No deliberate exemptions: the module renders no e-mail body and no cached
  # document. A file that only handles such tags as text would be listed here
  # with the reason.
  @exempt []

  @tag_opening ~r/<(script|style)\b[^>]*>/s

  test "no inline <script> or <style> in lib/ is written without a nonce" do
    offenders =
      for path <- Path.wildcard("lib/**/*.{ex,heex}"),
          path not in @exempt,
          {opening, number} <- tag_openings(path),
          not String.contains?(opening, "src="),
          not (opening =~ "CSP.nonce(" or opening =~ "CSP.attr("),
          do: "#{path}:#{number}"

    assert offenders == [],
           "inline tags without `nonce={PhoenixKitProjects.Web.CSP.nonce(kind)}`:\n" <>
             Enum.join(offenders, "\n")
  end

  test "the scan sees the tags the module renders, in HEEx and in a string" do
    assert Enum.any?(
             tag_openings("lib/phoenix_kit_projects/web/components/viz_palette.ex"),
             fn {opening, _} -> opening =~ "<style" and opening =~ "CSP.nonce(:style)" end
           )

    assert Enum.any?(
             tag_openings("lib/phoenix_kit_projects/calendar_display.ex"),
             fn {opening, _} -> opening =~ "<style" and opening =~ "CSP.attr(:style)" end
           )
  end

  # `nonce={…}` is HEEx. In a plain string it is rendered as written.
  test "a `nonce={…}` attribute in an .ex file sits inside a ~H template" do
    offenders =
      for path <- Path.wildcard("lib/**/*.ex"),
          lines = path |> File.read!() |> code_lines(),
          {line, number} <- lines,
          line =~ "nonce={PhoenixKitProjects.Web.CSP",
          not in_heex?(lines, number),
          do: "#{path}:#{number}"

    assert offenders == [],
           "write `<style\#{PhoenixKitProjects.Web.CSP.attr(:style)}>` in a plain string:\n" <>
             Enum.join(offenders, "\n")
  end

  @events ~w(click dblclick change input submit reset invalid select focus blur focusin focusout
             keydown keyup keypress load error scroll wheel resize toggle contextmenu copy cut
             paste drop) ++
            ~w(mousedown mouseup mouseover mouseout mousemove mouseenter mouseleave) ++
            ~w(touchstart touchend touchmove pointerdown pointerup pointermove) ++
            ~w(dragstart dragend dragover dragenter dragleave animationend transitionend)
  @handler Regex.compile!("\\son[a-z]+=[\"'{]|\\son(?:#{Enum.join(@events, "|")})\\s*=\\s*[\"'{]")
  @js_url ~r/\b(?:href|src|action|formaction)\s*=\s*["'{]\s*["']?\s*javascript:/i

  test "no markup in lib/ carries an inline event handler" do
    offenders =
      for path <- Path.wildcard("lib/**/*.{ex,heex}"),
          {line, number} <- path |> File.read!() |> code_lines(),
          not (line =~ ~r/^\s*(#|iex>|\.\.\.>)/),
          line =~ @handler or line =~ @js_url,
          do: "#{path}:#{number}"

    assert offenders == [],
           "inline handlers (no nonce covers them; use a `phx-` binding, a hook, or a " <>
             "`data-pkp-*` attribute handled in phoenix_kit_projects.js):\n" <>
             Enum.join(offenders, "\n")
  end

  test "the handler pattern catches what it is for" do
    assert ~S|<button onclick="window.print()">| =~ @handler
    assert ~s(<img onerror={@x}>) =~ @handler
    assert ~S|<a href="javascript:void(0)">| =~ @js_url
    refute ~s(<button phx-click="go" data-pkp-print>) =~ @handler
  end

  test "the JS builds no markup with an inline event handler" do
    offenders =
      for file <- @bundles,
          {line, number} <- bundle_lines(file),
          not (line =~ ~r{^\s*(//|\*|/\*)}),
          line =~ ~r/\son[a-z]+=\\?["']/ or line =~ ~r/["'`]\s*javascript:/i,
          do: "#{file}:#{number}"

    assert offenders == [], Enum.join(offenders, "\n")
  end

  test "every <style>/<script> the JS creates is stamped, and none is written as a string" do
    offenders =
      for file <- @bundles,
          {line, number} <- bundle_lines(file),
          not (line =~ ~r{^\s*(//|\*|/\*)}),
          problem = element_problem(line),
          do: "#{file}:#{number} #{problem}"

    assert offenders == [], Enum.join(offenders, "\n")
  end

  defp element_problem(line) do
    cond do
      line =~ ~r/createElement\(["']style["']\)/ and
          not (line =~ ~r/adoptStyle\(document\.createElement\(["']style["']\)\)/) ->
        "creates a <style> without `adoptStyle(…)`"

      line =~ ~r/createElement\(["']script["']\)/ ->
        "creates a <script>"

      line =~ ~r/["'`]<(style|script)\b/ ->
        "builds a <style>/<script> tag as a string"

      true ->
        nil
    end
  end

  describe "PhoenixKitProjects.Web.CSP" do
    # Whatever core is installed (the published one has no `PhoenixKitWeb.CSP`),
    # a page with no nonce renders as it always did.
    test "with no nonce on the page: no attribute, the session untouched" do
      assert CSP.nonce(:style) == nil
      assert CSP.nonce(:script) == nil
      assert CSP.attr(:style) == ""
      assert CSP.nested_session(%{"id" => "x"}) == %{"id" => "x"}
      assert CSP.on_mount(:default, %{}, %{}, :socket) == {:cont, :socket}

      assert String.starts_with?(PhoenixKitProjects.CalendarDisplay.loading_style(), "<style>")
    end

    test "with core's CSP support: the page's nonce reaches the tags and a nested view" do
      if Code.ensure_loaded?(PhoenixKitWeb.CSP) do
        session = %{"phoenix_kit_csp_nonces" => %{"style" => "st-1", "script" => "sc-1"}}
        assert CSP.on_mount(:default, %{}, session, :socket) == {:cont, :socket}

        assert CSP.nonce(:style) == "st-1"
        assert CSP.nonce(:script) == "sc-1"
        assert CSP.attr(:style) == ~s( nonce="st-1")
        assert CSP.nested_session(%{"id" => "x"}) == Map.put(session, "id", "x")

        assert String.starts_with?(
                 PhoenixKitProjects.CalendarDisplay.loading_style(),
                 ~s(<style nonce="st-1">)
               )
      end
    end
  end

  defp bundle_lines(file) do
    "priv/static/assets/#{file}" |> File.read!() |> String.split("\n") |> Enum.with_index(1)
  end

  defp in_heex?(lines, number) do
    lines
    |> Enum.take(number - 1)
    |> Enum.reverse()
    |> Enum.find(fn {line, _} -> line =~ ~s(""") end)
    |> case do
      {opener, _} -> opener =~ ~s(~H""")
      nil -> false
    end
  end

  defp tag_openings(path) do
    source = path |> File.read!() |> markup_source()

    for [{start, length}] <- Regex.scan(@tag_opening, source, return: :index, capture: :first) do
      line = source |> binary_part(0, start) |> String.split("\n") |> length()
      {binary_part(source, start, length), line}
    end
  end

  # The source with what is not markup blanked, line numbers kept:
  # documentation, HEEx comments and Elixir comment lines.
  defp markup_source(source) do
    blank = fn text -> String.replace(text, ~r/[^\n]/, "") end

    source
    |> then(&Regex.replace(@doc_heredoc, &1, blank))
    |> then(&Regex.replace(~r/@(?:moduledoc|doc|typedoc)\s+"[^"\n]*"/, &1, blank))
    |> then(&Regex.replace(~r/<%!--.*?--%>/s, &1, blank))
    |> then(&Regex.replace(~r/^[ \t]*#[^\n]*$/m, &1, ""))
  end

  defp code_lines(source) do
    @doc_heredoc
    |> Regex.replace(source, fn doc -> String.replace(doc, ~r/[^\n]/, "") end)
    |> String.split("\n")
    |> Enum.with_index(1)
  end
end
