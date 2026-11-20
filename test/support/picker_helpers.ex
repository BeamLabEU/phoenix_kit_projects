defmodule PhoenixKitProjects.PickerHelpers do
  @moduledoc """
  Drives core's people picker (`PhoenixKitWeb.Components.PeoplePicker`) in a
  form's LiveView test: its events are the LiveComponent's own, so they are
  sent to it with `with_target/2` on the picker's id (`"assignment-assignee"`,
  `"project-assignee"`, `"subproject-assignee"`, `"task-default-assignee"`).
  The change reaches the form through the parent's `handle_info/2`, as in a
  browser; `render/1` after each call shows it.

  The task form's pickers carry their record in the id
  (`"assignment-assignee-<uuid>"`, `-new`): a bare name finds the one picker
  whose id starts with it (`target/1`).
  """

  import Phoenix.LiveViewTest

  @doc """
  The picker's full id on the page (`"assignment-assignee-<uuid>"` or
  `-new`), for selectors into it (`"#\#{picker_id(view, name)}-chip-…"`).
  """
  def picker_id(view, name) do
    html = render(view)

    case Regex.run(~r/id="(#{name}-(?:new|[0-9a-f]{8}-[0-9a-f-]{27}))"/, html) do
      [_, id] -> id
      _ -> name
    end
  end

  @doc "The picker by its exact id, or by a name its id starts with."
  def target(id), do: ~s(##{id}, [id^="#{id}-"][data-phx-component])

  @doc "A pick, as a row of the lists: adds it (or asks first, for an account)."
  def pick(view, id, kind, uuid),
    do:
      view |> with_target(target(id)) |> render_click("toggle", %{"kind" => kind, "uuid" => uuid})

  @doc "The chip's ✕."
  def remove(view, id, kind, uuid),
    do:
      view |> with_target(target(id)) |> render_click("remove", %{"kind" => kind, "uuid" => uuid})

  @doc "A Recent chip."
  def recent(view, id, kind, uuid),
    do:
      view |> with_target(target(id)) |> render_click("recent", %{"kind" => kind, "uuid" => uuid})

  @doc "\"Assign to me\"."
  def me(view, id), do: view |> with_target(target(id)) |> render_click("me", %{})

  @doc "The Yes of the staff-record question."
  def confirm(view, id), do: view |> with_target(target(id)) |> render_click("confirm", %{})

  @doc "The question's Cancel."
  def cancel(view, id), do: view |> with_target(target(id)) |> render_click("cancel_confirm", %{})

  @doc "Typing in the search field (the debounce is the browser's)."
  def query(view, id, text),
    do: view |> with_target(target(id)) |> render_keyup("query", %{"value" => text})

  @doc "Focusing the search field: the opening lists."
  def open(view, id), do: view |> with_target(target(id)) |> render_focus("open", %{})
end
