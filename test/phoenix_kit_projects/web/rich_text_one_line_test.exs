defmodule PhoenixKitProjects.Web.RichTextOneLineTest do
  @moduledoc """
  `RichText.one_line/1`: a description as one line for a list's cell (Max,
  2026-11-27: the projects list showed `@[user:…|maxdon2001]`).
  """

  use ExUnit.Case, async: true

  alias PhoenixKitProjects.Web.Components.RichText

  test "a mention reads as its name, a link as its text; pictures and marks go" do
    text =
      "Hello @[user:019d6837-db2d-74da-be36-f66e905e0872|maxdon2001] see **this** " <>
        "and [the doc](https://x.y) ![p](pkfile:abc)\n\n- one\n- two " <>
        "#[project:01a21075-3545-78cb-b8b6-9221ede7f2fa|TIAT]"

    assert RichText.one_line(text) == "Hello @maxdon2001 see this and the doc one two TIAT"
  end

  test "headings, quotes and emphasis lose their marks; words keep theirs" do
    assert RichText.one_line("# Title\n> quote *em* snake_case_name, 2*3*4") ==
             "Title quote em snake_case_name, 2*3*4"
  end

  test "nothing to show is nil" do
    assert RichText.one_line(nil) == nil
    assert RichText.one_line("  \n ") == nil
    assert RichText.one_line("![only](pkfile:x)") == nil
  end
end
