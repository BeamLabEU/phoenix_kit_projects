defmodule PhoenixKitProjects.Web.PortalLive do
  @moduledoc """
  The public portal page — `/portal/:slug`, no authentication, no
  internal API access: everything renders from `Portal.public_view/1`'s
  whitelisted DTO (panel #5), and the submit path runs the full guard
  chain inside `handle_event` (panel #2 — plug-level limits never see
  LiveView events).

  Every failure mode — unknown slug, disabled extension, disabled
  capability, rotation while mounted — renders the SAME unavailable
  state (panel #11), and a `:portal_rotated` broadcast downgrades live
  sessions immediately (panel #7). Content renders through HEEx escaping
  only — portal-sourced text is plain text at every egress (panel #4).
  """

  use Phoenix.LiveView
  use Gettext, backend: PhoenixKitProjects.Gettext

  alias PhoenixKitProjects.Portal
  alias PhoenixKitProjects.PubSub, as: ProjectsPubSub

  @impl true
  def mount(%{"slug" => slug}, _session, socket) do
    # Peer address only — never a forwarded header (panel #3). Hosts
    # behind a proxy that want real client IPs terminate them via
    # RemoteIp BEFORE Phoenix; we never parse XFF ourselves.
    peer_ip =
      case get_connect_info(socket, :peer_data) do
        %{address: address} -> address
        _ -> nil
      end

    socket =
      socket
      |> assign(
        slug: slug,
        peer_ip: peer_ip,
        submitted: false,
        error: nil,
        # The min-fill-time anchor (panel: bots submit instantly).
        mounted_ms: System.monotonic_time(:millisecond)
      )
      |> load_view()

    if connected?(socket) do
      case socket.assigns.view do
        %{project_uuid: uuid} -> ProjectsPubSub.subscribe(ProjectsPubSub.topic_project(uuid))
        _ -> :ok
      end
    end

    {:ok, socket}
  end

  def mount(_params, _session, socket) do
    {:ok, assign(socket, view: nil, slug: nil, submitted: false, error: nil)}
  end

  defp load_view(socket) do
    case Portal.public_view(socket.assigns.slug) do
      {:ok, view} ->
        # The DTO has no project uuid (whitelist) — resolve it once for
        # the rotation subscription; it never reaches the template.
        project_uuid =
          case Portal.resolve(socket.assigns.slug) do
            {:ok, _portal, project} -> project.uuid
            _ -> nil
          end

        assign(socket,
          view: Map.put(view, :project_uuid, project_uuid),
          page_title: view.project_name
        )

      :error ->
        assign(socket, view: nil, page_title: gettext("Not found"))
    end
  end

  # Rotation / re-configuration while mounted: re-resolve; a dead slug
  # downgrades to the uniform unavailable state on the spot.
  @impl true
  def handle_info({:projects, event, _payload}, socket)
      when event in [:portal_rotated, :project_modules_changed, :assignment_updated] do
    {:noreply, load_view(socket)}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  @impl true
  def handle_event("submit_issue", params, socket) do
    meta = %{
      peer_ip: socket.assigns.peer_ip,
      honeypot: params["website"],
      mounted_ms: socket.assigns.mounted_ms
    }

    case Portal.submit(socket.assigns.slug, params, meta) do
      {:ok, :submitted} ->
        {:noreply, socket |> assign(submitted: true, error: nil) |> load_view()}

      {:error, :rate_limited} ->
        {:noreply,
         assign(socket, error: gettext("Too many submissions — please try again later."))}

      _ ->
        {:noreply,
         assign(socket, error: gettext("Could not submit — check the form and try again."))}
    end
  end

  def handle_event(_event, _params, socket), do: {:noreply, socket}

  # ── Render ────────────────────────────────────────────────────────

  @impl true
  def render(%{view: nil} = assigns) do
    ~H"""
    <div class="mx-auto flex min-h-[60vh] max-w-lg flex-col items-center justify-center gap-3 px-4 text-center">
      <meta name="robots" content="noindex, nofollow" />
      <span class="hero-link-slash w-10 h-10 opacity-30"></span>
      <h1 class="text-xl font-semibold">{gettext("This page is unavailable")}</h1>
      <p class="text-sm opacity-60">
        {gettext("The link may have been rotated or the portal turned off.")}
      </p>
    </div>
    """
  end

  def render(assigns) do
    ~H"""
    <div class="mx-auto flex max-w-3xl flex-col gap-8 px-4 py-10">
      <meta name="robots" content="noindex, nofollow" />

      <header class="flex flex-col gap-1">
        <h1 class="text-2xl font-bold">{@view.project_name}</h1>
        <p :if={@view.capabilities.status} class="text-sm opacity-60">
          {status_line(@view)}
        </p>
      </header>

      <%!-- Status summary --%>
      <section :if={@view.capabilities.status and @view.issues != []} class="flex flex-wrap gap-2">
        <span
          :for={{status_label, count} <- summarize(@view)}
          class="badge badge-ghost badge-lg gap-1"
        >
          {status_label}: {count}
        </span>
      </section>

      <%!-- Public issue list --%>
      <section :if={@view.capabilities.list} class="flex flex-col gap-2">
        <h2 class="text-lg font-semibold">{gettext("Issues")}</h2>
        <p :if={@view.issues == []} class="text-sm opacity-60">
          {gettext("Nothing published yet.")}
        </p>
        <div :if={@view.issues != []} class="divide-y divide-base-200 rounded-lg border border-base-200">
          <div :for={issue <- @view.issues} class="flex items-center gap-3 px-3 py-2">
            <span class="min-w-0 flex-1 truncate text-sm">{issue.title}</span>
            <span class="badge badge-ghost badge-sm shrink-0">{issue.status_label}</span>
          </div>
        </div>
      </section>

      <%!-- Submission form --%>
      <section :if={@view.capabilities.submit} class="flex flex-col gap-3">
        <h2 class="text-lg font-semibold">{gettext("Report an issue")}</h2>

        <div :if={@submitted} class="alert alert-success text-sm">
          {gettext("Thank you — your issue has been submitted.")}
        </div>

        <form :if={not @submitted} id="portal-submit-form" phx-submit="submit_issue" class="flex flex-col gap-3">
          <div :if={@error} class="alert alert-warning text-sm">{@error}</div>

          <label class="form-control">
            <span class="label-text mb-1">{gettext("Title")}</span>
            <input
              type="text"
              name="title"
              required
              maxlength="200"
              class="input input-bordered"
            />
          </label>

          <label class="form-control">
            <span class="label-text mb-1">{gettext("Description")}</span>
            <textarea name="description" rows="5" maxlength="5000" class="textarea textarea-bordered"></textarea>
          </label>

          <%!-- Honeypot: invisible to humans, irresistible to bots. --%>
          <div aria-hidden="true" style="position:absolute; left:-9999px;" tabindex="-1">
            <label>Website <input type="text" name="website" tabindex="-1" autocomplete="off" /></label>
          </div>

          <button type="submit" class="btn btn-primary self-start" phx-disable-with={gettext("Submitting…")}>
            {gettext("Submit")}
          </button>
        </form>
      </section>
    </div>
    """
  end

  defp status_line(view) do
    cond do
      view.completed_at -> gettext("Completed")
      view.started_at -> gettext("In progress")
      true -> gettext("Not started")
    end
  end

  defp summarize(view) do
    view.issues
    |> Enum.frequencies_by(& &1.status_label)
    |> Enum.sort_by(&elem(&1, 1), :desc)
  end
end
