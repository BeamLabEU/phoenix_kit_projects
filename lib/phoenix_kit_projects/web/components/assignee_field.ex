defmodule PhoenixKitProjects.Web.Components.AssigneeField do
  @moduledoc """
  Whose a task, a sub-project, a project or a library task is: core's people
  picker (`PhoenixKitWeb.Components.PeoplePicker`) over this module's people,
  teams and departments (`PhoenixKitProjects.PeopleSource`). The module's own
  picker moved into core (the boss, 2026-11-18: "make sure this component is
  in core because it's pretty useful to be able to select people like
  that"); this is what is left of it — the field with the module's words,
  and the LiveView side of the choice.

  ## In a LiveView

      # mount (and whenever the record changes):
      socket |> AssigneeField.init(project, can_assign?: …, source: "project_form")
             |> AssigneeField.set_selected(AssigneeField.changeset_keys(cs))

      # the picker's change message, in one clause:
      def handle_info({PhoenixKitWeb.Components.PeoplePicker, _id, {:changed, _}} = msg, socket),
        do: AssigneeField.handle_info(msg, socket, __MODULE__)

      # the two callbacks it calls back:
      def picker_allowed?(socket), do: …     # may this viewer assign, now?
      def picker_set(socket, keys), do: …    # the whole new list into the form

      # in the form:
      <.assignee_field id="x-assignee" name="x[assignees][]" selected={@assignee_selected}
        can_assign={@can_assign?} project_uuid={@assignee_project_uuid}
        source={@assignee_source} label={gettext("Assignees")} />

  Assigns it keeps: `assignee_selected` (the ordered `[{kind, uuid}]` the
  form holds), `can_assign?`, `assignee_project_uuid` (the project whose
  tasks Recent looks at), `assignee_source` (the activity's `source` of a
  staff record made from it) and `assignee_viewer_uuid` (who picks). The
  call passes them as below — `viewer_uuid={@assignee_viewer_uuid}` too.

  The picker re-checks nothing itself: a crafted change reaches
  `handle_info/3` like a real one, which asks `picker_allowed?/1` (the right
  as it is now) before the list goes into the form; a refused one is handed
  back to the picker, so its chips and hidden inputs drop the refused pick.
  An account picked after the staff-record question (`{"user", uuid}`) is
  turned into its staff person HERE, once the right has been asked
  (`resolve_accounts/2`), and the picker is handed the person in its place.
  """

  use Phoenix.Component
  use Gettext, backend: PhoenixKitProjects.Gettext

  alias Phoenix.LiveView
  alias PhoenixKitProjects.{Activity, Assignees, AssigneeSet, People}
  alias PhoenixKitWeb.Components.PeoplePicker

  @callback picker_allowed?(LiveView.Socket.t()) :: boolean()
  @callback picker_set(LiveView.Socket.t(), [{String.t(), String.t()}]) :: LiveView.Socket.t()

  # ── State ──────────────────────────────────────────────────────────

  @doc """
  The field's assigns for a project (nil: no project, e.g. the task
  library): whether the viewer may assign (`opts[:can_assign?]`, default
  true) and, in `opts[:source]`, the form named in the log line of a staff
  record made from it.
  """
  @spec init(LiveView.Socket.t(), map() | nil, keyword()) :: LiveView.Socket.t()
  def init(socket, project, opts \\ []) do
    project_uuid =
      case project do
        %{uuid: uuid} when is_binary(uuid) and uuid != "" -> uuid
        _ -> nil
      end

    assign(socket,
      assignee_project_uuid: project_uuid,
      assignee_source: Keyword.get(opts, :source, "task_form"),
      can_assign?: Keyword.get(opts, :can_assign?, true),
      assignee_selected: socket.assigns[:assignee_selected] || [],
      # Who picks: their Recent picks and "Assign to me" (the picker cannot
      # see the page's user).
      assignee_viewer_uuid: Activity.actor_uuid(socket)
    )
  end

  @doc "The chosen assignees as the form holds them (`[{kind, uuid}]`)."
  @spec set_selected(LiveView.Socket.t(), [{String.t(), String.t()}]) :: LiveView.Socket.t()
  def set_selected(socket, keys) when is_list(keys), do: assign(socket, :assignee_selected, keys)

  @doc """
  The set a form's changeset holds now: the one just chosen
  (`:assignee_keys`), else the record's own (`AssigneeSet.keys/1`).
  """
  @spec changeset_keys(Ecto.Changeset.t() | term()) :: [{String.t(), String.t()}]
  def changeset_keys(%Ecto.Changeset{} = cs) do
    case Ecto.Changeset.get_change(cs, :assignee_keys) do
      keys when is_list(keys) -> keys
      _ -> AssigneeSet.keys(cs.data)
    end
  end

  def changeset_keys(_), do: []

  @doc """
  A form's posted `assignees`, cut down to the ones that can be saved: the
  record's own current assignees, and anyone else who still exists and is
  not trashed. A crafted `kind:uuid` (or a person hard-deleted since the
  pick) would otherwise fail on a foreign key inside the save. A list that
  is not a list of assignees is left for the changeset to report.
  """
  @spec vet_posted(map(), map()) :: map()
  def vet_posted(%{"assignees" => posted} = attrs, record) do
    case AssigneeSet.normalize(posted) do
      {:ok, keys} ->
        held = AssigneeSet.keys(record)

        keep =
          Enum.filter(keys, fn {kind, uuid} = key ->
            key in held or Assignees.describe_pick(kind, uuid) != nil
          end)

        Map.put(attrs, "assignees", posted(keep))

      :error ->
        attrs
    end
  end

  def vet_posted(attrs, _record), do: attrs

  @doc """
  A set as a form posts it: `"kind:uuid"` each, after an empty first entry
  (so a cleared list still arrives).
  """
  @spec posted([{String.t(), String.t()}]) :: [String.t()]
  def posted(keys), do: [""] ++ Enum.map(keys, fn {kind, uuid} -> "#{kind}:#{uuid}" end)

  # ── The picker's message ───────────────────────────────────────────

  @doc """
  The picker's `{:changed, keys}`: taken only while `mod.picker_allowed?/1`
  says so, then put in the form (`mod.picker_set/2`). Refused, the picker is
  handed the form's list back.
  """
  @spec handle_info({module(), String.t(), {:changed, list()}}, LiveView.Socket.t(), module()) ::
          {:noreply, LiveView.Socket.t()}
  def handle_info({PeoplePicker, id, {:changed, keys}}, socket, mod) when is_list(keys) do
    keys = for {kind, uuid} <- keys, is_binary(kind) and is_binary(uuid), do: {kind, uuid}

    if mod.picker_allowed?(socket) do
      {resolved, socket} = resolve_accounts(keys, socket)
      if resolved != keys, do: LiveView.send_update(PeoplePicker, id: id, selected: resolved)
      {:noreply, socket |> set_selected(resolved) |> mod.picker_set(resolved)}
    else
      LiveView.send_update(PeoplePicker,
        id: id,
        selected: socket.assigns[:assignee_selected] || []
      )

      {:noreply, socket}
    end
  end

  def handle_info(_msg, socket, _mod), do: {:noreply, socket}

  @doc """
  The keys with every account (`{"user", uuid}`) replaced by its staff
  person, made when it has none (`People.ensure_person_for_user/2`, logged
  as made from `assignee_source` by the viewer). An account that cannot be
  made one (trashed, inactive) is left out, with a flash. Call it only once
  the viewer's right to assign has been asked.
  """
  @spec resolve_accounts([{String.t(), String.t()}], LiveView.Socket.t()) ::
          {[{String.t(), String.t()}], LiveView.Socket.t()}
  def resolve_accounts(keys, socket) do
    {resolved, socket} =
      Enum.reduce(keys, {[], socket}, fn
        {"user", uuid}, {acc, sock} ->
          case People.ensure_person_for_user(uuid,
                 actor_uuid: Activity.actor_uuid(sock),
                 source: sock.assigns[:assignee_source] || "task_form"
               ) do
            {:ok, %{uuid: person_uuid}} ->
              {[{"person", person_uuid} | acc], sock}

            {:error, :trashed_person} ->
              {acc,
               LiveView.put_flash(
                 sock,
                 :error,
                 gettext(
                   "Their staff record is in the trash; restore it under Staff → People to assign them."
                 )
               )}

            {:error, _} ->
              {acc,
               LiveView.put_flash(sock, :error, gettext("Could not create the staff record."))}
          end

        key, {acc, sock} ->
          {[key | acc], sock}
      end)

    {resolved |> Enum.reverse() |> Enum.uniq(), socket}
  end

  # ── The field ──────────────────────────────────────────────────────

  @doc """
  The assignee field, inside the form it fills: `name` is the list field the
  choice posts under (`"assignment[assignees][]"`, one `kind:uuid` each,
  after an empty one so a cleared list still posts). Several assignees; a
  pick adds, ✕ removes; "Assign to me"; Recent; an account with no staff
  record asks before one is made.
  """
  attr(:id, :string, required: true)
  attr(:name, :string, required: true)
  attr(:selected, :list, required: true)
  attr(:label, :string, default: nil)
  attr(:can_assign, :boolean, default: true)
  attr(:project_uuid, :string, default: nil)
  attr(:source, :string, default: "task_form")
  attr(:viewer_uuid, :string, default: nil)
  attr(:class, :any, default: nil)

  def assignee_field(assigns) do
    ~H"""
    <.live_component
      module={PeoplePicker}
      id={@id}
      selected={@selected}
      source={PhoenixKitProjects.PeopleSource}
      source_opts={%{project_uuid: @project_uuid, source: @source}}
      viewer_uuid={@viewer_uuid}
      name={@name}
      can_edit={@can_assign}
      label={@label}
      placeholder={gettext("Search a person, team or department")}
      me_label={gettext("Assign to me")}
      class={@class}
    />
    """
  end
end
