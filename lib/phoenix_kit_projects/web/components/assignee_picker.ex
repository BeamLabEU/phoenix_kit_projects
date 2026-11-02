defmodule PhoenixKitProjects.Web.Components.AssigneePicker do
  @moduledoc """
  The one assignee picker of the module: whose a task, a sub-project, a
  project or a library task's default is. One search over people, teams,
  departments and accounts without a staff record (core `<.search_picker>`),
  "Assign to me", the choice as a chip with its faces, and "Recent" chips —
  the viewer's own picks first, so one removed again stays a press away
  (`PhoenixKitProjects.Assignees.recent_for_viewer/4`).

  Lifted out of the task form (the boss, 2026-10-30: "the user assignment
  thing being different in basically every pop-up"). It is a component plus
  the events behind it; the LiveView keeps only what is its own — where the
  choice goes.

  ## In a LiveView

      # mount (and whenever the record changes):
      socket |> AssigneePicker.init(project, source: "project_form")
             |> AssigneePicker.refresh_chip({kind, uuid} | nil)

      # every picker event, in one clause:
      def handle_event(event, params, socket) when event in AssigneePicker.events(),
        do: AssigneePicker.handle_event(event, params, socket, __MODULE__)

      # the two callbacks it calls back:
      def picker_allowed?(socket), do: …            # may this viewer assign, now?
      def picker_choose(socket, kind, uuid), do: …  # put it in the form (nil = nobody)

      # in the form:
      <.assignee_picker id="x-assignee" fields={…} chip={@assignee_chip} … />
      # after the form (a form inside a form is not HTML):
      <.assignee_picker_outside search_form="x-assignee-form" staff_confirm={@staff_confirm} />

  Assigns it keeps: `assignee_chip`, `recent_assignees`, `my_person_uuid`,
  `can_assign?`, `staff_confirm`, `assignee_notice`, `assignee_project_uuid`.

  ## Several assignees (a task, V29)

  `init(socket, project, multi: true)` turns on the task's picker: any
  number of people, teams and departments, ticked in lists and shown as
  chips above them (the boss, 2026-10-31). It opens on Recent (the viewer's
  own picks), then Teams, Departments and People, five each with "Browse
  more" — which opens that one list alone, with a way back, scrolling on
  for ever (`phx-viewport-bottom`, keyset pages from `Assignees.page/4`).
  Typing searches everything, a team or department followed by its people.

  The ticks have one source, `assignee_selected` (ordered `{kind, uuid}`);
  a person listed twice (alone and under a group) is one tick. The LiveView
  keeps it in step with its form (`set_selected/2`) and implements
  `picker_set(socket, keys)`, called with the whole new list on every
  change. The lists are a stream (`@streams.assignee_options`); a tick
  re-inserts the rows of that key so they redraw.
  """

  use Phoenix.Component
  use Gettext, backend: PhoenixKitProjects.Gettext

  import PhoenixKitWeb.Components.Core.Icon, only: [icon: 1]
  import PhoenixKitWeb.Components.Core.Modal, only: [confirm_modal: 1]
  import PhoenixKitProjects.Web.Components.AssigneeFaces, only: [assignee_faces: 1]

  alias Phoenix.LiveView
  alias PhoenixKit.Users.Auth
  alias PhoenixKit.Users.Auth.User
  alias PhoenixKitProjects.{Activity, Assignees, L10n, People}

  @events ~w(assignee_search assignee_pick assignee_recent assign_to_me
             staff_create_confirm staff_create_cancel assignee_noop assignee_clear
             assignee_toggle assignee_remove assignee_browse assignee_back
             assignee_query assignee_more assignee_open assignee_close)

  @doc "The events the picker sends; a LiveView hands each to `handle_event/4`."
  @spec events() :: [String.t()]
  def events, do: @events

  @callback picker_allowed?(LiveView.Socket.t()) :: boolean()
  @callback picker_choose(LiveView.Socket.t(), String.t() | nil, String.t() | nil) ::
              LiveView.Socket.t()
  @callback picker_set(LiveView.Socket.t(), [{String.t(), String.t()}]) :: LiveView.Socket.t()
  @optional_callbacks picker_set: 2

  @home_size 5
  @page_size 20

  # ── State ──────────────────────────────────────────────────────────

  @doc """
  The picker's assigns for a project (nil: no project, e.g. the task
  library): the viewer's staff person, the Recent chips and whether they may
  assign (`opts[:can_assign?]`, default true). `opts[:source]` names the
  form in the log line of a staff record made from it.
  """
  @spec init(LiveView.Socket.t(), map() | nil, keyword()) :: LiveView.Socket.t()
  def init(socket, project, opts \\ []) do
    project_uuid =
      case project do
        %{uuid: uuid} when is_binary(uuid) and uuid != "" -> uuid
        _ -> nil
      end

    socket
    |> Phoenix.Component.assign(
      assignee_project_uuid: project_uuid,
      assignee_source: Keyword.get(opts, :source, "task_form"),
      my_person_uuid: my_person_uuid(socket),
      can_assign?: Keyword.get(opts, :can_assign?, true)
    )
    |> refresh_recent()
    |> Phoenix.Component.assign_new(:staff_confirm, fn -> nil end)
    |> Phoenix.Component.assign_new(:assignee_notice, fn -> nil end)
    |> Phoenix.Component.assign_new(:assignee_chip, fn -> %{key: nil, row: nil} end)
    |> init_multi(Keyword.get(opts, :multi, false))
  end

  # Both modes open the same dropdown (the boss, 2026-11-02: one picker);
  # only what a pick does differs.
  defp init_multi(socket, multi?) do
    socket
    |> Phoenix.Component.assign(
      assignee_multi?: multi?,
      assignee_open?: false,
      assignee_selected: socket.assigns[:assignee_selected] || [],
      assignee_rows: socket.assigns[:assignee_rows] || %{},
      assignee_view: :home,
      assignee_cursor: nil,
      assignee_seen: %{}
    )
    |> LiveView.stream(:assignee_options, [], reset: true)
    |> load_home()
  end

  # The opening lists: five of each kind and whether there are more.
  defp load_home(socket) do
    lang = L10n.current_content_lang()

    home =
      Map.new(~w(team department person), fn kind ->
        {rows, next} = Assignees.page({:browse, kind}, nil, @home_size, lang)
        {kind, %{rows: rows, more?: not is_nil(next)}}
      end)

    Phoenix.Component.assign(socket, :assignee_home, home)
  end

  @doc """
  The ticked assignees (`[{kind, uuid}]`) as the form holds them: the
  chips' rows are looked up for the ones not seen before.
  """
  @spec set_selected(LiveView.Socket.t(), [{String.t(), String.t()}]) :: LiveView.Socket.t()
  def set_selected(socket, keys) when is_list(keys) do
    was = socket.assigns[:assignee_selected] || []
    cache = socket.assigns[:assignee_rows] || %{}
    lang = L10n.current_content_lang()

    cache =
      Enum.reduce(keys, cache, fn {kind, uuid} = key, acc ->
        if Map.has_key?(acc, key),
          do: acc,
          else: Map.put(acc, key, Assignees.describe(kind, uuid, lang))
      end)

    socket
    |> Phoenix.Component.assign(assignee_selected: keys, assignee_rows: cache)
    |> redraw((keys -- was) ++ (was -- keys))
  end

  # The rows of these keys in the open list, inserted again so their tick
  # follows (a stream keeps no assigns of its own).
  defp redraw(socket, []), do: socket

  defp redraw(socket, keys) do
    seen = socket.assigns[:assignee_seen] || %{}

    keys
    |> Enum.flat_map(&Map.get(seen, &1, []))
    |> Enum.reduce(socket, &LiveView.stream_insert(&2, :assignee_options, &1))
  end

  @doc "Re-reads the Recent chips (after a pick, they lead with it)."
  @spec refresh_recent(LiveView.Socket.t()) :: LiveView.Socket.t()
  def refresh_recent(socket) do
    recent =
      Assignees.recent_for_viewer(
        Activity.actor_uuid(socket),
        socket.assigns[:assignee_project_uuid],
        8,
        L10n.current_content_lang()
      )

    Phoenix.Component.assign(socket, :recent_assignees, recent)
  end

  @doc """
  The chip of the chosen assignee (`{kind, uuid}` or nil): its row and
  faces, looked up only when the choice changed.
  """
  @spec refresh_chip(LiveView.Socket.t(), {String.t(), String.t()} | nil) :: LiveView.Socket.t()
  def refresh_chip(socket, key) do
    case socket.assigns[:assignee_chip] do
      %{key: ^key, row: row} when not is_nil(row) or is_nil(key) ->
        socket

      _ ->
        row =
          case key do
            {kind, uuid} -> Assignees.describe(kind, uuid, L10n.current_content_lang())
            nil -> nil
          end

        Phoenix.Component.assign(socket, :assignee_chip, %{key: key, row: row})
    end
  end

  @doc """
  `{kind, uuid}` of the assignee three uuid fields hold — the first set of
  person, team, department — or nil. `get` reads one field (`:person` …).
  """
  @spec key_of((atom() -> term())) :: {String.t(), String.t()} | nil
  def key_of(get) when is_function(get, 1) do
    Enum.find_value([person: "person", team: "team", department: "department"], fn {f, kind} ->
      case get.(f) do
        uuid when is_binary(uuid) and uuid != "" -> {kind, uuid}
        _ -> nil
      end
    end)
  end

  @doc """
  The three assignee fields for one choice, under the names `names` gives
  (`%{person: "assigned_person_uuid", …}`): exactly one set.
  """
  @spec field_attrs(map(), String.t() | nil, String.t() | nil) :: map()
  def field_attrs(names, kind, uuid) do
    Map.new([person: "person", team: "team", department: "department"], fn {f, k} ->
      {Map.fetch!(names, f), if(k == kind, do: uuid)}
    end)
  end

  # ── Events ─────────────────────────────────────────────────────────

  @doc """
  One picker event. `mod` is the LiveView: its `picker_allowed?/1` is asked
  before anything is chosen, and `picker_choose/3` puts the choice in its
  form. A pick names a row the search offered and is looked up again, so a
  forged kind or uuid assigns nobody.
  """
  @spec handle_event(String.t(), map(), LiveView.Socket.t(), module()) ::
          {:noreply, LiveView.Socket.t()}
  def handle_event("assignee_search", %{"q" => q} = params, socket, _mod) when is_binary(q) do
    limit =
      case Integer.parse(to_string(params["limit"] || "")) do
        {n, _} when n > 0 -> n
        _ -> 20
      end

    {rows, more?} = Assignees.search_assignees(q, limit, L10n.current_content_lang())
    rows = Enum.map(rows, &Map.take(&1, [:kind, :uuid, :label, :sublabel, :icon]))

    {:noreply,
     LiveView.push_event(socket, "assignee_results", %{q: q, results: rows, has_more: more?})}
  end

  def handle_event("assignee_search", _params, socket, _mod), do: {:noreply, socket}

  # A user with no staff person yet: assigning them makes one, so it asks
  # first (`staff_confirm`).
  def handle_event("assignee_pick", %{"kind" => "user", "uuid" => uuid}, socket, mod) do
    {:noreply,
     socket |> assign_user(uuid, :other, mod) |> LiveView.push_event("assignee_staged", %{})}
  end

  def handle_event("assignee_pick", %{"kind" => kind, "uuid" => uuid}, socket, mod) do
    socket =
      case Assignees.describe(kind, uuid) do
        %{kind: kind, uuid: uuid} -> choose(socket, kind, uuid, mod)
        nil -> socket
      end

    {:noreply, LiveView.push_event(socket, "assignee_staged", %{})}
  end

  def handle_event("assignee_recent", %{"kind" => kind, "uuid" => uuid}, socket, mod) do
    offered? =
      Enum.any?(socket.assigns[:recent_assignees] || [], &(&1.kind == kind and &1.uuid == uuid))

    {:noreply, if(offered?, do: choose(socket, kind, uuid, mod), else: socket)}
  end

  # The viewer themself — their staff person, made (after asking) when their
  # account has none.
  def handle_event("assign_to_me", _params, socket, mod) do
    case Activity.actor_uuid(socket) do
      uuid when is_binary(uuid) -> {:noreply, assign_user(socket, uuid, :self, mod)}
      _ -> {:noreply, socket}
    end
  end

  # "Create and assign": the question holds the user, re-checked here.
  def handle_event("staff_create_confirm", _params, socket, mod) do
    case socket.assigns[:staff_confirm] do
      %{user_uuid: user_uuid, who: who} ->
        socket = Phoenix.Component.assign(socket, :staff_confirm, nil)

        if mod.picker_allowed?(socket),
          do: {:noreply, create_and_assign(socket, user_uuid, who, mod)},
          else: {:noreply, socket}

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event("staff_create_cancel", _params, socket, _mod),
    do: {:noreply, Phoenix.Component.assign(socket, :staff_confirm, nil)}

  # The search box's own form: Enter there must submit nothing.
  def handle_event("assignee_noop", _params, socket, _mod), do: {:noreply, socket}

  def handle_event("assignee_clear", _params, %{assigns: %{assignee_multi?: true}} = socket, mod) do
    if mod.picker_allowed?(socket),
      do:
        {:noreply, socket |> Phoenix.Component.assign(:assignee_notice, nil) |> set_keys([], mod)},
      else: {:noreply, socket}
  end

  def handle_event("assignee_clear", _params, socket, mod) do
    if mod.picker_allowed?(socket),
      do:
        {:noreply,
         socket |> Phoenix.Component.assign(:assignee_notice, nil) |> mod.picker_choose(nil, nil)},
      else: {:noreply, socket}
  end

  # ── Several assignees ──────────────────────────────────────────────

  # A tick: on when it was off, off when it was on. A pick names a row the
  # lists offered and is looked up again (`describe`), so a forged kind or
  # uuid ticks nobody; an account without a staff record asks first.
  def handle_event("assignee_toggle", %{"kind" => "user", "uuid" => uuid}, socket, mod) do
    {:noreply, socket |> close_if_single() |> assign_user(uuid, :other, mod)}
  end

  # One assignee: a pick replaces it and the dropdown closes.
  def handle_event(
        "assignee_toggle",
        %{"kind" => kind, "uuid" => uuid},
        %{assigns: %{assignee_multi?: false}} = socket,
        mod
      ) do
    case Assignees.describe(kind, uuid) do
      %{kind: kind, uuid: uuid} ->
        {:noreply, socket |> choose(kind, uuid, mod) |> close_if_single()}

      nil ->
        {:noreply, socket}
    end
  end

  def handle_event("assignee_toggle", %{"kind" => kind, "uuid" => uuid}, socket, mod) do
    keys = socket.assigns[:assignee_selected] || []

    cond do
      not mod.picker_allowed?(socket) ->
        {:noreply, socket}

      {kind, uuid} in keys ->
        {:noreply, set_keys(socket, List.delete(keys, {kind, uuid}), mod)}

      true ->
        case Assignees.describe(kind, uuid) do
          %{kind: kind, uuid: uuid} -> {:noreply, choose(socket, kind, uuid, mod)}
          nil -> {:noreply, socket}
        end
    end
  end

  def handle_event("assignee_remove", %{"kind" => kind, "uuid" => uuid}, socket, mod) do
    keys = socket.assigns[:assignee_selected] || []

    if mod.picker_allowed?(socket) and {kind, uuid} in keys,
      do: {:noreply, set_keys(socket, List.delete(keys, {kind, uuid}), mod)},
      else: {:noreply, socket}
  end

  def handle_event("assignee_browse", %{"kind" => kind}, socket, _mod)
      when kind in ~w(team department person),
      do: {:noreply, open_list(socket, {:browse, kind})}

  def handle_event("assignee_back", _params, socket, _mod),
    do: {:noreply, open_list(socket, :home)}

  def handle_event("assignee_query", %{"assignee_q" => q}, socket, _mod) when is_binary(q) do
    socket = Phoenix.Component.assign(socket, :assignee_open?, true)

    case String.trim(q) do
      "" -> {:noreply, open_list(socket, :home)}
      text -> {:noreply, open_list(socket, {:search, String.slice(text, 0, 100)})}
    end
  end

  # The dropdown under the search field: opened by focusing it, closed by
  # a click elsewhere. Closing only hides it — the list, its page and its
  # scroll stay as they were (the panel, 2026-11-02).
  def handle_event("assignee_open", _params, socket, _mod),
    do: {:noreply, Phoenix.Component.assign(socket, :assignee_open?, true)}

  def handle_event("assignee_close", _params, socket, _mod),
    do: {:noreply, Phoenix.Component.assign(socket, :assignee_open?, false)}

  # The list's bottom came into view: the next page, once, for the list
  # that asked (a page for a list since left is dropped).
  def handle_event("assignee_more", _params, socket, _mod) do
    case {socket.assigns[:assignee_view], socket.assigns[:assignee_cursor]} do
      {{_, _} = view, cursor} when not is_nil(cursor) ->
        {:noreply, load_page(socket, view, cursor)}

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event(_event, _params, socket, _mod), do: {:noreply, socket}

  defp close_if_single(%{assigns: %{assignee_multi?: false}} = socket),
    do: Phoenix.Component.assign(socket, :assignee_open?, false)

  defp close_if_single(socket), do: socket

  defp open_list(socket, :home) do
    socket
    |> Phoenix.Component.assign(
      assignee_view: :home,
      assignee_cursor: nil,
      assignee_seen: %{}
    )
    |> LiveView.stream(:assignee_options, [], reset: true)
  end

  defp open_list(socket, view) do
    socket
    |> Phoenix.Component.assign(
      assignee_view: view,
      assignee_cursor: nil,
      assignee_seen: %{}
    )
    |> LiveView.stream(:assignee_options, [], reset: true)
    |> load_page(view, nil)
  end

  defp load_page(socket, view, cursor) do
    {rows, next} = Assignees.page(view, cursor, @page_size, L10n.current_content_lang())

    seen =
      Enum.reduce(rows, socket.assigns[:assignee_seen] || %{}, fn row, acc ->
        Map.update(acc, {row.kind, row.uuid}, [row], &(&1 ++ [row]))
      end)

    socket
    |> Phoenix.Component.assign(assignee_cursor: next, assignee_seen: seen)
    |> LiveView.stream(:assignee_options, rows)
  end

  # A choice the viewer made: put in the form, and remembered as theirs
  # for the Recent chips.
  defp choose(socket, kind, uuid, mod) do
    if mod.picker_allowed?(socket) do
      Assignees.remember_pick(Activity.actor_uuid(socket), kind, uuid)

      socket
      |> Phoenix.Component.assign(:assignee_notice, nil)
      |> put_choice(kind, uuid, mod)
      |> refresh_recent()
    else
      socket
    end
  end

  # One assignee: the choice replaces it. Several: it is added (ticked).
  defp put_choice(%{assigns: %{assignee_multi?: true}} = socket, kind, uuid, mod) do
    keys = socket.assigns.assignee_selected
    if {kind, uuid} in keys, do: socket, else: set_keys(socket, keys ++ [{kind, uuid}], mod)
  end

  defp put_choice(socket, kind, uuid, mod), do: mod.picker_choose(socket, kind, uuid)

  defp set_keys(socket, keys, mod) do
    socket |> set_selected(keys) |> mod.picker_set(keys)
  end

  # Assigns a user through their staff person: straight away when they
  # have one; asking first when assigning would create it; refused, with a
  # line saying where to restore it, when it is trashed. `who` is `:self`
  # (Assign to me) or `:other` (a picked user, looked up again).
  defp assign_user(socket, user_uuid, who, mod) do
    if mod.picker_allowed?(socket) do
      case People.get_person_by_user_uuid(user_uuid) do
        %{status: "trashed"} ->
          Phoenix.Component.assign(socket, :assignee_notice, {:trashed, who})

        %{uuid: person_uuid} ->
          choose(socket, "person", person_uuid, mod)

        nil ->
          ask_staff_create(socket, user_uuid, who)
      end
    else
      socket
    end
  end

  defp ask_staff_create(socket, user_uuid, who) do
    name =
      case who do
        :self -> self_name(socket, user_uuid)
        :other -> with %{label: label} <- Assignees.describe_user(user_uuid), do: label
      end

    if is_binary(name),
      do:
        Phoenix.Component.assign(socket, :staff_confirm, %{
          user_uuid: user_uuid,
          who: who,
          name: name
        }),
      else: socket
  end

  defp self_name(socket, user_uuid) do
    case Activity.actor_uuid(socket) == user_uuid && Auth.get_user(user_uuid) do
      %User{} = user -> if People.assignable_user?(user), do: People.new_person_name(user)
      _ -> nil
    end
  end

  defp create_and_assign(socket, user_uuid, who, mod) do
    case People.ensure_person_for_user(user_uuid,
           actor_uuid: Activity.actor_uuid(socket),
           source: socket.assigns[:assignee_source] || "task_form"
         ) do
      {:ok, %{uuid: person_uuid}} ->
        socket
        |> then(
          &if(who == :self,
            do: Phoenix.Component.assign(&1, :my_person_uuid, person_uuid),
            else: &1
          )
        )
        |> choose("person", person_uuid, mod)

      {:error, :trashed_person} ->
        Phoenix.Component.assign(socket, :assignee_notice, {:trashed, who})

      {:error, _} ->
        LiveView.put_flash(socket, :error, gettext("Could not create the staff record."))
    end
  end

  # The viewer's own staff person — what "Assign to me" assigns — or nil
  # (nil also when it is trashed: then there is no one to assign as them).
  defp my_person_uuid(socket) do
    with uuid when is_binary(uuid) <- Activity.actor_uuid(socket),
         %{uuid: person_uuid, status: status} when status != "trashed" <-
           People.get_person_by_user_uuid(uuid) do
      person_uuid
    else
      _ -> nil
    end
  rescue
    _ -> nil
  end

  # ── The component ──────────────────────────────────────────────────

  @doc """
  The picker, inside the form it fills. `fields` are the hidden inputs that
  carry the choice (`[{name, value}]`, the record's three assignee fields);
  `search_form` is the id of the empty form that owns the search box
  (`assignee_picker_outside/1`), so Enter there never submits the form.
  """
  attr(:id, :string, required: true)
  attr(:label, :string, default: nil)
  attr(:fields, :list, default: [])
  attr(:chip, :map, required: true)
  attr(:can_assign?, :boolean, default: true)
  attr(:my_person_uuid, :string, default: nil)
  attr(:recent, :list, default: [])
  attr(:notice, :any, default: nil)
  attr(:search_form, :string, required: true)
  attr(:me_id, :string, default: nil)

  attr(:kind_name, :string,
    default: "assign_type",
    doc: "the hidden input naming the kind chosen"
  )

  attr(:view, :any, default: :home)
  attr(:home, :map, default: %{})
  attr(:more?, :boolean, default: false)
  attr(:open?, :boolean, default: false)
  attr(:streams, :any, required: true)
  attr(:class, :any, default: nil)

  def assignee_picker(assigns) do
    key = assigns.chip.key

    assigns =
      assign(assigns,
        me_id: assigns.me_id || "#{assigns.id}-me",
        kind: kind_of(assigns.chip),
        selected: if(key, do: [key], else: []),
        rows: if(key, do: %{key => assigns.chip.row}, else: %{})
      )

    ~H"""
    <div id={@id} class={["flex flex-col gap-2", @class]} data-kind={@kind}>
      <input type="hidden" name={@kind_name} value={@kind} />
      <input :for={{name, value} <- @fields} type="hidden" name={name} value={value} />
      <.picker_body {assigns} multi?={false} remove_event="assignee_clear" />
    </div>
    """
  end

  @doc """
  The several-assignee picker (`init(…, multi: true)`), inside the form it
  fills: `name` is the list field the choice posts under
  (`"assignment[assignees][]"`, one `kind:uuid` each, after an empty one
  so a cleared list still posts). The search box belongs to `search_form`
  (`assignee_picker_outside/1`), which sends `assignee_query` as it is
  typed. `streams` is the LiveView's `@streams`.
  """
  attr(:id, :string, required: true)
  attr(:label, :string, default: nil)
  attr(:name, :string, required: true)
  attr(:selected, :list, required: true)
  attr(:rows, :map, default: %{})
  attr(:view, :any, default: :home)
  attr(:home, :map, default: %{})
  attr(:more?, :boolean, default: false)
  attr(:open?, :boolean, default: false)
  attr(:streams, :any, required: true)
  attr(:can_assign?, :boolean, default: true)
  attr(:my_person_uuid, :string, default: nil)
  attr(:recent, :list, default: [])
  attr(:notice, :any, default: nil)
  attr(:search_form, :string, required: true)
  attr(:me_id, :string, default: nil)
  attr(:class, :any, default: nil)

  def assignee_multi_picker(assigns) do
    assigns = assign(assigns, me_id: assigns.me_id || "#{assigns.id}-me")

    ~H"""
    <div id={@id} class={["flex flex-col gap-2", @class]} data-count={length(@selected)}>
      <input type="hidden" name={@name} value="" />
      <input :for={{kind, uuid} <- @selected} type="hidden" name={@name} value={"#{kind}:#{uuid}"} />
      <.picker_body {assigns} multi?={true} remove_event="assignee_remove" />
    </div>
    """
  end

  # What both modes draw (the boss, 2026-11-02 — one picker, as it looked
  # before the several-assignee change): who it is for as cards; the search
  # field, whose dropdown holds the grouped lists and the search results;
  # the Recent chips under it, one press each.
  defp picker_body(assigns) do
    assigns =
      assign(assigns,
        me?: {"person", assigns.my_person_uuid} in assigns.selected,
        recent_shown: Enum.reject(assigns.recent, &({&1.kind, &1.uuid} in assigns.selected)),
        list_title: list_title(assigns.view)
      )

    ~H"""
    <div class="flex items-center justify-between gap-2">
      <label :if={@label} for={"#{@id}-q"} class="text-sm font-semibold">{@label}</label>
      <%!-- Works for any account: one with no staff person gets one
           made, after the form asks (`staff_confirm`). --%>
      <button
        :if={@can_assign? and not @me?}
        type="button"
        id={@me_id}
        phx-click="assign_to_me"
        class="btn btn-xs btn-outline gap-1 ml-auto"
      >
        <.icon name="hero-user-plus" class="w-3.5 h-3.5" /> {gettext("Assign to me")}
      </button>
    </div>
    <p :if={@can_assign? and match?({:trashed, _}, @notice)} id={"#{@id}-notice"} class="text-xs text-warning">
      <%= if @notice == {:trashed, :self} do %>
        {gettext("Your staff record is in the trash; restore it under Staff → People to be assigned.")}
      <% else %>
        {gettext("Their staff record is in the trash; restore it under Staff → People to assign them.")}
      <% end %>
    </p>

    <%!-- Who it is for: a card each, in the order they were added. --%>
    <div :if={@selected != []} id={"#{@id}-chips"} class="flex flex-wrap gap-2">
      <div
        :for={{kind, uuid} = key <- @selected}
        id={"#{@id}-chip-#{kind}-#{uuid}"}
        data-kind={kind}
        class="flex items-center gap-2 rounded-box border border-base-300 py-1.5 pl-2 pr-1 min-w-0 max-w-full"
      >
        <% row = Map.get(@rows, key) %>
        <%= if row && row[:faces] do %>
          <.assignee_faces faces={row.faces} size="sm" />
        <% else %>
          <span class="inline-flex items-center justify-center w-8 h-8 rounded-full bg-base-200 shrink-0">
            <.icon name={(row && row.icon) || "hero-user"} class="w-4 h-4 text-base-content/60" />
          </span>
        <% end %>
        <div class="min-w-0">
          <div class="truncate font-medium text-sm">{(row && row.label) || gettext("No longer listed")}</div>
          <div :if={row && row[:sublabel]} class="truncate text-xs text-base-content/60">{row.sublabel}</div>
        </div>
        <button
          :if={@can_assign?}
          type="button"
          id={"#{@id}-clear-#{kind}-#{uuid}"}
          phx-click={@remove_event}
          phx-value-kind={kind}
          phx-value-uuid={uuid}
          class="btn btn-ghost btn-xs btn-circle shrink-0"
          aria-label={gettext("Remove %{name}", name: (row && row.label) || "")}
          title={gettext("Remove %{name}", name: (row && row.label) || "")}
        >
          <.icon name="hero-x-mark" class="w-4 h-4" />
        </button>
      </div>
    </div>
    <p :if={@selected == [] and not @can_assign?} class="text-sm text-base-content/60">
      {gettext("Unassigned")}
    </p>

    <div :if={@can_assign?} id={"#{@id}-search"} phx-click-away={@open? && "assignee_close"}>
      <label class="input input-sm w-full flex items-center gap-2">
        <.icon name="hero-magnifying-glass" class="w-4 h-4 opacity-60" />
        <input
          id={"#{@id}-q"}
          type="search"
          name="assignee_q"
          form={@search_form}
          phx-debounce="250"
          phx-focus="assignee_open"
          autocomplete="off"
          aria-expanded={to_string(@open?)}
          aria-controls={"#{@id}-list"}
          placeholder={gettext("Search a person, team or department")}
          class="grow"
        />
      </label>

      <%!-- Under the field, in the flow (an absolute one is clipped by a
           popup's scroll area). Hidden when closed, never removed: the
           list, its page and its scroll stay. --%>
      <div
        id={"#{@id}-list"}
        role="listbox"
        class={[
          "mt-1 max-h-72 overflow-y-auto overscroll-contain p-1 rounded-box border border-base-300 bg-base-100 shadow-sm",
          not @open? && "hidden"
        ]}
      >
        <%= if @view == :home do %>
          <.option_section
            :for={{kind, title} <- [{"team", gettext("Teams")}, {"department", gettext("Departments")}, {"person", gettext("People")}]}
            :if={match?(%{rows: [_ | _]}, @home[kind])}
            id={"#{@id}-home-#{kind}"}
            title={title}
            rows={@home[kind].rows}
            selected={@selected}
            more_kind={@home[kind].more? && kind}
          />
        <% else %>
          <div class="flex items-center gap-2 px-1 py-1">
            <button
              :if={match?({:browse, _}, @view)}
              type="button"
              phx-click="assignee_back"
              id={"#{@id}-back"}
              class="btn btn-ghost btn-xs gap-1"
            >
              <.icon name="hero-chevron-left" class="w-3.5 h-3.5" /> {gettext("Back")}
            </button>
            <span class="text-xs font-semibold uppercase tracking-wide text-base-content/60">{@list_title}</span>
          </div>
          <ul
            id={"#{@id}-options"}
            phx-update="stream"
            phx-viewport-bottom={@more? && "assignee_more"}
            class="flex flex-col"
          >
            <li
              :for={{dom_id, row} <- @streams.assignee_options}
              id={dom_id}
              class={[member?(row) && "pl-4"]}
            >
              <.option_row row={row} selected={@selected} />
            </li>
            <li id={"#{@id}-options-empty"} class="hidden only:block px-2 py-2 text-sm text-base-content/60">
              {gettext("No matches")}
            </li>
          </ul>
        <% end %>
      </div>
    </div>

    <%!-- The viewer's own recent picks, as before: one press adds one. --%>
    <div :if={@can_assign? and @recent_shown != []} id={"#{@id}-recent"} class="flex flex-wrap items-center gap-1.5">
      <span class="text-xs text-base-content/60">{gettext("Recent:")}</span>
      <button
        :for={r <- @recent_shown}
        type="button"
        phx-click="assignee_recent"
        phx-value-kind={r.kind}
        phx-value-uuid={r.uuid}
        class="btn btn-xs btn-ghost border-base-300 gap-1 font-normal"
        title={r.sublabel || r.label}
      >
        <.icon name={r.icon} class="w-3.5 h-3.5 opacity-60" />{r.label}
      </button>
    </div>
    """
  end

  attr(:id, :string, required: true)
  attr(:title, :string, required: true)
  attr(:rows, :list, required: true)
  attr(:selected, :list, required: true)
  attr(:more_kind, :any, default: nil)

  defp option_section(assigns) do
    ~H"""
    <section id={@id} class="mb-1">
      <h4 class="px-2 pt-1 pb-0.5 text-xs font-semibold uppercase tracking-wide text-base-content/60">
        {@title}
      </h4>
      <ul class="flex flex-col">
        <li :for={row <- @rows}><.option_row row={row} selected={@selected} /></li>
      </ul>
      <button
        :if={@more_kind}
        type="button"
        id={"#{@id}-more"}
        phx-click="assignee_browse"
        phx-value-kind={@more_kind}
        class="btn btn-ghost btn-xs w-full justify-start gap-1 font-normal text-primary"
      >
        {gettext("Browse more")} <.icon name="hero-chevron-right" class="w-3.5 h-3.5" />
      </button>
    </section>
    """
  end

  attr(:row, :map, required: true)
  attr(:selected, :list, required: true)

  # One option: a press adds it (several) or makes it the one (one); a
  # chosen one carries a tick at its end, no checkbox (the boss).
  defp option_row(assigns) do
    assigns = assign(assigns, :on?, {assigns.row.kind, assigns.row.uuid} in assigns.selected)

    ~H"""
    <button
      type="button"
      role="option"
      aria-selected={to_string(@on?)}
      phx-click="assignee_toggle"
      phx-value-kind={@row.kind}
      phx-value-uuid={@row.uuid}
      data-assignee={"#{@row.kind}:#{@row.uuid}"}
      class={["flex w-full items-center gap-2 rounded px-2 py-1 text-left hover:bg-base-200", @on? && "bg-primary/5"]}
    >
      <.icon name={@row[:icon] || "hero-user"} class="w-4 h-4 shrink-0 opacity-60" />
      <span class="min-w-0 flex-1">
        <span class="block truncate text-sm">{@row.label}</span>
        <span :if={@row[:sublabel]} class="block truncate text-xs text-base-content/60">{@row.sublabel}</span>
      </span>
      <.icon :if={@on?} name="hero-check" class="w-4 h-4 shrink-0 text-primary" />
    </button>
    """
  end

  defp member?(%{id: id}) when is_binary(id), do: String.contains?(id, "-person-")
  defp member?(_), do: false

  defp list_title({:browse, "team"}), do: gettext("Teams")
  defp list_title({:browse, "department"}), do: gettext("Departments")
  defp list_title({:browse, "person"}), do: gettext("People")
  defp list_title({:search, _}), do: gettext("Search results")
  defp list_title(_), do: nil

  @doc """
  What the picker needs outside the form it sits in: the empty form that
  owns its search box, and the "Create a staff record?" question.
  """
  attr(:search_form, :string, required: true)
  attr(:staff_confirm, :any, default: nil)

  def assignee_picker_outside(assigns) do
    ~H"""
    <form id={@search_form} phx-submit="assignee_noop" phx-change="assignee_query" class="hidden"></form>
    <%!-- In the drawer this dialog sits inside the drawer's own dialog,
         and daisyUI's `modal-end` makes every modal box under it full
         height (a descendant rule); a confirm keeps its own height. --%>
    <style :if={@staff_confirm}>
      #pk-modal-staff_create_cancel > .modal-box { height: auto; }
    </style>
    <.confirm_modal
      :if={@staff_confirm}
      show={true}
      on_confirm="staff_create_confirm"
      on_cancel="staff_create_cancel"
      title={gettext("Create a staff record?")}
      title_icon="hero-user-plus"
      messages={[
        {:info,
         gettext(
           "%{name} has no staff record yet. Assigning creates one (Staff → People) with their name and account; you can fill it in or remove it there later.",
           name: @staff_confirm.name
         )}
      ]}
      prompt=""
      cancel_text={gettext("Cancel")}
      confirm_text={gettext("Create and assign")}
    />
    """
  end

  defp kind_of(%{key: {kind, _uuid}}), do: kind
  defp kind_of(_chip), do: ""
end
