defmodule PhoenixKitProjects.Web.Components.RefChip do
  @moduledoc """
  A project's key or a task's ref (`ACME`, `ACME-42` —
  `PhoenixKitProjects.Refs`) as a small monospace pill — the same pill
  wherever a ref shows, rows and popups included (the boss, 2026-10-31): the name to say
  aloud, type into a search box or the address bar, or paste into a commit
  message. A click copies it (Max, 2026-11-26: "clicking on the id of a
  task anywhere copies its id"), the pill saying "Copied" for a moment
  (`phoenix_kit_projects.js`, `[data-pkp-copy]`); so does Enter or Space
  on it. Nothing renders for a row that has none yet.
  """

  use Phoenix.Component
  use Gettext, backend: PhoenixKitProjects.Gettext

  attr(:ref, :string, default: nil)
  attr(:size, :string, default: "sm", values: ~w(sm md))
  attr(:class, :any, default: nil)

  def ref_chip(%{ref: ref} = assigns) when ref in [nil, ""], do: ~H""

  def ref_chip(assigns) do
    ~H"""
    <button
      type="button"
      data-ref={@ref}
      data-pkp-copy={@ref}
      data-copied={gettext("Copied")}
      title={gettext("Click to copy %{ref} — works in search, in the address bar and on the API", ref: @ref)}
      class={[
        "badge badge-ghost font-mono select-all whitespace-nowrap shrink-0 text-base-content/70",
        "cursor-copy hover:text-base-content",
        @size == "sm" && "badge-sm",
        @class
      ]}
    >{@ref}</button>
    """
  end
end
