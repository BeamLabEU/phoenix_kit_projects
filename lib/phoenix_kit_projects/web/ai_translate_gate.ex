defmodule PhoenixKitProjects.Web.AITranslateGate do
  @moduledoc """
  Re-checks the form's own write right before an AI-translate modal event
  reaches its handler.

  `PhoenixKitAI.Components.AITranslate.Embed` handles the modal's events in
  a `:handle_event` lifecycle hook with no authorization callback, so
  `ai_translate_lang` would enqueue a translation for whoever can still send
  the event. A form declares `on_mount(PhoenixKitProjects.Web.AITranslateGate)`
  BEFORE `use ...AITranslate.Embed` (hooks run in the order they attach) and
  exports `ai_translate_allowed?/1` — the same right its save needs for the
  record it holds, read from the socket's CURRENT scope (the one core swaps
  in when a role loses a grant mid-session). This hook halts those events
  with a refusal when that answers false.
  """

  use Gettext, backend: PhoenixKitProjects.Gettext

  @events ~w(ai_translate_lang ai_toggle_modal ai_select_endpoint ai_select_prompt
             ai_select_scope ai_generate_prompt)

  @doc false
  def on_mount(:default, _params, _session, socket) do
    {:cont,
     Phoenix.LiveView.attach_hook(socket, :projects_ai_translate_gate, :handle_event, &gate/3)}
  end

  @doc false
  # Closing is always allowed, including after the form's write right was
  # revoked while the modal was open. The Embed only toggles this assign.
  def gate("ai_toggle_modal", _params, %{assigns: %{ai_modal_open: true}} = socket),
    do: {:cont, socket}

  def gate(event, _params, socket) when event in @events do
    if allowed?(socket) do
      {:cont, socket}
    else
      {:halt,
       Phoenix.LiveView.put_flash(
         socket,
         :error,
         gettext("You don't have permission to do that here.")
       )}
    end
  end

  def gate(_event, _params, socket), do: {:cont, socket}

  # Fails closed: a view that forgot the callback, or one that raises,
  # refuses the event.
  defp allowed?(%{view: view} = socket) do
    function_exported?(view, :ai_translate_allowed?, 1) and view.ai_translate_allowed?(socket)
  rescue
    _ -> false
  end
end
