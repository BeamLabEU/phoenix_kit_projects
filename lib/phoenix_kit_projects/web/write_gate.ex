defmodule PhoenixKitProjects.Web.WriteGate do
  @moduledoc """
  Re-checks a form's write right on every write event, against the scope
  the socket holds when the event arrives.

  A form checked once at mount keeps its page open after a role loses the
  grant (core swaps the narrower scope in, but nothing re-asks), so a save
  sent after the revoke would still write. A form declares
  `on_mount(PhoenixKitProjects.Web.WriteGate)` and exports:

    * `write_events/0` — the event names that write;
    * `write_allowed?/1` — the right its mount needed for the record it
      holds, re-read from the database and the live scope.

  The hook halts those events with "You don't have permission to do that
  here." when `write_allowed?/1` answers false, and fails closed when it is
  missing or raises. Writes that do not arrive as events (a timer, an
  internal `handle_event/3` call) must ask `write_allowed?/1` themselves.
  """

  use Gettext, backend: PhoenixKitProjects.Gettext

  @doc false
  def on_mount(:default, _params, _session, socket) do
    {:cont, Phoenix.LiveView.attach_hook(socket, :projects_write_gate, :handle_event, &gate/3)}
  end

  @doc false
  def gate(event, _params, %{view: view} = socket) do
    if event in view.write_events() and not allowed?(socket) do
      {:halt, refuse(socket)}
    else
      {:cont, socket}
    end
  end

  @doc "Puts the refusal flash on `socket`."
  def refuse(socket) do
    Phoenix.LiveView.put_flash(
      socket,
      :error,
      gettext("You don't have permission to do that here.")
    )
  end

  @doc "Asks the form's `write_allowed?/1`, failing closed."
  def allowed?(%{view: view} = socket) do
    function_exported?(view, :write_allowed?, 1) and view.write_allowed?(socket)
  rescue
    _ -> false
  end
end
