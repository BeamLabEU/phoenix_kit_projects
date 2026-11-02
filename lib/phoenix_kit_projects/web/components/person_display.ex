defmodule PhoenixKitProjects.Web.Components.PersonDisplay do
  @moduledoc """
  One way to show a person everywhere in the module: a face and a name
  (the boss, 2026-10-30: the time logs showed some people by their email,
  others by name, with no picture). The face is core's `user_avatar` when
  the account is at hand (uploaded, OAuth, Gravatar, then initials), the
  name's initials otherwise, a chip icon for an AI agent. The name is the
  account's, else its staff person's (`People.user_display_names/1`); an
  email only when there is no name at all.

      <.person name={row.worker.name} kind={row.worker.kind} />
      <.person name={name} user={user} size="sm" />
  """

  use Phoenix.Component

  import PhoenixKitWeb.Components.Core.Icon, only: [icon: 1]
  import PhoenixKitWeb.Components.Core.UserInfo, only: [user_avatar: 1]

  alias PhoenixKitProjects.Web.Components.AssigneeFaces

  attr(:name, :string, required: true)
  attr(:user, :any, default: nil, doc: "the `%User{}`, when at hand, for its picture")
  attr(:kind, :string, default: "user", doc: "`\"ai_agent\"` shows a chip, not a face")
  attr(:size, :string, default: "xs", values: ~w(xs sm))
  attr(:class, :any, default: nil)
  slot(:inner_block, doc: "after the name (a badge)")

  def person(assigns) do
    ~H"""
    <span class={["inline-flex items-center gap-1.5 min-w-0", @class]}>
      <%= cond do %>
        <% @kind == "ai_agent" -> %>
          <span class={[face_class(@size), "bg-base-200"]}>
            <.icon name="hero-cpu-chip" class="w-3.5 h-3.5 text-base-content/60" />
          </span>
        <% is_struct(@user) -> %>
          <.user_avatar user={@user} size={@size} />
        <% true -> %>
          <span class={[face_class(@size), "bg-base-300 text-base-content/70 font-semibold"]}>
            {AssigneeFaces.initials(@name)}
          </span>
      <% end %>
      <span class="truncate">{@name}</span>
      {render_slot(@inner_block)}
    </span>
    """
  end

  defp face_class("sm"),
    do: "inline-flex items-center justify-center rounded-full shrink-0 w-8 h-8 text-xs"

  defp face_class(_),
    do: "inline-flex items-center justify-center rounded-full shrink-0 w-6 h-6 text-[0.6rem]"
end
