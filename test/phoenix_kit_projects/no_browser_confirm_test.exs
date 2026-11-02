defmodule PhoenixKitProjects.NoBrowserConfirmTest do
  @moduledoc """
  Nothing in the module asks through the browser's own confirm box
  (`data-confirm`): every Close, Delete and popup ✕ asks in the page's own
  dialog, `Components.ConfirmAction` (the boss, 2026-11-02 — the browser's
  box froze the page and looks foreign). Only `confirm_action.ex`'s own
  documentation may name the attribute, to say why it is not used.
  """

  use ExUnit.Case, async: true

  test "no data-confirm in lib/ outside ConfirmAction's documentation" do
    offenders =
      Path.wildcard("lib/**/*.{ex,heex}")
      |> Enum.reject(&String.ends_with?(&1, "components/confirm_action.ex"))
      |> Enum.filter(&(File.read!(&1) =~ "data-confirm"))

    assert offenders == []
  end
end
