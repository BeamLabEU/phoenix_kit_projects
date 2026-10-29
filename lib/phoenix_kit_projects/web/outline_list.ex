defmodule PhoenixKitProjects.Web.OutlineList do
  @moduledoc """
  The project page's task list as an outline — what `ProjectShowLive` needs
  to show tasks under tasks and to let the list be typed.

  A project's list has one of two faces, chosen by `style/3`:

    * **text** — the whole list is one text field (the `PkpOutline` hook):
      one line a task, an indent a level, a box in the gutter the tick.
      What a to-do list with nothing else switched on looks like.
    * **cards** — a row per task that can carry what the project's features
      put on it; the title is edited in place (the `PkpTitle` hook) and
      Enter adds the next task.

  The project's own choice is `settings["outline"]["style"]`: `"auto"`
  (text until a feature has something to put on a row), `"text"`, `"cards"`.

  Both faces write through `PhoenixKitProjects.Outline`, so a list never
  differs by how it is drawn.
  """

  use Phoenix.Component
  use Gettext, backend: PhoenixKitProjects.Gettext

  import PhoenixKitWeb.Components.Core.Icon

  alias PhoenixKitProjects.{Activity, Authz, Outline, Paths, Projects, Refs}
  alias PhoenixKitProjects.Schemas.{Assignment, Project, Task}
  alias PhoenixKitProjects.Web.Helpers, as: WebHelpers

  # The features that put something on a task's row. With all of them off a
  # row is a tick and a title, and a text field shows that as well as
  # anything.
  @row_features ~w(in_progress assignees priorities labels estimates progress dependencies
                   scheduling ledger)a

  @styles ~w(auto text cards)

  @doc "The list styles a project may choose."
  @spec styles() :: [String.t()]
  def styles, do: @styles

  @doc ~S|The project's stored choice: `"auto"`, `"text"` or `"cards"`.|
  @spec stored_style(Project.t() | map()) :: String.t()
  def stored_style(%{settings: %{"outline" => %{"style" => style}}}) when style in @styles,
    do: style

  def stored_style(_), do: "auto"

  @doc """
  How the list is drawn for this project right now: `:text` or `:cards`.
  A template is always cards (its tasks are library tasks, picked, not
  typed). `"auto"` is text while no row feature is on and the list holds no
  sub-project.
  """
  @spec style(Project.t(), map(), [Assignment.t()]) :: :text | :cards
  def style(%Project{is_template: true}, _fx, _assignments), do: :cards

  def style(%Project{} = project, fx, assignments) do
    case stored_style(project) do
      "text" -> :text
      "cards" -> :cards
      _ -> if plain?(fx, assignments), do: :text, else: :cards
    end
  end

  defp plain?(fx, assignments) do
    fx[:tasks] == true and not Enum.any?(@row_features, &(fx[&1] == true)) and
      not Enum.any?(assignments, &Assignment.subproject?/1)
  end

  @doc """
  Whether a feature's value is shown on a task's row (`true` unless the
  project keeps it to the form: `settings["outline"]["row"][feature] ==
  false`).
  """
  @spec on_row?(Project.t() | map(), String.t() | atom()) :: boolean()
  def on_row?(%{settings: %{"outline" => %{"row" => %{} = row}}}, feature),
    do: Map.get(row, to_string(feature)) != false

  def on_row?(_project, _feature), do: true

  @doc """
  The feature gates as a task CARD uses them: a feature the project keeps
  off the rows (`on_row?/2`) reads as off there — it stays on everywhere
  else, its form included. `estimates` also stands for the dates chip's
  neighbours, `discussion` for the two thread buttons (`:comments_row`).
  """
  @spec row_fx(Project.t() | map(), map()) :: map()
  def row_fx(project, fx) do
    fx
    |> Map.new(fn {key, on?} ->
      {key,
       on? and
         (key not in ~w(assignees priorities labels estimates progress ledger dependencies waiting dates)a or
            on_row?(project, key))}
    end)
    |> Map.put(:comments_row, on_row?(project, "discussion"))
  end

  # ── assigns ────────────────────────────────────────────────────────

  @doc """
  The outline assigns of the page, from its freshly loaded `@assignments`:
  `outline_style`, `outline_depths`, `outline_counts`, `outline_parents`,
  `outline_held`, `outline_can` — and, for the text face, the lines pushed
  to the hook.
  """
  @spec assign_outline(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def assign_outline(socket) do
    %{project: project, fx: fx} = socket.assigns
    assignments = socket.assigns[:assignments] || []
    style = style(project, fx, assignments)
    scope = socket.assigns[:phoenix_kit_current_scope]

    can = %{
      edit:
        fx[:tasks] == true and project.archived_at == nil and
          Authz.can?(scope, project, :edit_tasks) and Authz.can?(scope, project, :create_tasks),
      delete: Authz.can?(scope, project, :delete_tasks),
      tick: fx[:tasks] == true and Authz.can?(scope, project, :update_status),
      nest: fx[:subtasks] != false
    }

    socket =
      assign(socket,
        outline_style: style,
        outline_depths: Outline.depths(assignments),
        outline_counts: Outline.counts(assignments),
        outline_parents: Outline.parents(assignments),
        outline_held: if(can.edit, do: Outline.held(project.uuid), else: []),
        outline_can: can,
        outline_fx: row_fx(project, fx),
        outline_dom_id: "pkp-outline-#{project.uuid}"
      )

    if style == :text do
      lines = lines(socket)

      socket
      |> assign(:outline_lines, lines)
      |> Phoenix.LiveView.push_event("pkp_outline:lines", %{
        id: socket.assigns.outline_dom_id,
        lines: lines
      })
    else
      assign(socket, :outline_lines, [])
    end
  end

  # The list as the text face shows it: one map per line, in outline order.
  defp lines(socket) do
    %{project: project, assignments: assignments} = socket.assigns
    counts = socket.assigns[:outline_counts] || Outline.counts(assignments)

    assignments
    |> Outline.walk()
    |> Enum.map(fn {a, depth} -> line(a, depth, counts, project, socket) end)
  end

  defp line(%Assignment{} = a, depth, counts, project, socket) do
    count = Map.get(counts, a.uuid)

    base = %{
      id: a.uuid,
      text: line_text(a),
      depth: depth,
      done: a.status == "done",
      ref: Refs.task_ref(project.key, a.number) || "",
      count: if(count && count.total > 0, do: "#{count.done}/#{count.total}", else: ""),
      kind: if(Assignment.subproject?(a), do: "project", else: "task")
    }

    Map.merge(base, opener(a, project, socket))
  end

  # The primary title: what the form's Title box edits. A translated title
  # is the translation's own business (the task's form).
  defp line_text(%Assignment{child_project_uuid: nil, task: %Task{title: title}}), do: title || ""
  defp line_text(%Assignment{} = a), do: Assignment.label(a) || ""

  @doc "How the hook opens a line's task: a popup session in a drawer page, else a link."
  @spec opener(Assignment.t(), Project.t(), Phoenix.LiveView.Socket.t()) :: map()
  def opener(%Assignment{} = a, project, socket) do
    cond do
      Assignment.subproject?(a) ->
        %{href: Paths.project(a.child_project_uuid)}

      socket.assigns[:embed_mode] in [:emit, :popup] ->
        lv = PhoenixKitProjects.Web.AssignmentViewLive

        session = %{"project_id" => project.uuid, "id" => a.uuid}

        %{
          open:
            Jason.encode!(%{
              lv: Atom.to_string(lv),
              session: WebHelpers.encode_emit_session(session, __MODULE__, lv)
            })
        }

      true ->
        %{href: Paths.view_assignment(project.uuid, a.uuid)}
    end
  end

  # ── events ─────────────────────────────────────────────────────────

  @doc "The events this module answers (all start with `outline_`)."
  @spec event?(String.t()) :: boolean()
  def event?("outline_" <> _), do: true
  def event?(_), do: false

  @doc """
  Handles an `outline_*` event. `reload` is the page's own "the list
  changed" (`sync_project_completion |> load_assignments`).
  """
  @spec handle_event(
          String.t(),
          map(),
          Phoenix.LiveView.Socket.t(),
          (Phoenix.LiveView.Socket.t() ->
             Phoenix.LiveView.Socket.t())
        ) ::
          {:noreply, Phoenix.LiveView.Socket.t()} | {:reply, map(), Phoenix.LiveView.Socket.t()}
  def handle_event("outline_sync", %{"lines" => lines} = params, socket, reload)
      when is_list(lines) do
    %{project: project, outline_can: can} = socket.assigns

    if can.edit do
      # Without the right to delete, nothing a list omits is taken as
      # removed: the lines come back on the next refresh.
      known = if can.delete, do: List.wrap(params["known"]), else: []

      case Outline.sync(project.uuid, lines, known,
             actor_uuid: Activity.actor_uuid(socket),
             allow_done: can.tick,
             rename_library: library_right?(socket)
           ) do
        {:ok, summary} ->
          log_sync(socket, summary)
          socket = reload.(socket)
          {:reply, sync_reply(summary, socket), socket}

        {:error, reason} ->
          audit_failed(socket, "projects.task_list_edited", project.uuid, "project")
          {:reply, %{error: sync_error(reason)}, socket}
      end
    else
      {:reply, %{error: gettext("You can't change this list.")}, socket}
    end
  end

  def handle_event("outline_restore", %{"uuid" => uuid}, socket, reload) do
    with true <- socket.assigns.outline_can.edit,
         %Assignment{review_status: "removed"} = a <- own(socket, uuid) do
      case Outline.restore(a) do
        {:ok, _} ->
          audit(socket, "projects.assignment_restored", a)
          {:noreply, reload.(socket)}

        {:error, _} ->
          audit_failed(socket, "projects.assignment_restored", uuid)
          {:noreply, put_flash(socket, :error, gettext("The task could not be restored."))}
      end
    else
      _ -> {:noreply, socket}
    end
  end

  def handle_event("outline_purge", %{"uuid" => uuid}, socket, reload) do
    with true <- socket.assigns.outline_can.edit and socket.assigns.outline_can.delete,
         %Assignment{review_status: "removed"} = a <- own(socket, uuid) do
      case PhoenixKitProjects.Notices.removing(a, Activity.actor_uuid(socket), fn ->
             Projects.delete_assignment(a)
           end) do
        {:ok, _} ->
          audit(socket, "projects.assignment_removed", a)
          {:noreply, reload.(socket)}

        {:error, _} ->
          audit_failed(socket, "projects.assignment_removed", uuid)
          {:noreply, put_flash(socket, :error, gettext("Could not remove task."))}
      end
    else
      _ -> {:noreply, socket}
    end
  end

  # ── the card face ──────────────────────────────────────────────────

  def handle_event("outline_rename", %{"id" => uuid, "text" => text}, socket, reload) do
    title = text |> to_string() |> String.replace(~r/\s+/u, " ") |> String.trim()

    with true <- socket.assigns.outline_can.edit,
         true <- title != "",
         %Assignment{task: %Task{} = task} <- own(socket, uuid),
         true <- task.ad_hoc == true or library_right?(socket),
         true <- task.title != title,
         {:ok, _} <- Projects.update_task(task, %{"title" => title}) do
      audit(socket, "projects.assignment_updated", uuid, %{"fields" => ["title"]})
      {:reply, %{}, reload.(socket)}
    else
      _ -> {:reply, %{}, socket}
    end
  end

  def handle_event("outline_add", %{"after" => after_uuid} = params, socket, reload) do
    text = params["text"] |> to_string() |> String.trim()
    title = if text == "", do: gettext("New task"), else: text

    with true <- socket.assigns.outline_can.edit,
         %Assignment{} = anchor <- own(socket, after_uuid),
         {:ok, %{assignment: a}} <-
           Projects.create_task_with_assignment(
             socket.assigns.project.uuid,
             %{"title" => title, "ad_hoc" => true},
             %{}
           ) do
      Projects.stamp_assignment(a, %{created_by_uuid: Activity.actor_uuid(socket)})
      audit(socket, "projects.assignment_created", a)
      # Below a task that has subtasks, the new one is its first subtask;
      # otherwise the next task at the same level. A place that went away
      # meanwhile leaves the task at the end of the list, where it is seen.
      has_below? = Outline.descendants(Outline.shape(a.project_uuid), anchor.uuid) != []

      _ =
        if has_below?,
          do: Outline.move(a, anchor.uuid, nil),
          else: Outline.move(a, anchor.parent_uuid, anchor.uuid)

      {:noreply, socket |> assign(outline_focus: a.uuid, outline_fresh: a.uuid) |> reload.()}
    else
      _ -> {:noreply, socket}
    end
  end

  def handle_event("outline_add_first", _params, socket, reload) do
    with true <- socket.assigns.outline_can.edit,
         {:ok, %{assignment: a}} <-
           Projects.create_task_with_assignment(
             socket.assigns.project.uuid,
             %{"title" => gettext("New task"), "ad_hoc" => true},
             %{}
           ) do
      Projects.stamp_assignment(a, %{created_by_uuid: Activity.actor_uuid(socket)})
      audit(socket, "projects.assignment_created", a)
      {:noreply, socket |> assign(outline_focus: a.uuid, outline_fresh: a.uuid) |> reload.()}
    else
      _ -> {:noreply, socket}
    end
  end

  def handle_event("outline_paste", %{"after" => after_uuid, "lines" => lines}, socket, reload)
      when is_list(lines) do
    with true <- socket.assigns.outline_can.edit,
         %Assignment{} = anchor <- own(socket, after_uuid) do
      # The list as it stands, with the pasted lines put in after the
      # anchor's branch — one write, one refresh.
      walked = Outline.walk(socket.assigns.assignments)
      depths = socket.assigns.outline_depths
      base = Map.get(depths, anchor.uuid, 0)

      branch = [
        anchor.uuid
        | socket.assigns.assignments |> Outline.descendants(anchor.uuid) |> Enum.map(& &1.uuid)
      ]

      last = List.last(branch)

      pasted =
        for %{"text" => text} = line when is_binary(text) <- lines do
          %{
            "id" => nil,
            "text" => text,
            "depth" => base + to_depth(line["depth"]),
            "done" => line["done"] == true and socket.assigns.outline_can.tick
          }
        end

      all =
        Enum.flat_map(walked, fn {a, depth} ->
          here = %{"id" => a.uuid, "text" => line_text(a), "depth" => depth}
          if a.uuid == last, do: [here | pasted], else: [here]
        end)

      case Outline.sync(socket.assigns.project.uuid, all, [],
             actor_uuid: Activity.actor_uuid(socket),
             rename: false
           ) do
        {:ok, summary} ->
          log_sync(socket, summary)
          {:noreply, reload.(socket)}

        {:error, reason} ->
          audit_failed(
            socket,
            "projects.task_list_edited",
            socket.assigns.project.uuid,
            "project"
          )

          {:noreply, put_flash(socket, :error, sync_error(reason))}
      end
    else
      _ -> {:noreply, socket}
    end
  end

  def handle_event("outline_nest", %{"id" => uuid, "dir" => dir}, socket, reload) do
    with true <- socket.assigns.outline_can.edit,
         true <- socket.assigns.outline_can.nest or dir == "out",
         %Assignment{} = a <- own(socket, uuid) do
      rows = socket.assigns.assignments
      siblings = Enum.filter(rows, &(&1.parent_uuid == a.parent_uuid))
      index = Enum.find_index(siblings, &(&1.uuid == a.uuid)) || 0

      result =
        case dir do
          # Under the sibling above, as its last subtask.
          "in" when index > 0 ->
            above = Enum.at(siblings, index - 1)
            if Assignment.subproject?(above), do: :noop, else: Outline.move(a, above.uuid, :last)

          # Out one level, right after what it sat under.
          "out" when is_binary(a.parent_uuid) ->
            parent = Enum.find(rows, &(&1.uuid == a.parent_uuid))
            Outline.move(a, parent && parent.parent_uuid, a.parent_uuid)

          _ ->
            :noop
        end

      case result do
        {:ok, moved} ->
          audit(socket, "projects.assignment_moved", a, %{"parent" => moved.parent_uuid})
          {:noreply, socket |> assign(outline_focus: a.uuid) |> reload.()}

        {:error, _} ->
          audit_failed(socket, "projects.assignment_moved", a.uuid)
          {:noreply, put_flash(socket, :error, gettext("The task could not be moved there."))}

        :noop ->
          {:noreply, socket}
      end
    else
      _ -> {:noreply, socket}
    end
  end

  # A task just added and left empty-handed: Backspace on its blank title.
  def handle_event("outline_drop", %{"id" => uuid}, socket, reload) do
    with true <- socket.assigns.outline_can.edit,
         true <- socket.assigns[:outline_fresh] == uuid,
         %Assignment{} = a <- own(socket, uuid),
         false <- MapSet.member?(socket.assigns.outline_parents, uuid),
         {:ok, _} <- Projects.delete_assignment(a) do
      audit(socket, "projects.assignment_removed", a)
      rows = Outline.walk(socket.assigns.assignments) |> Enum.map(&elem(&1, 0).uuid)
      index = Enum.find_index(rows, &(&1 == uuid)) || 0
      focus = if index > 0, do: Enum.at(rows, index - 1)
      {:noreply, socket |> assign(outline_focus: focus, outline_fresh: nil) |> reload.()}
    else
      _ -> {:noreply, socket}
    end
  end

  def handle_event("outline_fold", %{"uuid" => uuid}, socket, _reload) do
    folded = socket.assigns[:outline_folded] || MapSet.new()

    folded =
      if MapSet.member?(folded, uuid),
        do: MapSet.delete(folded, uuid),
        else: MapSet.put(folded, uuid)

    {:noreply, assign(socket, :outline_folded, folded)}
  end

  def handle_event("outline_open", %{"id" => uuid}, socket, _reload) do
    case own(socket, uuid) do
      %Assignment{} ->
        {:noreply,
         Phoenix.LiveView.push_navigate(socket,
           to: Paths.view_assignment(socket.assigns.project.uuid, uuid)
         )}

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event(_event, _params, socket, _reload), do: {:noreply, socket}

  defp put_flash(socket, kind, message), do: Phoenix.LiveView.put_flash(socket, kind, message)

  # One history line per act, as the row buttons write them; a failure is
  # written too, so the record shows what was tried.
  defp audit(socket, action, a_or_uuid, metadata \\ %{}) do
    {uuid, label} =
      case a_or_uuid do
        %Assignment{} = a -> {a.uuid, Assignment.label(a)}
        uuid -> {uuid, nil}
      end

    Activity.log(action,
      actor_uuid: Activity.actor_uuid(socket),
      resource_type: "assignment",
      resource_uuid: uuid,
      metadata:
        metadata
        |> Map.put("project_uuid", socket.assigns.project.uuid)
        |> then(&if(label, do: Map.put(&1, "task", label), else: &1))
    )
  rescue
    _ -> :ok
  end

  defp audit_failed(socket, action, uuid, type \\ "assignment") do
    Activity.log_failed(action,
      actor_uuid: Activity.actor_uuid(socket),
      resource_type: type,
      resource_uuid: uuid,
      metadata: %{"project_uuid" => socket.assigns.project.uuid}
    )
  rescue
    _ -> :ok
  end

  defp to_depth(n) when is_integer(n) and n >= 0, do: n
  defp to_depth(_), do: 0

  # A library task's title is shared by every project that uses it: renaming
  # one is `projects.manage_library`'s, asked of the LIVE scope at the write
  # (never cached in `outline_can`, which is computed once per reload).
  defp library_right?(socket),
    do: Authz.manage_library?(socket.assigns[:phoenix_kit_current_scope])

  defp own(socket, uuid) when is_binary(uuid) do
    case Projects.get_assignment(uuid) do
      %Assignment{project_uuid: pid} = a when pid == socket.assigns.project.uuid -> a
      _ -> nil
    end
  end

  defp own(_socket, _uuid), do: nil

  defp sync_reply(summary, socket) do
    project = socket.assigns.project
    by_uuid = Map.new(socket.assigns[:assignments] || [], &{&1.uuid, &1})

    created =
      Map.new(summary.created, fn {tmp, %{uuid: uuid, number: number}} ->
        extra =
          case Map.get(by_uuid, uuid) do
            nil -> %{}
            a -> opener(a, project, socket)
          end

        {tmp, Map.merge(%{uuid: uuid, ref: Refs.task_ref(project.key, number) || ""}, extra)}
      end)

    note =
      case length(summary.held) do
        0 ->
          nil

        n ->
          ngettext(
            "1 task you removed carries hours, notes or other work, so it is kept below until you decide.",
            "%{count} tasks you removed carry hours, notes or other work, so they are kept below until you decide.",
            n
          )
      end

    %{created: created, gone: summary.removed ++ summary.held, note: note}
  end

  defp sync_error(:too_many_lines), do: gettext("That is more lines than one list can take.")
  defp sync_error(:not_found), do: gettext("This project no longer exists.")
  defp sync_error({:line, _index, _cs}), do: gettext("One of the lines could not be saved.")
  defp sync_error(_), do: gettext("The list could not be saved.")

  # One line of history for a batch, however many lines it carried.
  defp log_sync(socket, summary) do
    counts = %{
      "created" => summary.created_count,
      "removed" => length(summary.removed),
      "held" => length(summary.held),
      "restored" => length(summary.revived),
      "renamed" => length(summary.renamed)
    }

    if Enum.any?(counts, fn {_k, n} -> n > 0 end) do
      Activity.log("projects.task_list_edited",
        actor_uuid: Activity.actor_uuid(socket),
        resource_type: "project",
        resource_uuid: socket.assigns.project.uuid,
        metadata: Map.put(counts, "project", socket.assigns.project.name)
      )
    end
  rescue
    _ -> :ok
  end

  @doc """
  A switch of the typed list from the project's settings
  (`settings["outline"]["lines"][key]`): `"delete"` (an × at the end of each
  line, on unless turned off) and `"handles"` (a drag grip before the box,
  off unless turned on).
  """
  @spec line_option(Project.t() | map() | nil, String.t(), boolean()) :: boolean()
  def line_option(%{settings: %{"outline" => %{"lines" => %{} = lines}}}, key, default),
    do: Map.get(lines, key, default) == true

  def line_option(_project, _key, default), do: default

  @doc "The rows to draw: everything except what sits under a folded task."
  @spec unfolded([Assignment.t()], MapSet.t()) :: [Assignment.t()]
  def unfolded(rows, folded) do
    if MapSet.size(folded) == 0 do
      rows
    else
      hidden =
        folded
        |> Enum.flat_map(fn uuid -> rows |> Outline.descendants(uuid) |> Enum.map(& &1.uuid) end)
        |> MapSet.new()

      Enum.reject(rows, &MapSet.member?(hidden, &1.uuid))
    end
  end

  # ── components ─────────────────────────────────────────────────────

  attr(:id, :string, required: true)
  attr(:lines, :list, required: true)
  attr(:can, :map, required: true)
  attr(:project, :map, default: nil)

  @doc "The text face: one editable field, owned by the `PkpOutline` hook."
  def text_list(assigns) do
    ~H"""
    <div
      id={@id}
      phx-hook="PkpOutline"
      phx-update="ignore"
      class="rounded-box border border-base-200 bg-base-100 px-2 py-1"
      data-lines={Jason.encode!(@lines)}
      data-can-edit={if @can.edit, do: "1", else: "0"}
      data-can-tick={if @can.tick, do: "1", else: "0"}
      data-can-nest={if Map.get(@can, :nest, true), do: "1", else: "0"}
      data-delete={if line_option(@project, "delete", true), do: "1", else: "0"}
      data-handles={if line_option(@project, "handles", false), do: "1", else: "0"}
      data-label={gettext("Tasks")}
      data-placeholder={gettext("Type a task and press Enter. Paste a list to add many.")}
      data-hint={
        cond do
          not @can.edit -> ""
          Map.get(@can, :nest, true) -> gettext("Enter adds a task · Tab makes it a subtask · changes are saved as you type")
          true -> gettext("Enter adds a task · changes are saved as you type")
        end
      }
      data-saving={gettext("Saving…")}
      data-saved={gettext("Saved")}
      data-failed={gettext("Not saved — check your connection.")}
    >
    </div>
    """
  end

  attr(:held, :list, required: true)
  attr(:can, :map, required: true)
  attr(:project, :map, required: true)

  @doc """
  The tasks taken out of the list that carry something: kept in sight until
  a person puts each back or confirms the delete.
  """
  def held_tray(assigns) do
    ~H"""
    <div :if={@held != []} id={"outline-held-#{@project.uuid}"} class="mt-3 rounded-box border border-dashed border-warning/50 bg-warning/5 p-3">
      <p class="text-xs font-medium text-base-content/70 flex items-center gap-1">
        <.icon name="hero-archive-box-arrow-down" class="w-4 h-4" />
        {gettext("Removed from the list, still kept")}
      </p>
      <p class="text-xs text-base-content/60 mb-2">
        {gettext("These carry hours, a discussion, an owner or other work, so removing the line did not delete them.")}
      </p>
      <ul class="flex flex-col gap-1">
        <li :for={a <- @held} class="flex items-center gap-2 text-sm">
          <span class="font-mono text-xs text-base-content/50 shrink-0">{Refs.task_ref(@project.key, a.number)}</span>
          <span class="truncate flex-1 text-base-content/60 line-through">{Assignment.label(a)}</span>
          <button type="button" class="btn btn-ghost btn-xs" phx-click="outline_restore" phx-value-uuid={a.uuid} phx-disable-with={gettext("Restoring…")}>
            <.icon name="hero-arrow-uturn-left" class="w-3.5 h-3.5" /> {gettext("Restore")}
          </button>
          <button
            :if={@can.delete}
            type="button"
            class="btn btn-ghost btn-xs text-error"
            phx-click="outline_purge"
            phx-value-uuid={a.uuid}
            phx-disable-with={gettext("Deleting…")}
            data-confirm={gettext("Delete \"%{title}\" and everything it carries? This cannot be undone.", title: Assignment.label(a))}
          >
            <.icon name="hero-trash" class="w-3.5 h-3.5" /> {gettext("Delete")}
          </button>
        </li>
      </ul>
    </div>
    """
  end

  attr(:a, :map, required: true)
  attr(:can, :map, required: true)
  attr(:focus, :boolean, default: false)
  attr(:fresh, :boolean, default: false)
  attr(:class, :any, default: nil)

  @doc "A task's title on a card row, edited in place (the `PkpTitle` hook)."
  def title_input(assigns) do
    ~H"""
    <input
      :if={@can.edit}
      id={"task-title-#{@a.uuid}"}
      type="text"
      phx-hook="PkpTitle"
      data-id={@a.uuid}
      data-focus={if @focus, do: "1", else: "0"}
      data-fresh={if @fresh, do: "1", else: "0"}
      value={if @fresh, do: "", else: @a.task && @a.task.title}
      placeholder={gettext("Type the task")}
      maxlength="500"
      autocomplete="off"
      aria-label={gettext("Task title")}
      class={[
        "min-w-0 flex-1 bg-transparent border-0 border-b border-transparent px-0 py-0.5 font-medium",
        "focus:outline-none focus:border-primary hover:border-base-300",
        @class
      ]}
    />
    """
  end
end
