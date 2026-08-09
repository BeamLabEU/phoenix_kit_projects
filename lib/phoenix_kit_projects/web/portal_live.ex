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

  import PhoenixKitWeb.Components.Core.EmptyState
  import PhoenixKitWeb.Components.Core.FileUpload, only: [file_upload: 1]
  import PhoenixKitWeb.Components.Core.Input, only: [input: 1]
  import PhoenixKitWeb.Components.Core.MentionText
  import PhoenixKitWeb.Components.Core.StatusDot
  import PhoenixKitWeb.Components.Core.Textarea, only: [textarea: 1]
  import PhoenixKitWeb.Components.Core.TimeDisplay, only: [time_ago: 1]

  alias PhoenixKit.Mentions.Token
  alias PhoenixKit.Utils.Routes
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
        issue: nil,
        issue_uuid: nil,
        status_filter: "all",
        # The min-fill-time anchor (panel: bots submit instantly).
        mounted_ms: System.monotonic_time(:millisecond)
      )
      |> allow_upload(:screenshot,
        # Images only, and the count/size caps the context enforces again
        # on the way in. LiveView's checks are a courtesy to the person
        # uploading; Portal.store_attachments/1 is the control.
        accept: ~w(.png .jpg .jpeg .webp .gif),
        max_entries: Portal.attachment_limits().count,
        max_file_size: Portal.attachment_limits().bytes
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
    {:ok,
     assign(socket,
       view: nil,
       portal: nil,
       slug: nil,
       submitted: false,
       error: nil,
       needs_sign_in: false
     )}
  end

  defp load_view(socket) do
    # ONE resolve for both the uuid and the view (the final panel's
    # TOCTOU find: a rotate between two resolves used to skip the
    # rotation subscription). The uuid rides the socket for the PubSub
    # topic only; it never reaches the template.
    viewer = socket.assigns[:phoenix_kit_current_scope]

    case Portal.resolve(socket.assigns.slug, viewer) do
      {:ok, portal, project} ->
        case Portal.public_view(socket.assigns.slug, viewer) do
          {:ok, view} ->
            assign(socket,
              # The row itself, not just its uuid: the mention typeahead
              # scopes off the portal (access mode decides which issues are
              # listed at all), and re-resolving inside the event handler
              # would be a second doorway to keep in step with this one.
              # Re-set on every load_view, so a rotation or a mode change
              # replaces it rather than leaving a stale grant behind.
              portal: portal,
              view: Map.put(view, :project_uuid, project.uuid),
              page_title: view.project_name
            )

          :error ->
            assign(socket, portal: nil, view: nil, page_title: gettext("Not found"))
        end

      :error ->
        assign(socket,
          portal: nil,
          view: nil,
          page_title: gettext("Not found"),
          needs_sign_in: needs_sign_in?(socket, viewer)
        )
    end
  end

  # Whether to OFFER a sign-in link — and deliberately not a question about
  # this slug at all.
  #
  # Asking "is this particular slug a members board?" made the answer an
  # existence probe: an unknown slug said "unavailable" while a real
  # members board said "sign in", so any candidate URL could be tested.
  # Anonymous visitors now see the same page and the same offer whatever
  # the slug was, which costs a signed-out reader nothing and tells an
  # attacker nothing.
  defp needs_sign_in?(_socket, viewer), do: is_nil(viewer_uuid(viewer))

  defp viewer_uuid(%{user: %{uuid: uuid}}) when is_binary(uuid), do: uuid
  defp viewer_uuid(_), do: nil

  # Reading a discussion follows the board: whoever can see the issue can
  # see what has been said about it. WRITING is the thing that is gated.

  # The issue page is the board page plus one record. Loading it here
  # rather than in mount keeps the board's own resolve untouched, and a
  # missing/unpublished issue degrades to the board rather than to an
  # error: the reader followed a link to something that is no longer
  # published, and the board is the useful place to land.
  @impl true
  def handle_params(params, _uri, socket) do
    {:noreply,
     socket
     |> assign(
       issue_uuid: params["issue"],
       status_filter: status_filter(params["status"])
     )
     |> load_issue()}
  end

  # Whitelisted, never echoed back raw: the value reaches a class attribute
  # and a comparison, and anything outside the vocabulary is simply "all".
  defp status_filter(status) when status in ["todo", "in_progress", "done"], do: status
  defp status_filter(_), do: "all"

  defp load_issue(%{assigns: %{issue_uuid: nil}} = socket), do: assign(socket, issue: nil)

  defp load_issue(socket) do
    viewer = socket.assigns[:phoenix_kit_current_scope]

    case Portal.public_issue(socket.assigns.slug, socket.assigns.issue_uuid, viewer) do
      {:ok, issue} -> assign(socket, issue: issue)
      :error -> assign(socket, issue: nil, issue_uuid: nil)
    end
  end

  # Comments re-render the page they live on.
  @impl true
  def handle_info({:comments_updated, _payload}, socket), do: {:noreply, socket}

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
    do_submit(socket, params)
  end

  # The portal does NOT `use PhoenixKit.Mentions.Live`. That glue's search
  # spans everything the VIEWER may see, which on a public page is the
  # wrong axis entirely: a staff member reading this board could pick an
  # internal task and publish its title to the open web. It also injects
  # the request-access dialog, which has no meaning here — there is nobody
  # to ask on behalf of an anonymous reader.
  #
  # Without this clause the events fell to the catch-all below and were
  # silently swallowed, which is why typing `@` or `#` did nothing at all.
  def handle_event("pk_mention_search", params, socket) do
    kind = if params["kind"] == "user", do: :user, else: :resource

    results =
      case socket.assigns[:portal] do
        nil ->
          []

        portal ->
          Portal.mention_candidates(kind, params["query"] || "", portal,
            viewer: socket.assigns[:phoenix_kit_current_scope],
            issue_uuid: socket.assigns[:issue_uuid]
          )
      end
      |> Enum.map(fn candidate ->
        # Built HERE, never by the client. A record whose title contains a
        # `|` or `]` would otherwise be concatenated into an unparseable
        # token, and a client that builds tokens is a client that can forge
        # one pointing anywhere it likes.
        case Token.to_string(
               candidate.kind,
               candidate.type,
               candidate.uuid,
               candidate.title
             ) do
          {:ok, token} -> Map.put(candidate, :token, token)
          :error -> nil
        end
      end)
      |> Enum.reject(&is_nil/1)

    {:reply, %{results: results, seq: params["seq"]}, socket}
  end

  def handle_event(_event, _params, socket), do: {:noreply, socket}

  defp do_submit(socket, params) do
    meta = %{
      peer_ip: socket.assigns.peer_ip,
      honeypot: params["website"],
      mounted_ms: socket.assigns.mounted_ms,
      # A thunk, not files. Portal.submit/3 calls it only after the
      # honeypot, fill-time and rate-limit gates pass, so a caller who is
      # about to be refused never costs an image re-encode.
      attachments: fn -> take_screenshots(socket) end,
      # The submit policy is checked in the write path, which needs to know
      # who is asking.
      viewer: socket.assigns[:phoenix_kit_current_scope]
    }

    case Portal.submit(socket.assigns.slug, params, meta) do
      {:ok, :submitted} ->
        {:noreply,
         socket
         |> put_flash(
           :info,
           gettext(
             "Thanks — your report is with the team. It will appear here once they publish it."
           )
         )
         |> push_navigate(to: board_path(socket.assigns.slug))}

      {:error, :rate_limited} ->
        {:noreply,
         assign(socket, error: gettext("Too many submissions — please try again later."))}

      _ ->
        {:noreply,
         assign(socket, error: gettext("Could not submit — check the form and try again."))}
    end
  end

  # ── Render ────────────────────────────────────────────────────────

  @impl true
  def render(%{view: nil} = assigns) do
    assigns = assign_new(assigns, :needs_sign_in, fn -> false end)

    ~H"""
    <div class="mx-auto flex min-h-[60vh] max-w-lg flex-col items-center justify-center gap-3 px-4 text-center">
      <meta name="robots" content="noindex, nofollow" />
      <span class="hero-link-slash w-10 h-10 opacity-30"></span>

      <%!-- A members board tells an anonymous visitor what to do about it.
           Every other failure keeps the uniform wording, so the page can't
           be used to discover which slugs exist. --%>
      <%!-- One wording for every failure. Naming the reason — wrong slug,
           rotated link, portal off, signed out — is what turns this page
           into a probe for which slugs are real. --%>
      <h1 class="text-xl font-semibold">{gettext("This page is unavailable")}</h1>
      <p class="text-sm opacity-60">
        {gettext("The link may have been rotated or the portal turned off.")}
      </p>
      <a
        :if={@needs_sign_in}
        href={Routes.path("/users/log-in")}
        class="btn btn-ghost btn-sm"
      >
        {gettext("Some boards need you to sign in")}
      </a>
    </div>
    """
  end

  def render(%{live_action: :report, view: %{may_submit: false}} = assigns) do
    # Reachable directly, so it answers the same question the board's
    # button does rather than trusting that nobody typed the URL. The
    # server refuses either way; drawing the form would just waste the
    # reporter's paragraphs.
    ~H"""
    <div class="mx-auto flex max-w-2xl flex-col gap-4 px-4 py-10">
      <.robots mode={@view.access_mode} />

      <.link navigate={board_path(@slug)} class="text-sm opacity-60 hover:opacity-100">
        {gettext("← Back to %{project}", project: @view.project_name)}
      </.link>

      <.empty_state
        icon="hero-lock-closed"
        title={gettext("Reporting is closed here")}
        description={
          if @view.capabilities.submit,
            do: gettext("This board takes reports from signed-in people."),
            else: gettext("This board isn't taking new reports right now.")
        }
      />
    </div>
    """
  end

  def render(%{live_action: :report} = assigns) do
    ~H"""
    <div class="mx-auto flex max-w-2xl flex-col gap-6 px-4 py-10">
      <.robots mode={@view.access_mode} />

      <.link navigate={board_path(@slug)} class="text-sm opacity-60 hover:opacity-100">
        {gettext("← Back to %{project}", project: @view.project_name)}
      </.link>

      <div>
        <h1 class="text-2xl font-bold">{gettext("Report an issue")}</h1>
        <%!-- Above the fold, not in fine print under the button. Everything
             submitted here is invisible until a person publishes it, and a
             reporter who doesn't know that submits again, and again. --%>
        <p class="mt-2 text-sm opacity-70">
          {gettext("Your report goes to the team for review. It won't appear on the public board until someone there publishes it.")}
        </p>
      </div>

      <div :if={@error} class="alert alert-error text-sm">{@error}</div>

      <form id="portal-submit-form" phx-submit="submit_issue" class="flex flex-col gap-4">
        <.input
          type="text"
          name="title"
          value=""
          label={gettext("What happened?")}
          placeholder={gettext("A short summary")}
          required
          maxlength="200"
          autocomplete="off"
        />

        <div>
          <.textarea
            name="description"
            value=""
            label={gettext("Details")}
            rows="8"
            maxlength="5000"
            placeholder={gettext("What you did, what you expected, and what happened instead.")}
          />
        </div>

        <%!-- Screenshots. Accepting a file from a stranger is defensible
             here for two reasons that have to hold together: every image
             is RE-ENCODED before storage, so what lands on disk is our
             encoder's output rather than the uploader's bytes; and nothing
             submitted reaches the public board until a person publishes
             it. Neither alone would be enough. --%>
        <div>
          <.file_upload
            upload={@uploads.screenshot}
            standalone={false}
            label={gettext("Screenshots (optional)")}
            icon="hero-photo"
            accept_description={gettext("PNG, JPEG, WebP or GIF")}
            max_size_description={
              gettext("up to %{count} images, %{size} MB each",
                count: Portal.attachment_limits().count,
                size: div(Portal.attachment_limits().bytes, 1_000_000)
              )
            }
          />
        </div>

        <%!-- The honeypot. Hidden from people, irresistible to the bots
             that fill every field they find. --%>
        <div class="hidden" aria-hidden="true">
          <label>
            {gettext("Website")}
            <input type="text" name="website" tabindex="-1" autocomplete="off" />
          </label>
        </div>

        <div class="flex items-center justify-end gap-2">
          <.link navigate={board_path(@slug)} class="btn btn-ghost btn-sm">
            {gettext("Cancel")}
          </.link>
          <button type="submit" class="btn btn-primary" phx-disable-with={gettext("Sending…")}>
            {gettext("Send report")}
          </button>
        </div>
      </form>
    </div>
    """
  end

  def render(%{live_action: :issue, issue: issue} = assigns) when not is_nil(issue) do
    ~H"""
    <div class="mx-auto flex max-w-3xl flex-col gap-6 px-4 py-10">
      <.robots mode={@view.access_mode} />

      <.link navigate={board_path(@slug)} class="text-sm opacity-60 hover:opacity-100">
        {gettext("← %{project}", project: @view.project_name)}
      </.link>

      <header class="flex flex-col gap-2">
        <%!-- Meta above the title (the eyebrow pattern). It is most of what
             separates a designed page from a scaffolded one. --%>
        <div class="flex flex-wrap items-center gap-2 text-sm">
          <.status_dot variant={status_variant(@issue.status)} label={@issue.status_label} />
          <span class="opacity-40">·</span>
          <span class="opacity-60">
            {gettext("Opened %{when}", when: short_date(@issue.inserted_at))}
          </span>
        </div>
        <h1 class="text-2xl font-bold leading-snug">{@issue.title}</h1>
      </header>

      <div :if={@issue.description} class="prose prose-sm max-w-none opacity-90">
        <.mention_text
          text={@issue.description}
          scope={@phoenix_kit_current_scope}
          allow_request={false}
          withhold_titles
        />
      </div>

      <%!-- Screenshots that came with the report. `loading="lazy"` and a
           bounded height so a tall screenshot doesn't push the discussion
           off the page. --%>
      <div :if={@issue[:images] not in [nil, []]} class="flex flex-wrap gap-3">
        <a
          :for={image <- @issue.images}
          href={image.url}
          target="_blank"
          rel="noopener noreferrer"
          class="block overflow-hidden rounded-box border border-base-200 transition-colors hover:border-primary/40"
        >
          <img
            src={image.url}
            alt={gettext("Screenshot attached to this report")}
            loading="lazy"
            class="max-h-56 w-auto object-contain"
          />
        </a>
      </div>

      <div class="divider my-0"></div>

      <section class="flex flex-col gap-3">
        <h2 class="text-lg font-semibold">{gettext("Discussion")}</h2>

        <.live_component
          module={PhoenixKitComments.Web.CommentsComponent}
          id={"portal-issue-#{@issue.uuid}"}
          resource_type={Portal.discussion_resource_type()}
          resource_uuid={@issue.uuid}
          current_user={commenter(assigns)}
          enabled={@view.may_comment}
          show_title={false}
          rich_text={false}
          withhold_mention_titles
        />

        <%!-- Not a disabled textarea: a greyed-out box reads as broken
             rather than as a rule. --%>
        <p
          :if={not @view.may_comment}
          class="rounded-box bg-base-200 px-4 py-3 text-center text-sm opacity-70"
        >
          {gettext("Only signed-in people can reply here.")}
        </p>
      </section>
    </div>
    """
  end

  def render(assigns) do
    ~H"""
    <div class="mx-auto flex max-w-3xl flex-col gap-6 px-4 py-10">
      <.robots mode={@view.access_mode} />

      <%!-- A masthead, not a bare heading. The name, what this board is
           for, and one freshness signal — that timestamp does more for
           perceived quality than any amount of restyling. --%>
      <header class="flex flex-wrap items-start justify-between gap-4">
        <div class="min-w-0">
          <h1 class="text-3xl font-bold">{@view.project_name}</h1>
          <p class="mt-1 text-sm opacity-60">
            {gettext("Public issue board")}
            <span :if={last_activity(@view)}>
              <span class="opacity-40">·</span>
              {gettext("updated %{when}", when: last_activity(@view))}
            </span>
          </p>
        </div>
        <.link :if={@view.may_submit} navigate={report_path(@slug)} class="btn btn-primary btn-sm">
          {gettext("Report an issue")}
        </.link>
      </header>

      <p :if={@view.capabilities.submit and not @view.may_submit} class="text-sm opacity-60">
        {gettext("Sign in to report an issue here.")}
      </p>

      <%!-- Real links, not JS tabs: server-rendered, crawlable, and they
           work with scripting off. They also replace the old "To do: 3"
           chip row, which read like debug output. --%>
      <div :if={@view.capabilities.list and @view.issues != []} class="join">
        <.link
          :for={{key, label, count} <- status_filters(@view)}
          patch={board_path(@slug, key)}
          class={["btn btn-sm join-item", @status_filter == key && "btn-active"]}
        >
          {label}
          <span class="opacity-50">{count}</span>
        </.link>
      </div>

      <section :if={@view.capabilities.list} class="flex flex-col">
        <.empty_state
          :if={@view.issues == []}
          icon="hero-inbox"
          title={gettext("Nothing published yet")}
          description={gettext("Issues appear here once the team publishes them.")}
        />

        <.empty_state
          :if={@view.issues != [] and visible_issues(@view, @status_filter) == []}
          icon="hero-funnel"
          title={gettext("No issues in this view")}
        />

        <%!-- Rows, not cards. Issue titles are text, and text wants rows:
             at six issues cards waste the viewport, at three hundred they
             are mush. --%>
        <.link
          :for={issue <- visible_issues(@view, @status_filter)}
          navigate={issue_path(@slug, issue.uuid)}
          class="group flex items-center gap-3 border-b border-base-200 py-3 transition-colors hover:bg-base-200/40"
        >
          <.status_dot
            variant={status_variant(issue.status)}
            label={issue.status_label}
            size={:sm}
            class="w-28 shrink-0 text-xs opacity-70"
          />
          <span class="min-w-0 flex-1 truncate font-medium group-hover:text-primary">
            {issue.title}
          </span>
          <.time_ago datetime={issue.updated_at} class="shrink-0 text-xs opacity-50" />
        </.link>
      </section>
    </div>
    """
  end

  # ── Presentation ──────────────────────────────────────────────────

  attr(:mode, :string, required: true)

  defp robots(assigns) do
    ~H"""
    <meta
      name="robots"
      content={if @mode == "public", do: "index, follow", else: "noindex, nofollow"}
    />
    """
  end

  # Core's `status_dot` does this, and a second implementation of a dot
  # plus a label is exactly the kind of thing that drifts. This maps the
  # assignment vocabulary onto its semantic variants and stops there.
  defp status_variant("done"), do: :success
  defp status_variant("in_progress"), do: :warning
  defp status_variant(_), do: :info

  # Filters are derived from what is actually on the board, so a board with
  # nothing in progress doesn't offer an empty tab.
  defp status_filters(view) do
    counts = Enum.frequencies_by(view.issues, & &1.status)

    [{"all", gettext("All"), length(view.issues)}]
    |> Kernel.++(
      for {status, label} <- [
            {"todo", gettext("Open")},
            {"in_progress", gettext("In progress")},
            {"done", gettext("Done")}
          ],
          Map.has_key?(counts, status),
          do: {status, label, Map.fetch!(counts, status)}
    )
  end

  defp visible_issues(view, "all"), do: view.issues
  defp visible_issues(view, status), do: Enum.filter(view.issues, &(&1.status == status))

  # The freshest thing on the board. Deliberately absent when nothing has
  # moved in a while: a stale "updated 4 months ago" advertises neglect,
  # where saying nothing simply doesn't make the claim.
  defp last_activity(view) do
    case view.issues do
      [] ->
        nil

      issues ->
        latest = issues |> Enum.map(& &1.updated_at) |> Enum.max(DateTime)

        if DateTime.diff(DateTime.utc_now(), latest, :day) <= 60,
          do: relative_time(latest),
          else: nil
    end
  end

  defp relative_time(dt) do
    days = DateTime.diff(DateTime.utc_now(), dt, :day)

    cond do
      days <= 0 ->
        gettext("today")

      days == 1 ->
        gettext("yesterday")

      days < 30 ->
        ngettext("%{count} day ago", "%{count} days ago", days, count: days)

      true ->
        ngettext("%{count} month ago", "%{count} months ago", div(days, 30), count: div(days, 30))
    end
  end

  defp short_date(nil), do: ""
  defp short_date(dt), do: Calendar.strftime(dt, "%-d %b %Y")

  defp issue_path(slug, uuid), do: Routes.path("/portal/#{slug}/i/#{uuid}")

  # nil, never false: the comments component reads `current_user.uuid`, and
  # `false && user` hands it a boolean that dies on the first field access.
  defp commenter(%{view: %{may_comment: true}} = assigns), do: current_user(assigns)
  defp commenter(_assigns), do: nil

  defp current_user(%{phoenix_kit_current_scope: %{user: user}}), do: user
  defp current_user(_), do: nil

  defp take_screenshots(socket) do
    socket
    |> consume_uploaded_entries(:screenshot, fn %{path: path}, entry ->
      # The path handed in here belongs to the upload channel, and returning
      # `{:ok, _}` is precisely what tells LiveView to stop that channel —
      # at which point Plug.Upload's monitor deletes the file. That deletion
      # is asynchronous, so reading the path after this callback returns is
      # a race: a quiet machine usually wins it and a loaded one does not,
      # which shows up as a perfectly good PNG failing at random. Copy it
      # while it is still ours; from here on the file is ours to remove too.
      owned =
        Path.join(System.tmp_dir!(), "pk-portal-in-#{System.unique_integer([:positive])}")

      case File.cp(path, owned) do
        :ok -> {:ok, %{path: owned, name: entry.client_name}}
        {:error, _} -> {:ok, :unreadable}
      end
    end)
    |> Enum.reject(&(&1 == :unreadable))
  rescue
    _ -> []
  end

  defp board_path(slug), do: Routes.path("/portal/#{slug}")
  defp board_path(slug, "all"), do: board_path(slug)
  defp board_path(slug, status), do: Routes.path("/portal/#{slug}?status=#{status}")
  defp report_path(slug), do: Routes.path("/portal/#{slug}/report")
end
