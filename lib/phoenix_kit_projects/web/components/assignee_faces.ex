defmodule PhoenixKitProjects.Web.Components.AssigneeFaces do
  @moduledoc """
  Who has a task, as faces (the boss, 2026-10-29): a person's profile
  picture, or a small overlapping stack for a team or a department with
  "+N" for the rest. Pictures come from core's `user_avatar` (uploaded,
  OAuth, Gravatar, then coloured initials); a staff person without an
  account shows their initials. Fed by `PhoenixKitProjects.Assignees.faces/2`.
  """

  use Phoenix.Component
  use Gettext, backend: PhoenixKitProjects.Gettext

  import PhoenixKitWeb.Components.Core.UserInfo, only: [user_avatar: 1]

  attr(:faces, :map, default: nil, doc: "`%{faces: [...], extra: n}` or nil")
  attr(:size, :string, default: "xs", values: ~w(xs sm))
  attr(:class, :any, default: nil)

  def assignee_faces(%{faces: nil} = assigns), do: ~H""
  def assignee_faces(%{faces: %{faces: []}} = assigns), do: ~H""

  def assignee_faces(assigns) do
    ~H"""
    <span
      class={["inline-flex items-center shrink-0", length(@faces.faces) > 1 && "-space-x-1.5", @class]}
      title={Enum.map_join(@faces.faces, ", ", & &1.name) <> extra_title(@faces.extra)}
    >
      <span :for={f <- @faces.faces} class="inline-flex rounded-full ring-2 ring-base-100">
        <%= if f.user do %>
          <.user_avatar user={f.user} size={@size} />
        <% else %>
          <span class={[
            "inline-flex items-center justify-center rounded-full bg-base-300 text-base-content/70 font-semibold",
            @size == "xs" && "w-6 h-6 text-[0.6rem]",
            @size == "sm" && "w-8 h-8 text-xs"
          ]}>
            {initials(f.name)}
          </span>
        <% end %>
      </span>
      <span
        :if={@faces.extra > 0}
        class={[
          "inline-flex items-center justify-center rounded-full bg-base-200 text-base-content/70 ring-2 ring-base-100 font-medium",
          @size == "xs" && "w-6 h-6 text-[0.6rem]",
          @size == "sm" && "w-8 h-8 text-xs"
        ]}
      >
        +{@faces.extra}
      </span>
    </span>
    """
  end

  defp extra_title(0), do: ""
  defp extra_title(n), do: " " <> gettext("and %{count} more", count: n)

  @doc false
  def initials(name) do
    name
    |> to_string()
    |> String.split(~r/[\s@._-]+/, trim: true)
    |> Enum.take(2)
    |> Enum.map_join(&String.first/1)
    |> String.upcase()
    |> case do
      "" -> "?"
      i -> i
    end
  end
end
