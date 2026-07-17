defmodule PhoenixKitProjects.Web.AssigneeFilter do
  @moduledoc """
  Shared state glue for the calendar assignee/overdue filter — the chip-rail
  model (person chips via the core search_picker, a Me quick-toggle, an
  Unassigned lens, Personal-only and Overdue-only refinements, one Clear).

  Two LiveViews consume it (the Overview Tasks calendar and the per-project
  Calendar tab), each with its own item semantics — the Overview filters
  flattened leaf tasks, the project tab filters top-level bars with
  descendant-aware matching. This module owns everything that must NOT drift
  between them: the assigns, the event handling (including the picker's
  search/pick/staged contract), scope resolution, and union matching.

  ## Usage

      # mount
      socket = socket |> assign(AssigneeFilter.defaults()) |> ...

      # one handle_event clause forwards every filter event
      def handle_event(event, params, socket) when event in @assignee_filter_events do
        case AssigneeFilter.update(socket, event, params) do
          {socket, :reapply} -> {:noreply, apply_my_filter(socket)}
          {socket, :noop} -> {:noreply, socket}
        end
      end

  with `@assignee_filter_events AssigneeFilter.events()`. The panel UI lives
  in `<.assignee_filter_panel>` (`Web.Components.AssigneeFilterPanel`).
  """

  import Phoenix.Component, only: [assign: 2]
  import Phoenix.LiveView, only: [push_event: 3]

  alias PhoenixKitProjects.{Activity, Assignees, L10n}

  @events ~w(clear_assignee_filter toggle_me_chip toggle_unassigned assignee_search
             assignee_pick remove_assignee_person toggle_assignee_direct toggle_overdue_only)

  @doc "The filter's event names — guard the forwarding handle_event clause with these."
  @spec events() :: [String.t()]
  def events, do: @events

  @doc "Default assigns for a consuming LiveView's mount."
  @spec defaults() :: keyword()
  def defaults do
    [
      assignee_selected: [],
      assignee_scopes: %{},
      include_unassigned?: false,
      assignee_direct_only?: false,
      overdue_only?: false,
      me_scope: :unresolved,
      unassigned_count: 0
    ]
  end

  @doc """
  Resolves the viewer's own scope once per mount (`:unresolved` → scope | nil).
  Call from the consumer's data-load path; nil hides the Me quick-adder.
  """
  @spec resolve_me(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def resolve_me(%{assigns: %{me_scope: :unresolved}} = socket) do
    me =
      Assignees.scope_for_user(Activity.actor_uuid(socket), L10n.current_content_lang())

    assign(socket, me_scope: me)
  end

  def resolve_me(socket), do: socket

  @doc """
  Applies one filter event to the socket. Returns `{socket, :reapply}` when
  the consumer must re-derive its filtered view, `{socket, :noop}` otherwise
  (picker searches answer via push_event and change nothing else).
  """
  @spec update(Phoenix.LiveView.Socket.t(), String.t(), map()) ::
          {Phoenix.LiveView.Socket.t(), :reapply | :noop}
  def update(socket, "clear_assignee_filter", _params) do
    {assign(socket,
       assignee_selected: [],
       assignee_scopes: %{},
       include_unassigned?: false,
       overdue_only?: false,
       assignee_direct_only?: false
     ), :reapply}
  end

  def update(socket, "toggle_me_chip", _params) do
    case socket.assigns.me_scope do
      %{person_uuid: uuid, person_name: name} = scope ->
        if Enum.any?(socket.assigns.assignee_selected, &(&1.uuid == uuid)) do
          {remove_chip(socket, uuid), :reapply}
        else
          {add_chip(socket, uuid, name, scope), :reapply}
        end

      _ ->
        {socket, :noop}
    end
  end

  def update(socket, "toggle_unassigned", _params) do
    {assign(socket, include_unassigned?: not socket.assigns.include_unassigned?), :reapply}
  end

  def update(socket, "toggle_assignee_direct", _params) do
    {assign(socket, assignee_direct_only?: not socket.assigns.assignee_direct_only?), :reapply}
  end

  def update(socket, "toggle_overdue_only", _params) do
    {assign(socket, overdue_only?: not socket.assigns.overdue_only?), :reapply}
  end

  def update(socket, "assignee_search", %{"q" => q} = params) do
    limit =
      case params["limit"] do
        n when is_integer(n) and n > 0 ->
          n

        n when is_binary(n) ->
          case Integer.parse(n) do
            {i, _} -> max(i, 1)
            :error -> 8
          end

        _ ->
          8
      end

    # Already-picked people don't reappear as suggestions.
    exclude = Enum.map(socket.assigns.assignee_selected, & &1.uuid)
    {rows, has_more} = Assignees.search_people(q, limit, exclude: exclude)

    {push_event(socket, "assignee_results", %{q: q, results: rows, has_more: has_more}), :noop}
  end

  def update(socket, "assignee_pick", %{"uuid" => uuid}) when is_binary(uuid) do
    already? = Enum.any?(socket.assigns.assignee_selected, &(&1.uuid == uuid))

    case if(already?,
           do: :duplicate,
           else: Assignees.scope_for_person(uuid, L10n.current_content_lang())
         ) do
      nil ->
        {socket, :noop}

      :duplicate ->
        # Still confirm so the picker hook clears the input.
        {push_event(socket, "assignee_staged", %{}), :noop}

      scope ->
        {socket
         |> add_chip(uuid, scope.person_name, scope)
         |> push_event("assignee_staged", %{}), :reapply}
    end
  end

  def update(socket, "remove_assignee_person", %{"uuid" => uuid}) when is_binary(uuid) do
    {remove_chip(socket, uuid), :reapply}
  end

  def update(socket, _event, _params), do: {socket, :noop}

  @doc "The resolved scopes of the picked person chips."
  @spec current_scopes(map()) :: [Assignees.scope()]
  def current_scopes(assigns) do
    assigns.assignee_selected
    |> Enum.map(&Map.get(assigns.assignee_scopes, &1.uuid))
    |> Enum.reject(&is_nil/1)
  end

  @doc """
  Matches one assignment against every selected scope; a `:direct` hit for
  anyone wins (so direct-only keeps a task any selected person holds
  personally), otherwise the first inherited provenance labels the row.
  """
  @spec match_any(struct(), [Assignees.scope()]) ::
          :direct | {:team, String.t()} | {:department, String.t()} | nil
  def match_any(assignment, scopes) do
    Enum.reduce_while(scopes, nil, fn scope, acc ->
      case Assignees.match(assignment, scope) do
        nil -> {:cont, acc}
        :direct -> {:halt, :direct}
        via -> {:cont, acc || via}
      end
    end)
  end

  @doc "How many filters are active — badges the funnel button."
  @spec active_count(map()) :: non_neg_integer()
  def active_count(assigns) do
    length(assigns.assignee_selected) +
      if(assigns.include_unassigned?, do: 1, else: 0) +
      if(assigns.overdue_only?, do: 1, else: 0) +
      if(assigns.assignee_direct_only? and assigns.assignee_selected != [], do: 1, else: 0)
  end

  defp add_chip(socket, uuid, name, scope) do
    assign(socket,
      assignee_selected: socket.assigns.assignee_selected ++ [%{uuid: uuid, name: name}],
      assignee_scopes: Map.put(socket.assigns.assignee_scopes, uuid, scope)
    )
  end

  defp remove_chip(socket, uuid) do
    assign(socket,
      assignee_selected: Enum.reject(socket.assigns.assignee_selected, &(&1.uuid == uuid)),
      assignee_scopes: Map.delete(socket.assigns.assignee_scopes, uuid)
    )
  end
end
