defmodule PhoenixKitProjects.Web.PopupHostLive do
  @moduledoc """
  Opinionated wrapper LV that pairs the `<.popup_host>` function
  component with the emit-mode PubSub contract.

  A host app mounts this LV (typically via `live_render`) and gets
  popup-driven UX for free — no host-side `handle_info` subscription,
  no modal-stack state management, no frame-ref bookkeeping.

  ## What it does

  1. Subscribes to a host-supplied PubSub topic on connect.
  2. Optionally renders a "root view" inline (the always-visible LV;
     `OverviewLive` is the typical pick) by passing `session["root_view"]`.
  3. On `{:projects, :opened, ...}` — pushes a frame onto the modal
     stack and renders the target LV inside a `<dialog>` overlay.
  4. On `{:projects, :closed | :saved | :deleted, %{frame_ref: ref}}`
     — pops the top frame iff `ref` matches (race-safe against stale
     events).
  5. Generates a unique `frame_ref` per push and stamps it into the
     child LV's session along with `mode: "emit"` and the host topic,
     so the child's own emits flow back through this LV.
  6. Caps stack depth at `@max_stack_depth` (5) to prevent runaway
     recursion if a misbehaved LV emits `:opened` on every mount.

  ## Session contract

  - `"pubsub_topic"` (required) — PubSub topic string. The host owns
    the topic name; this LV does not invent it (so two embeds on the
    same page can use different topics if needed).
  - `"root_view"` (optional) — `%{"lv" => "Module.Name", "session" =>
    %{...}}`. The always-visible LV. `:lv` is whitelist-validated.
  - `"wrapper_class"` (optional) — outer div class. Defaults to
    `"flex flex-col w-full"`.

  ## Example mount (from a host app's router)

      live "/orders/:id/projects", MyApp.OrderProjectsLive

      # ... and in MyApp.OrderProjectsLive's render:
      {Phoenix.Component.live_render(@socket, PhoenixKitProjects.Web.PopupHostLive,
         id: "projects-popup-host",
         session: %{
           "pubsub_topic" => "host:orders:" <> @order_id,
           "root_view" => %{
             "lv" => "PhoenixKitProjects.Web.OverviewLive",
             "session" => %{
               "wrapper_class" => "flex flex-col w-full px-4 py-6 gap-6"
             }
           }
         })}

  Whenever the embedded `OverviewLive` (or anything it transitively
  opens) emits `:opened`, this LV renders the target inside a modal
  on the host's existing page. No URL change. No DOM replacement.
  """

  use Phoenix.LiveView, layout: false

  import PhoenixKitProjects.Web.Components.PopupHost

  alias PhoenixKitProjects.PubSub, as: ProjectsPubSub
  alias PhoenixKitProjects.Web.Helpers, as: WebHelpers

  require Logger

  @default_wrapper_class "flex flex-col w-full"
  @default_root_wrapper_class "flex flex-col w-full px-4 py-6 gap-6"
  @max_stack_depth 5

  @impl true
  def mount(_params, session, socket) do
    # Restore the locale in this process so anything PopupHost itself
    # renders (flash text, error markers) reads the right language.
    # Same fix as `WebHelpers.maybe_put_locale/1` applied in every
    # embeddable LV — `live_render` spawns a fresh process without the
    # parent's Gettext locale in its dict. See dev_docs/embedding_audit.md.
    WebHelpers.maybe_put_locale(session)

    topic =
      case Map.get(session, "pubsub_topic") do
        s when is_binary(s) and s != "" ->
          s

        _ ->
          raise ArgumentError,
                "PopupHostLive requires session[\"pubsub_topic\"] to be a non-empty string"
      end

    wrapper_class = Map.get(session, "wrapper_class", @default_wrapper_class)
    host_locale = Map.get(session, "locale")

    if connected?(socket), do: ProjectsPubSub.subscribe(topic)

    root_view = decode_root_view(Map.get(session, "root_view"), topic, host_locale)

    {:ok,
     assign(socket,
       host_topic: topic,
       host_locale: host_locale,
       wrapper_class: wrapper_class,
       modal_stack: [],
       root_view: root_view
     )}
  end

  defp decode_root_view(nil, _topic, _locale), do: nil

  defp decode_root_view(%{"lv" => lv_str} = config, topic, locale) do
    with {:ok, lv} <- WebHelpers.decode_embeddable_lv(lv_str),
         {:ok, session} <- WebHelpers.decode_session(Map.get(config, "session")) do
      child_session =
        session
        |> Map.put("mode", "emit")
        |> Map.put("pubsub_topic", topic)
        |> Map.put_new("wrapper_class", @default_root_wrapper_class)
        |> maybe_put_locale_key(locale)

      %{
        lv: lv,
        session: child_session,
        # Suffix the topic so two `PopupHostLive` instances on the same
        # page (e.g. two order panels both rendering `OverviewLive` as
        # root_view) don't collide on `live_render` child IDs. Phoenix
        # LV requires unique IDs per logical embed; duplicates break
        # client-side targeting and patching. The topic is host-supplied
        # and unique per host instance, so it's a stable disambiguator.
        id: "embed-root-" <> lv_slug(lv) <> "-" <> topic_suffix(topic)
      }
    else
      _ ->
        Logger.warning("[PopupHostLive] invalid root_view session config: #{inspect(config)}")

        nil
    end
  end

  defp decode_root_view(other, _topic, _locale) do
    Logger.warning(
      ~s([PopupHostLive] root_view must be a map with "lv" and "session" keys, got #{inspect(other)})
    )

    nil
  end

  # Threads the host's `session["locale"]` into the child LV's session
  # so it survives the `live_render` process boundary. Without this,
  # every modal frame's child mount falls back to backend default
  # English regardless of what locale the host page is running.
  defp maybe_put_locale_key(session, locale)
       when is_binary(locale) and locale != "" do
    Map.put_new(session, "locale", locale)
  end

  defp maybe_put_locale_key(session, _), do: session

  defp lv_slug(mod) when is_atom(mod) do
    mod
    |> Atom.to_string()
    |> String.split(".")
    |> List.last()
    |> Macro.underscore()
  end

  # Short, deterministic, DOM-safe suffix derived from the host topic.
  # `Base.url_encode64/2` on a SHA-256 hash gives us a value that's safe
  # to embed in an HTML id regardless of what characters the host put in
  # their topic name.
  defp topic_suffix(topic) when is_binary(topic) do
    :crypto.hash(:sha256, topic)
    |> Base.url_encode64(padding: false)
    |> binary_part(0, 12)
  end

  @impl true
  def handle_info({:projects, :opened, %{lv: lv, session: child_session} = payload}, socket)
      when is_atom(lv) and is_map(child_session) do
    emitter_ref = Map.get(payload, :frame_ref)

    cond do
      length(socket.assigns.modal_stack) >= @max_stack_depth ->
        Logger.warning(
          "[PopupHostLive] modal stack depth (#{@max_stack_depth}) exceeded — " <>
            "refusing to push #{inspect(lv)}"
        )

        {:noreply, socket}

      not WebHelpers.embeddable_lv?(lv) ->
        Logger.warning("[PopupHostLive] refused :opened for non-embeddable LV #{inspect(lv)}")

        {:noreply, socket}

      not stale_safe_opener?(socket, emitter_ref) ->
        # The event's `frame_ref` doesn't match the current top of the
        # stack (nil = root view). A non-top emitter means the source
        # frame was popped before we processed this — i.e. stale event,
        # double-click race, or adversarial broadcast. Drop instead of
        # opening a child that the user wouldn't expect.
        Logger.debug(
          "[PopupHostLive] dropping stale :opened from frame_ref=#{inspect(emitter_ref)}; " <>
            "current top=#{inspect(current_top_ref(socket))}"
        )

        {:noreply, socket}

      true ->
        {:noreply, push_frame(socket, lv, child_session)}
    end
  end

  # Malformed `:opened` message (missing/bad shape). Drops + logs instead
  # of crashing — adversarial or stale broadcasts must not take down the
  # popup host.
  def handle_info({:projects, :opened, payload}, socket) do
    Logger.warning("[PopupHostLive] dropping malformed :opened payload: #{inspect(payload)}")

    {:noreply, socket}
  end

  def handle_info({:projects, :closed, %{frame_ref: ref}}, socket) do
    {:noreply, pop_if_top_matches(socket, ref)}
  end

  # `:saved` and `:deleted` carry `close: bool` so the emitter controls
  # whether the modal frame should pop. Form-LV saves default to
  # `close: true` (form is terminal; modal closes). Form-LV "this
  # resource is gone" deletes via `notify_deleted_or_navigate/4` also
  # emit `close: true`. List-LV row-delete via `notify_deleted/3` emits
  # `close: false` — the list stays open showing the post-delete state.
  #
  # `:saved` additionally carries `next: {lv, session} | nil` for the
  # create-then-edit / create-then-show flow: pop the current frame,
  # push a new frame for `next` so the user lands on the follow-up
  # screen automatically (mirrors navigate mode's `push_navigate(to:
  # edit_path)`).
  def handle_info(
        {:projects, :saved, %{frame_ref: ref, close: true, next: {next_lv, next_session}}},
        socket
      )
      when is_atom(next_lv) and is_map(next_session) do
    cond do
      # R5-BH: a stale/adversarial :saved with the wrong `frame_ref`
      # used to leave the stack intact (pop is a no-op) AND still push
      # `next`. Now the pop and the push are both gated on the
      # frame_ref matching the top — otherwise drop the whole event.
      current_top_ref(socket) != ref ->
        Logger.debug(
          "[PopupHostLive] dropping stale :saved.next from frame_ref=#{inspect(ref)}; " <>
            "current top=#{inspect(current_top_ref(socket))}"
        )

        {:noreply, socket}

      not WebHelpers.embeddable_lv?(next_lv) ->
        Logger.warning(
          "[PopupHostLive] :saved.next references non-embeddable LV #{inspect(next_lv)}; " <>
            "popping current frame, not pushing next"
        )

        {:noreply, pop_top(socket)}

      true ->
        socket = pop_top(socket)

        if length(socket.assigns.modal_stack) < @max_stack_depth do
          {:noreply, push_frame(socket, next_lv, next_session)}
        else
          Logger.warning(
            "[PopupHostLive] modal stack depth (#{@max_stack_depth}) exceeded after pop — " <>
              "refusing to push :saved.next #{inspect(next_lv)}"
          )

          {:noreply, socket}
        end
    end
  end

  def handle_info({:projects, :saved, %{frame_ref: ref, close: true}}, socket) do
    {:noreply, pop_if_top_matches(socket, ref)}
  end

  def handle_info({:projects, :saved, _payload}, socket) do
    {:noreply, socket}
  end

  def handle_info({:projects, :deleted, %{frame_ref: ref, close: true}}, socket) do
    {:noreply, pop_if_top_matches(socket, ref)}
  end

  def handle_info({:projects, :deleted, _payload}, socket) do
    {:noreply, socket}
  end

  # Content-broadcast events (`:project_updated` etc.) on the host topic
  # are ignored here — they're meant for the host's own subscribers, not
  # for modal-stack management. Catch-all keeps the LV alive across any
  # unexpected message.
  def handle_info(_msg, socket), do: {:noreply, socket}

  @impl true
  def handle_event("close_top_modal", params, socket) do
    # Backdrop click + ESC keypress both fire `close_top_modal`. Each
    # element passes `phx-value-frame-ref={frame.frame_ref}` so the
    # handler can route through `pop_if_top_matches/2` — guards against
    # a race where the user clicks a lower frame's backdrop or where ESC
    # somehow fires for a non-top frame. ESC binding only attaches to
    # the topmost dialog (see popup_host.ex), so the ESC path almost
    # always matches; the frame-ref check is the belt-and-suspenders.
    case normalize_frame_ref(Map.get(params, "frame-ref")) do
      ref when is_integer(ref) ->
        {:noreply, pop_if_top_matches(socket, ref)}

      nil ->
        # The component always emits `phx-value-frame-ref` (see
        # popup_host.ex backdrop button + ESC binding). Missing or
        # malformed value here means the event is stale (frame already
        # popped) or adversarial. Treat as no-op rather than blindly
        # popping the current top — otherwise a delayed event could
        # close the wrong modal.
        Logger.debug(
          "[PopupHostLive] dropping close_top_modal without valid frame-ref " <>
            "(params=#{inspect(params)})"
        )

        {:noreply, socket}
    end
  end

  def handle_event(_event, _params, socket), do: {:noreply, socket}

  # Tolerant decode — `phx-value-frame-ref` arrives as a string from the
  # DOM. Garbage values (adversarial or pre-stamp) degrade to nil so the
  # handler falls back to `pop_top/1` instead of crashing.
  defp normalize_frame_ref(ref) when is_integer(ref), do: ref

  defp normalize_frame_ref(ref) when is_binary(ref) do
    case Integer.parse(ref) do
      {n, ""} -> n
      _ -> nil
    end
  end

  defp normalize_frame_ref(_), do: nil

  defp push_frame(socket, lv, child_session) do
    frame_ref = System.unique_integer([:positive, :monotonic])

    stamped_session =
      child_session
      |> Map.put("mode", "emit")
      |> Map.put("pubsub_topic", socket.assigns.host_topic)
      |> Map.put("frame_ref", frame_ref)
      |> maybe_put_locale_key(socket.assigns[:host_locale])

    frame = %{
      frame_ref: frame_ref,
      lv: lv,
      session: stamped_session,
      id: "embed-#{frame_ref}-#{lv_slug(lv)}"
    }

    assign(socket, modal_stack: socket.assigns.modal_stack ++ [frame])
  end

  defp pop_if_top_matches(socket, frame_ref) do
    case List.last(socket.assigns.modal_stack) do
      %{frame_ref: ^frame_ref} -> pop_top(socket)
      _ -> socket
    end
  end

  # Returns true iff the emitter's frame_ref is the rightful current
  # opener: either `nil` (root view) when the stack is empty, or matches
  # the top frame's ref. Anything else is stale — drop the event.
  defp stale_safe_opener?(socket, emitter_ref) do
    case current_top_ref(socket) do
      ^emitter_ref -> true
      _ -> false
    end
  end

  defp current_top_ref(socket) do
    case List.last(socket.assigns.modal_stack) do
      %{frame_ref: ref} -> ref
      _ -> nil
    end
  end

  defp pop_top(socket) do
    new_stack = Enum.drop(socket.assigns.modal_stack, -1)
    assign(socket, modal_stack: new_stack)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.popup_host
      modal_stack={@modal_stack}
      on_close="close_top_modal"
      class={@wrapper_class}
    >
      <%= if @root_view do %>
        {Phoenix.Component.live_render(@socket, @root_view.lv,
          id: @root_view.id,
          session: @root_view.session
        )}
      <% end %>

      <:frame :let={frame}>
        {Phoenix.Component.live_render(@socket, frame.lv,
          id: frame.id,
          session: frame.session
        )}
      </:frame>
    </.popup_host>
    """
  end
end
