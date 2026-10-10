defmodule PhoenixKitProjects.Web.Components.MoveProject do
  @moduledoc """
  The "Move…" dialog: put a project somewhere else in the tree — make a
  sub-project its own top-level project, or nest a project under another —
  and choose what it takes along from the parent it leaves
  (`PhoenixKitProjects.ProjectMove`: members, module settings, API keys).

  Before this the only way out of a parent was "Make standalone" in the
  row menu of the PARENT's task list, which nobody looking at the
  sub-project itself could find (Max, 2026-10-10), and it left the project
  with no members and its agent's key behind.

  Shared by the project page (its own ⋮ menu and a sub-project row's) and
  the projects list (a row's ⋮ menu), in `ConfirmAction`'s shape — the page
  adds one modal and one event clause and keeps its own handlers:

      def handle_event(event, params, socket) when event in MoveProject.events(),
        do: MoveProject.handle_event(event, params, socket, &after_move/2)

      <.move_project_modal move={assigns[:move_project]} />

  The menu button pushes `move_project_open` with the project's uuid.
  `after_move.(socket, result)` runs once the move has committed (reload
  the list, re-open the page) and returns the socket. The mover is checked
  in `ProjectMove.run/4`, not here: an event naming a project they may not
  move opens nothing and moves nothing.
  """

  use Phoenix.Component
  use Gettext, backend: PhoenixKitProjects.Gettext

  import Phoenix.LiveView, only: [put_flash: 3]
  import PhoenixKitWeb.Components.Core.Modal, only: [modal: 1]
  import PhoenixKitWeb.Components.Core.Icon, only: [icon: 1]

  alias PhoenixKitProjects.{Activity, Authz, L10n, ProjectMove, Projects}
  alias PhoenixKitProjects.Schemas.Project
  alias PhoenixKitProjects.Web.Helpers, as: WebHelpers

  @events ~w(move_project_open move_project_change move_project_submit move_project_close)

  @doc "The events this dialog answers."
  @spec events() :: [String.t()]
  def events, do: @events

  @doc """
  Answers one of `events/0`. `after_move` is called with the socket and the
  move's result once it has committed.
  """
  @spec handle_event(String.t(), map(), Phoenix.LiveView.Socket.t(), (Phoenix.LiveView.Socket.t(),
                                                                      map() ->
                                                                        Phoenix.LiveView.Socket.t())) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_event("move_project_open", %{"uuid" => uuid}, socket, _after_move)
      when is_binary(uuid) do
    scope = socket.assigns[:phoenix_kit_current_scope]

    with %Project{} = project <- Projects.get_project(uuid),
         true <- Authz.can?(scope, project, :edit_settings) do
      preview = ProjectMove.preview(project, scope)

      {:noreply,
       assign(socket,
         move_project: %{
           preview: preview,
           # Leaving a parent defaults to "its own project" — what the
           # dialog is most often opened for; a top-level project can only
           # go under another, so nothing is preselected.
           target: if(preview.parent, do: "top", else: ""),
           members: preview.members != [],
           modules: preview.modules != [],
           keys: [],
           error: nil
         }
       )}
    else
      _ -> {:noreply, socket}
    end
  end

  def handle_event("move_project_change", params, socket, _after_move) do
    case socket.assigns[:move_project] do
      nil -> {:noreply, socket}
      move -> {:noreply, assign(socket, move_project: read_form(move, params))}
    end
  end

  def handle_event("move_project_submit", params, socket, after_move) do
    case socket.assigns[:move_project] do
      nil -> {:noreply, socket}
      move -> submit(read_form(move, params), socket, after_move)
    end
  end

  def handle_event("move_project_close", _params, socket, _after_move),
    do: {:noreply, assign(socket, move_project: nil)}

  def handle_event(_event, _params, socket, _after_move), do: {:noreply, socket}

  # Only what the dialog offered is read back: a target outside the list, or
  # a key that is not one of the ancestors', is dropped here and refused
  # again by `ProjectMove.run/4`.
  defp read_form(%{preview: preview} = move, params) do
    place = Map.get(params, "place", "")
    target_uuids = Enum.map(preview.targets, & &1.uuid)
    key_uuids = Enum.map(preview.keys, & &1.uuid)

    target =
      case {place, Map.get(params, "parent", "")} do
        {"top", _} -> if preview.parent, do: "top", else: ""
        {"under", uuid} -> if uuid in target_uuids, do: uuid, else: "under"
        _ -> move.target
      end

    %{
      move
      | target: target,
        members: Map.get(params, "members") == "true",
        modules: Map.get(params, "modules") == "true",
        keys: params |> Map.get("keys", []) |> List.wrap() |> Enum.filter(&(&1 in key_uuids)),
        error: nil
    }
  end

  defp submit(%{target: target} = move, socket, _after_move) when target in ["", "under"] do
    {:noreply,
     assign(socket, move_project: %{move | error: gettext("Choose where the project goes.")})}
  end

  defp submit(%{preview: %{project: project}} = move, socket, after_move) do
    scope = socket.assigns[:phoenix_kit_current_scope]
    actor = Activity.actor_uuid(socket)
    target = if move.target == "top", do: :top, else: move.target

    opts = [members: move.members, modules: move.modules, keys: move.keys, actor_uuid: actor]

    case ProjectMove.run(project, target, scope, opts) do
      {:ok, result} ->
        Activity.log("projects.project_moved",
          actor_uuid: actor,
          resource_type: "project",
          resource_uuid: project.uuid,
          metadata: %{
            "name" => project.name,
            "from_project_uuid" => result.from && result.from.uuid,
            "from" => result.from && result.from.name,
            "to_project_uuid" => result.to && result.to.uuid,
            "to" => result.to && result.to.name,
            "members" => result.members,
            "modules" => result.modules,
            "keys" => result.keys
          }
        )

        socket =
          socket
          |> assign(move_project: nil)
          |> put_flash(:info, moved_message(result))

        {:noreply, after_move.(socket, result)}

      {:error, reason} ->
        Activity.log_failed("projects.project_moved",
          actor_uuid: actor,
          resource_type: "project",
          resource_uuid: project.uuid,
          metadata: %{"name" => project.name}
        )

        {:noreply, assign(socket, move_project: %{move | error: error_message(reason)})}
    end
  end

  defp moved_message(%{project: project, to: nil}),
    do: gettext("\"%{name}\" is now its own project.", name: name(project))

  defp moved_message(%{project: project, to: to}) do
    gettext(~s("%{name}" is now under "%{parent}".), name: name(project), parent: name(to))
  end

  defp error_message(:forbidden), do: gettext("You may not move this project there.")
  defp error_message(:already_there), do: gettext("The project is already there.")

  defp error_message(:would_create_cycle),
    do: gettext("A project cannot go under one of its own sub-projects.")

  defp error_message(:archived), do: gettext("An archived project cannot be moved.")
  defp error_message(:not_found), do: gettext("That project no longer exists.")
  defp error_message(_), do: gettext("Could not move the project.")

  defp name(%Project{} = project),
    do: Project.localized_name(project, L10n.current_content_lang())

  attr(:move, :any,
    default: nil,
    doc: "The page's `:move_project` assign; nothing renders when nil."
  )

  def move_project_modal(%{move: nil} = assigns), do: ~H""

  def move_project_modal(assigns) do
    %{preview: preview} = assigns.move

    assigns =
      assign(assigns,
        project: preview.project,
        parent: preview.parent,
        targets: preview.targets,
        members: preview.members,
        modules: preview.modules,
        keys: preview.keys,
        under?: assigns.move.target not in ["top", ""]
      )

    ~H"""
    <.modal
      show
      on_close="move_project_close"
      id={"move-project-#{@project.uuid}"}
      max_width="lg"
      close_guard={:input}
    >
      <:title>{gettext("Move \"%{name}\"", name: name(@project))}</:title>
      <p class="text-sm text-base-content/70">
        <%= if @parent do %>
          {gettext("Now a sub-project of \"%{parent}\". Its tasks, sub-projects and logged time stay with it wherever it goes.",
            parent: name(@parent)
          )}
        <% else %>
          {gettext("Now a project of its own. Its tasks, sub-projects and logged time stay with it wherever it goes.")}
        <% end %>
      </p>

      <form
        id={"move-project-form-#{@project.uuid}"}
        phx-change="move_project_change"
        phx-submit="move_project_submit"
        class="flex flex-col gap-4 mt-4"
      >
        <fieldset class="flex flex-col gap-2">
          <label :if={@parent} class="flex items-start gap-2 cursor-pointer">
            <input
              type="radio"
              name="place"
              value="top"
              checked={@move.target == "top"}
              class="radio radio-sm mt-0.5"
            />
            <span>
              <span class="font-medium">{gettext("Make it its own project")}</span>
              <span class="block text-xs text-base-content/60">
                {gettext("It leaves \"%{parent}\" and appears in the projects list.", parent: name(@parent))}
              </span>
            </span>
          </label>

          <label class="flex items-start gap-2 cursor-pointer">
            <input
              type="radio"
              name="place"
              value="under"
              checked={@under?}
              disabled={@targets == []}
              class="radio radio-sm mt-0.5"
            />
            <span class="flex-1">
              <span class="font-medium">{gettext("Put it under another project")}</span>
              <span :if={@targets == []} class="block text-xs text-base-content/60">
                {gettext("There is no other project you can add it to.")}
              </span>
              <select
                :if={@targets != []}
                name="parent"
                id={"move-project-parent-#{@project.uuid}"}
                class="select select-sm select-bordered w-full mt-1"
                disabled={not @under?}
              >
                <option value="">{gettext("Choose a project…")}</option>
                <option :for={t <- @targets} value={t.uuid} selected={@move.target == t.uuid}>
                  {name(t)}
                </option>
              </select>
            </span>
          </label>
        </fieldset>

        <fieldset
          :if={@parent && (@members != [] or @modules != [] or @keys != [])}
          class="flex flex-col gap-2 border-t border-base-300 pt-3"
        >
          <legend class="text-sm font-medium">
            {gettext("Take along from \"%{parent}\"", parent: name(@parent))}
          </legend>

          <label :if={@members != []} class="flex items-start gap-2 cursor-pointer">
            <input type="hidden" name="members" value="false" />
            <input
              type="checkbox"
              name="members"
              value="true"
              checked={@move.members}
              class="checkbox checkbox-sm mt-0.5"
            />
            <span>
              <span>{ngettext("%{count} member", "%{count} members", length(@members), count: length(@members))}</span>
              <span class="block text-xs text-base-content/60">
                {member_names(@members)} — {gettext("without them only site admins can open the project.")}
              </span>
            </span>
          </label>

          <label :if={@modules != []} class="flex items-start gap-2 cursor-pointer">
            <input type="hidden" name="modules" value="false" />
            <input
              type="checkbox"
              name="modules"
              value="true"
              checked={@move.modules}
              class="checkbox checkbox-sm mt-0.5"
            />
            <span>
              <span>{gettext("Modules and their settings")}</span>
              <span class="block text-xs text-base-content/60">{module_names(@modules)}</span>
            </span>
          </label>

          <div :if={@keys != []} class="flex flex-col gap-1">
            <p class="text-sm">
              <.icon name="hero-key" class="w-4 h-4 inline" />
              {gettext("API keys that reach this project only through its parent")}
            </p>
            <p class="text-xs text-base-content/60">
              {gettext("A key you tick moves with the project: its token keeps working here and stops reaching the old parent. A key you leave stays where it is and no longer reaches this project.")}
            </p>
            <label :for={key <- @keys} class="flex items-center gap-2 cursor-pointer pl-1">
              <input
                type="checkbox"
                name="keys[]"
                value={key.uuid}
                checked={key.uuid in @move.keys}
                class="checkbox checkbox-sm"
              />
              <span class="text-sm">{key.name}</span>
            </label>
          </div>
        </fieldset>

        <p :if={@move.error} class="text-sm text-error" role="alert">{@move.error}</p>

        <div class="modal-action">
          <button type="button" class="btn btn-ghost btn-sm" phx-click="move_project_close">
            {gettext("Cancel")}
          </button>
          <%!-- A top-level project with nowhere to go under: nothing to submit. --%>
          <button
            type="submit"
            class="btn btn-primary btn-sm"
            disabled={is_nil(@parent) and @targets == []}
            phx-disable-with={gettext("Moving…")}
          >
            {gettext("Move")}
          </button>
        </div>
      </form>
    </.modal>
    """
  end

  defp member_names(members) do
    Enum.map_join(members, ", ", fn m ->
      case m.user do
        %{} = user -> user_label(user)
        _ -> gettext("(deleted account)")
      end
    end)
  end

  defp user_label(user) do
    case [Map.get(user, :first_name), Map.get(user, :last_name)]
         |> Enum.filter(&(is_binary(&1) and &1 != ""))
         |> Enum.join(" ") do
      "" -> Map.get(user, :email) || gettext("(deleted account)")
      full -> full
    end
  end

  defp module_names(rows) do
    Enum.map_join(rows, ", ", fn row ->
      case PhoenixKitProjects.Extensions.Registry.get(row.ext_key) do
        %{name: name} -> WebHelpers.translate_catalog(name)
        _ -> row.ext_key
      end
    end)
  end
end
