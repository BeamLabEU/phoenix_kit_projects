defmodule PhoenixKitProjects do
  @moduledoc """
  Projects module for PhoenixKit.

  Provides a reusable task library, projects that pull tasks in as
  assignments (with team/department/person assignees), and task
  dependency chains within each project.
  """

  use PhoenixKit.Module
  use Gettext, backend: PhoenixKitProjects.Gettext

  import Ecto.Query, only: [from: 2]

  require Logger

  # Single source of truth: read the version from mix.exs at compile time so
  # version/0 can't drift from @version on a release (baked in — no Mix at
  # runtime). The project's own config is in scope when this module compiles.
  @version Mix.Project.config()[:version]

  alias PhoenixKit.Dashboard.Tab
  alias PhoenixKit.RepoHelper
  alias PhoenixKit.Settings
  alias PhoenixKit.Users.{Permissions, RolePermission}
  alias PhoenixKitProjects.Authz

  @impl PhoenixKit.Module
  def module_key, do: "projects"

  @impl PhoenixKit.Module
  def module_name, do: "Projects"

  @impl PhoenixKit.Module
  def enabled? do
    Settings.get_boolean_setting("projects_enabled", false)
  rescue
    _ -> false
  catch
    :exit, _ -> false
  end

  @impl PhoenixKit.Module
  def enable_system do
    result = Settings.update_boolean_setting_with_module("projects_enabled", true, module_key())

    # Rebuild the extension catalog on our own enable so providers that
    # appeared while we were off are discovered without a restart (the
    # dashboards-Registry precedent; a Grok panel finding caught the
    # Registry moduledoc promising this before it was wired).
    try do
      PhoenixKitProjects.Extensions.Registry.refresh()
    rescue
      _ -> :ok
    end

    result
  end

  @impl PhoenixKit.Module
  def disable_system do
    Settings.update_boolean_setting_with_module("projects_enabled", false, module_key())
  end

  @impl PhoenixKit.Module
  def version, do: @version

  @impl PhoenixKit.Module
  @doc """
  Notification preference types (Step 7 of the hub rework): the actions
  below fan out through core's activity→notification bridge whenever their
  entries carry a `target_uuid` (the affected user — assignees on task
  actions, the member on membership actions). Users tune each sub-type —
  and its Email/Telegram routing — in their notification preferences.
  """
  def notification_types do
    [
      %{
        key: "projects",
        # Core shows the labels through this backend, in the reader's
        # language (a core that does not know the key shows them as written).
        gettext_backend: PhoenixKitProjects.Gettext,
        label: gettext_noop("Projects"),
        description: gettext_noop("Membership, health, and task updates in your projects"),
        actions: [],
        default: true,
        sub_types: [
          %{
            key: "membership",
            label: gettext_noop("Membership"),
            description: gettext_noop("Added to a project, role changes, removals"),
            actions: [
              "projects.member_added",
              "projects.member_role_changed",
              "projects.member_removed"
            ],
            default: true
          },
          %{
            key: "tasks",
            label: gettext_noop("Task updates"),
            description:
              gettext_noop(
                "Your tasks given to you, changed, started, done, reopened, handed on or removed"
              ),
            actions: [
              "projects.assignment_created",
              "projects.assignment_updated",
              "projects.assignment_started",
              "projects.assignment_completed",
              "projects.assignment_reopened",
              "projects.assignment_reassigned",
              "projects.assignment_removed"
            ],
            default: true
          },
          %{
            key: "handoffs",
            label: gettext_noop("Your turn"),
            description:
              gettext_noop(
                "A task of yours can start, or is on hold because work before it was reopened"
              ),
            actions: ["projects.assignment_ready", "projects.assignment_on_hold"],
            default: true
          },
          %{
            key: "comments",
            label: gettext_noop("Comments"),
            description:
              gettext_noop(
                "Comments and notes on your tasks, on tasks you commented on, and on projects you manage"
              ),
            actions: ["projects.comment_added"],
            default: true
          },
          %{
            key: "health",
            label: gettext_noop("Project health"),
            description: gettext_noop("Health judgments on your projects"),
            actions: ["projects.health_updated"],
            default: true
          },
          %{
            key: "events",
            label: gettext_noop("Project events"),
            description: gettext_noop("Meetings, milestones, and reviews added to your projects"),
            actions: [
              "projects.event_created",
              "projects.event_updated",
              "projects.event_deleted"
            ],
            default: true
          }
        ]
      }
    ]
  end

  @impl PhoenixKit.Module
  # Module-owned migration chain (V1 = baseline of the core-built V101..V128
  # shape; V2+ = hub-rework tables). Discovered by `mix phoenix_kit.update`,
  # which compares current_version/0 vs migrated_version_runtime/1 and
  # generates a host migration delegating to Schema.up/1. See the Schema
  # moduledoc for the core-chain handover contract.
  def migration_module, do: PhoenixKitProjects.Migrations.Schema

  @doc """
  The manifest of this module's tables, for `mix phoenix_kit.repair` and
  `mix phoenix_kit.doctor`; see `PhoenixKitProjects.ExpectedSchema`.
  """
  @impl PhoenixKit.Module
  def expected_schema, do: PhoenixKitProjects.ExpectedSchema

  @doc """
  The places in this module's tables that point at a stored file; see
  `PhoenixKitProjects.FileReferences`.
  """
  @impl PhoenixKit.Module
  def file_references, do: PhoenixKitProjects.FileReferences.pairs()

  # AI usage sink (the attribution wave, Phase G): phoenix_kit_ai's
  # dispatch_usage_sinks/1 calls every discovered module exporting this
  # function with each persisted %Request{} — duck-typed, no dependency
  # on that package. Resolution + the ledger write live in the Ledger's
  # attribution helper; a request without a resolvable projects
  # attribution is simply not ours.
  def handle_ai_usage(request) do
    PhoenixKitProjects.Ledger.record_ai_request(request)
  end

  @impl PhoenixKit.Module
  # Lifecycle hook: core calls this BEFORE a user row deletes, while
  # memberships still exist. RELEASE-GATED: the callback ships in an
  # unreleased core, so the Hex-pin build won't compile until that
  # release — gates run via PHOENIX_KIT_PATH (the admin-ui-overhaul
  # precedent). Sole-owner departures get succession or an
  # orphan-warning audit row.
  def before_user_delete(user_uuid) do
    PhoenixKitProjects.Members.handle_user_deletion(user_uuid)
  end

  @impl PhoenixKit.Module
  # Public portal routes (/portal/:slug) — the admin surface stays on the
  # admin_tabs/user_dashboard_tabs auto-generation.
  def route_module, do: PhoenixKitProjects.Web.Routes

  @impl PhoenixKit.Module
  # Makes projects and their tasks deep-linkable from Activity and Comments,
  # and mentionable with `#` anywhere someone can type. The handler owns its
  # own permission scoping — see PhoenixKitProjects.ResourceLinks.
  def resource_links do
    Map.merge(
      PhoenixKitProjects.ResourceLinks.types(),
      PhoenixKitProjects.PortalLinks.types()
    )
  end

  @impl PhoenixKit.Module
  def permission_metadata do
    %{
      key: module_key(),
      label: "Projects",
      icon: "hero-clipboard-document-list",
      description: "Reach the Projects module — see the projects you belong to",
      sub_permissions: [
        # The base key used to mean "do everything on every project": the
        # resolver short-circuited on module access before membership was
        # ever consulted, so granting a contractor's role the projects
        # permission handed them full power over every project on the site.
        # Splitting it makes the base key mean "may enter the module" and
        # this one mean "administer projects you are not a member of".
        # Core auto-grants declared sub-keys to Admin at boot, Owner rides
        # the "*" wildcard, and `migrate_legacy/0` carries every other role
        # that already held the base key — so nobody loses access, while a
        # role granted the base key from now on gets no such power.
        %{
          key: "admin_all",
          label: "Administer all projects",
          description:
            "See and manage every project on the site, including ones this user is not a member of"
        },
        # API keys, one right per action (Max, 2026-10-19: "make sure it's
        # all configurable via permissions… you grant someone an API key and
        # you want them to be able to rotate it. But you don't want them to
        # create any extra keys"). Seeing the keys that act for you needs
        # only the base key; everything else is one of these.
        %{
          key: "api_keys_create",
          label: "Create API keys",
          description: "Make API keys that act for this user"
        },
        %{
          key: "api_keys_edit",
          label: "Change their API keys' access",
          description:
            "Add and remove projects and change what a key that acts for this user may do"
        },
        %{
          key: "api_keys_rotate",
          label: "Rotate their API keys",
          description: "Get a new token for a key that acts for this user"
        },
        %{
          key: "api_keys_revoke",
          label: "Revoke their API keys",
          description: "Turn off a key that acts for this user"
        },
        %{
          key: "api_keys_manage",
          label: "Manage everyone's API keys",
          description:
            "See every API key, make keys for anyone or for nobody (shared), and change, rotate or revoke any key"
        },
        # A library task is shared by every project that assigned it, so
        # changing or deleting one reaches into projects the editor may not
        # even see — a site-level right, not a project role.
        %{
          key: "manage_library",
          label: "Manage the task library",
          description:
            "Create, edit, reorder and delete the shared library tasks, and add one-off tasks to the library"
        },
        %{
          key: "settings",
          label: "Change the projects settings",
          description:
            "Change the module's settings: status lists, the new-project form, list controls, timeline and calendar display"
        }
      ]
    }
  end

  # Set once the split's compatibility backfill has run, so it never runs
  # again and an Owner's revoke sticks.
  @admin_all_backfill_key "projects_admin_all_backfilled"
  @api_keys_backfill_key "projects_api_keys_permissions_backfilled"
  @manage_library_backfill_key "projects_manage_library_backfilled"
  @settings_backfill_key "projects_settings_backfilled"

  # What a role holding the base key could do with its own keys before the
  # API key rights were split out (2026-10-19).
  @own_key_rights ~w(projects.api_keys_create projects.api_keys_edit
                     projects.api_keys_rotate projects.api_keys_revoke)

  @doc """
  One-time data repairs for installs that predate a change here. Core calls
  this on every boot, so each repair carries its own "already done" flag and
  runs exactly once.

    * `projects.admin_all` is granted to every role that already holds the
      base `projects` key, preserving the pre-split behavior.
    * Projects carrying the old, incomplete "simple to-do list" preset get
      the three flags that preset should always have turned off.

  Both are deliberately one-way and one-time: re-deciding on every boot
  would fight the Owner, handing back a permission they revoked or
  re-disabling a feature they turned on.
  """
  def migrate_legacy do
    # ONCE each, not on every boot. This runs from the host's start-up, and
    # an unconditional version fights the Owner: revoke admin_all from the
    # contractor role and the next restart hands it back. Each flag is set
    # only once its grants all succeeded, so a failure is retried next boot.
    results = [
      backfill_sub_keys(@admin_all_backfill_key, [Authz.admin_all_key()]),
      backfill_sub_keys(@api_keys_backfill_key, @own_key_rights),
      backfill_sub_keys(@manage_library_backfill_key, [Authz.manage_library_key()]),
      backfill_sub_keys(@settings_backfill_key, [Authz.settings_key()])
    ]

    backfill_checklist_flags()

    case Enum.reject(results, &(&1 == :ok)) do
      [] -> :ok
      errors -> {:error, errors}
    end
  rescue
    error ->
      {:error, Exception.message(error)}
  end

  @doc false
  # Once per flag: every role that holds the base key gets `keys` — what the
  # base key used to allow (admin_all, the own-key API rights, the library
  # writes, the settings page). The grants are READ with this module's own
  # query: core's `get_permissions_for_role/1` rescues an error to `[]`,
  # which would read as "nobody holds projects" and set the flag for good. A
  # failed read answers `{:error, :lookup_failed}`, a failed grant
  # `{:error, {:backfill_incomplete, …}}`; either leaves the flag unset. A
  # role granted `projects` later gets the narrow meaning. `:grant` and
  # `:holders` are parameters only so a test can make either fail.
  def backfill_sub_keys(flag, keys, opts \\ []) do
    if Settings.get_setting(flag) == "true" do
      :ok
    else
      grant = Keyword.get(opts, :grant, &Permissions.grant_permission/3)
      holders = Keyword.get(opts, :holders, &role_uuids_holding/1)

      with {:ok, base, held} <- read_holders(holders, keys) do
        grant_missing(flag, keys, base, held, grant)
      end
    end
  end

  defp read_holders(holders, keys) do
    base = holders.(module_key())
    held = Map.new(keys, &{&1, MapSet.new(holders.(&1))})
    {:ok, base, held}
  rescue
    error ->
      Logger.warning(
        "[PhoenixKitProjects] permission backfill could not read the grants, will retry next boot: " <>
          Exception.message(error)
      )

      {:error, :lookup_failed}
  end

  defp grant_missing(flag, keys, base, held, grant) do
    failures =
      for role_uuid <- base,
          key <- keys,
          not MapSet.member?(Map.fetch!(held, key), role_uuid),
          result = grant.(role_uuid, key, nil),
          not match?({:ok, _}, result) do
        {role_uuid, key, result}
      end

    if failures == [] do
      Settings.update_setting_with_module(flag, "true", module_key())
      :ok
    else
      Logger.warning(
        "[PhoenixKitProjects] #{flag} incomplete, will retry next boot: " <> inspect(failures)
      )

      {:error, {:backfill_incomplete, flag, failures}}
    end
  end

  # Every role holding `key`, straight from the role-permission table; raises
  # on a failed read (see `backfill_sub_keys/3`).
  defp role_uuids_holding(key) do
    RepoHelper.repo().all(
      from(rp in RolePermission,
        where: rp.module_key == ^key,
        select: rp.role_uuid,
        distinct: true
      )
    )
  end

  # The "simple to-do list" preset shipped incomplete: it turned off the
  # eleven task features but left the work ledger, the board and the
  # start/finish lifecycle ON. A shared checklist therefore asked to be
  # "started", sat in the dashboard's not-started bucket until it was,
  # carried a `Logged: 0m` readout, and announced its own "completion"
  # when the last box was ticked — for a project type whose card promises
  # "no scheduling overhead".
  #
  # New checklists get the corrected preset. Existing ones can't: absence
  # means "inherit the default", and the default is on. So complete the
  # bundle for projects that carry ALL of the old one — an exact match, not
  # a heuristic, so a project someone configured to look similar by hand is
  # left alone. Anything here can be turned back on in Modules & features.
  @old_simple_bundle ~w(assignees priorities labels estimates progress
                        dependencies statuses scheduling subprojects
                        view_timeline view_calendar)
  @checklist_backfill_key "projects_checklist_flags_backfilled"

  defp backfill_checklist_flags do
    alias PhoenixKit.Settings
    alias PhoenixKitProjects.{Features, Projects}

    if Settings.get_setting(@checklist_backfill_key) == "true" do
      :ok
    else
      Projects.list_projects()
      |> Enum.filter(&old_simple_preset?/1)
      |> Enum.each(fn project ->
        Features.set_flags(project, %{
          "lifecycle" => false,
          "ledger" => false,
          "view_board" => false
        })
      end)

      Settings.update_setting_with_module(@checklist_backfill_key, "true", module_key())
      :ok
    end
  end

  defp old_simple_preset?(project) do
    flags = project.settings |> Kernel.||(%{}) |> Map.get("features", %{})

    Enum.all?(@old_simple_bundle, &(Map.get(flags, &1) == false)) and
      Enum.all?(~w(lifecycle ledger view_board), &(not Map.has_key?(flags, &1)))
  end

  @impl PhoenixKit.Module
  # Includes :phoenix_live_gantt (Timeline tab) and :phoenix_live_calendar (the
  # Overview calendar) so the host's Tailwind scans their classes with no manual
  # `@source` — the css-sources compiler resolves each dep atom to deps/<dep>.
  def css_sources, do: [:phoenix_kit_projects, :phoenix_live_gantt, :phoenix_live_calendar]

  @impl PhoenixKit.Module
  def media_reorganizer, do: PhoenixKitProjects.MediaReorganizer

  # The Timeline tab renders the gantt with enable_hooks={true}, so the host's
  # LiveSocket needs the gantt's JS hooks. Declaring the bundle here lets the
  # :phoenix_kit_js_sources compiler wire it into the host automatically — no
  # manual app.js import/spread. The bundle ships in phoenix_live_gantt's priv/.
  #
  # NOTE: no `@impl PhoenixKit.Module` — the core behaviour doesn't declare a
  # `js_sources/0` callback yet (it ships with the core js-sources compiler PR).
  # Annotating @impl against the released core warns ("behaviour does not specify
  # such callback") and fails `mix precommit` (compile --warnings-as-errors).
  # Until core ships the callback this is a harmless plain function core never
  # calls; re-add @impl once the core release includes it.
  def js_sources do
    [
      %{
        app: :phoenix_live_gantt,
        file: "static/assets/phoenix_live_gantt.js",
        global: "PhoenixLiveGanttHooks"
      },
      # The Overview calendar renders without JS (Phoenix-first); these hooks are
      # progressive enhancement (marker ticker / popover-pause) wired the same way
      # as the gantt's so they're available if the calendar opts into them.
      %{
        app: :phoenix_live_calendar,
        file: "static/assets/phoenix_live_calendar.js",
        global: "PhoenixLiveCalendarHooks"
      },
      # This module's own hooks: the typed task list (`PkpOutline`), the task
      # list's hover / trace of connections (`PkpLinks`) and a
      # title edited in place on a card row (`PkpTitle`). Plain JS, no build.
      %{
        app: :phoenix_kit_projects,
        file: "static/assets/phoenix_kit_projects.js",
        global: "PhoenixKitProjectsHooks"
      }
    ]
  end

  def ai_translatables do
    [
      {"project", PhoenixKitProjects.AITranslatable},
      {"template", PhoenixKitProjects.AITranslatable},
      {"task", PhoenixKitProjects.AITranslatable},
      {"assignment", PhoenixKitProjects.AITranslatable}
    ]
  end

  # Dashboard widgets contributed to `phoenix_kit_dashboards` (duck-typed contract
  # discovered by its Registry — no dependency on that package, no `@impl`).
  def phoenix_kit_widgets, do: PhoenixKitProjects.DashboardWidgets.all()

  # Project-extension catalog entries (the hub's own duck-typed provider
  # contract — `PhoenixKitProjects.Extensions.Registry` discovers this same
  # function on every module, ours included; no `@impl`, mirrors
  # `phoenix_kit_widgets/0`). The built-in Tasks extension ships
  # `default_enabled: true` so every pre-hub project keeps its task surface
  # unchanged — the hub's behavior-preserving default. Its feature flags land
  # with the Features layer (Step 3 of the 2026-08-05 plan); tabs stay native
  # on the show page until enforcement threading gates them.
  # Names, descriptions and flag labels are catalog DATA, translated at
  # render through `Web.Helpers.translate_catalog/1`; `gettext_noop/1`
  # registers each literal so the extractor keeps it in the `.pot` — without
  # it the whole catalog rendered English in every locale (the sweep,
  # 2026-09-05).
  def phoenix_kit_project_extensions do
    [
      %{
        key: "tasks",
        name: gettext_noop("Tasks"),
        description:
          gettext_noop("Task lists, dependencies, scheduling, Timeline and Calendar views"),
        icon: "hero-clipboard-document-list",
        module_key: nil,
        default_enabled: true,
        permission_actions: [
          :create_tasks,
          :edit_tasks,
          :delete_tasks,
          :assign_tasks,
          :update_status,
          :log_time,
          :log_time_for_others
        ],
        # The FROZEN pre-hub flag catalog (2026-08-05 panel amendment #6):
        # every flag defaults true so existing projects are unchanged with
        # no backfill; `requires` is the resolution-time dependency rule
        # (Features.on?/2 — a flag is dead while any requirement is off).
        # The "simple todo list" preset is these, explicitly false.
        feature_flags: [
          # Whether this project draws on the shared task library: the
          # "From library" tab and "Add to the task library" on the add-task
          # form. Off, every task is a one-off typed in place — a checklist
          # (the Simple preset turns it off; the others leave it on).
          %{key: "library", label: gettext_noop("Task library"), default: true},
          # The task row's middle state. Off, a task goes straight from
          # to-do to done (one tick, no Start step) — a checklist. Rows
          # already in progress keep their Done button; the board keeps
          # its In-progress column only while one is there.
          %{key: "in_progress", label: gettext_noop("In-progress step"), default: true},
          %{key: "assignees", label: gettext_noop("Assignees"), default: true},
          # Tasks under tasks (V23): Tab in the list, a parent on the form
          # and in the API. Off, the list stays flat; subtasks already made
          # keep their place.
          %{key: "subtasks", label: gettext_noop("Subtasks"), default: true},
          # Whom a task waits on and who asked for it. People's business:
          # off with Assignees, so a plain to-do's form stays a title and a
          # status (Max, 2026-10-14).
          %{
            key: "waiting",
            label: gettext_noop("Waiting on and requested by"),
            default: true,
            requires: ["assignees"]
          },
          # A task's own start and end dates (V21). Planning's business: off
          # with Scheduling, for the same reason.
          %{
            key: "dates",
            label: gettext_noop("Start and end dates"),
            default: true,
            requires: ["scheduling"]
          },
          %{key: "estimates", label: gettext_noop("Estimates & durations"), default: true},
          %{
            key: "progress",
            label: gettext_noop("Progress tracking"),
            default: true,
            requires: []
          },
          %{key: "dependencies", label: gettext_noop("Dependencies"), default: true},
          %{key: "statuses", label: gettext_noop("Workflow statuses"), default: true},
          %{
            key: "scheduling",
            label: gettext_noop("Scheduling & ETA"),
            default: true,
            requires: ["estimates"]
          },
          %{key: "subprojects", label: gettext_noop("Sub-projects"), default: true},
          %{key: "priorities", label: gettext_noop("Priorities"), default: true},
          %{key: "labels", label: gettext_noop("Labels"), default: true},
          %{key: "ledger", label: gettext_noop("Work ledger"), default: true},
          # Whether the project HAS a start and a finish. Off, it is just a
          # list of tasks that exists: no "start it" step, no completion, no
          # dashboard bucket asking when it begins. A shared checklist has
          # no beginning to name, and being asked to name one is the whole
          # complaint. Defaults on, like every flag here, so existing
          # projects are unchanged with no backfill.
          %{key: "lifecycle", label: gettext_noop("Start & finish"), default: true},
          %{key: "view_board", label: gettext_noop("Board view"), default: true},
          %{
            key: "view_timeline",
            label: gettext_noop("Timeline view"),
            default: true,
            requires: ["scheduling"]
          },
          %{
            key: "view_calendar",
            label: gettext_noop("Calendar view"),
            default: true,
            requires: ["scheduling"]
          }
        ],
        # Hours: the work ledger read back — who worked, on what, when —
        # with its chart, timesheet and report. A contributed tab like any
        # provider's, offered only while the `ledger` flag is on.
        tabs: [
          %{
            key: "hours",
            label: gettext_noop("Hours"),
            icon: "hero-clock",
            lv: PhoenixKitProjects.Web.ProjectHoursLive,
            requires_flag: "ledger"
          }
        ]
      },
      %{
        key: "files",
        name: gettext_noop("Files"),
        description: gettext_noop("Attach files to the project (core media library)"),
        icon: "hero-paper-clip",
        module_key: nil,
        default_enabled: true,
        permission_actions: [:upload_files]
      },
      # Whiteboards (Step 11): built-in extension whose surface is a
      # contributed tab through the SAME pipeline external providers use —
      # dogfooding the tab contract. Off by default: drawing boards are an
      # opt-in capability, not part of the pre-hub surface.
      %{
        key: "whiteboards",
        name: gettext_noop("Whiteboards"),
        description: gettext_noop("Freeform drawing boards on the core annotation canvas"),
        icon: "hero-paint-brush",
        module_key: nil,
        default_enabled: false,
        permission_actions: [:upload_files],
        tabs: [
          %{
            key: "boards",
            label: gettext_noop("Whiteboards"),
            icon: "hero-paint-brush",
            lv: PhoenixKitProjects.Web.ProjectWhiteboardsLive
          }
        ]
      },
      # Events (Step 12): dated happenings that aren't tasks — meetings,
      # milestones, reviews — on their own calendar tab. Off by default.
      %{
        key: "events",
        name: gettext_noop("Events"),
        description: gettext_noop("Meetings, milestones, and reviews on a project calendar"),
        icon: "hero-calendar-days",
        module_key: nil,
        default_enabled: false,
        permission_actions: [:create_tasks],
        tabs: [
          %{
            key: "events",
            label: gettext_noop("Events"),
            icon: "hero-calendar-days",
            lv: PhoenixKitProjects.Web.ProjectEventsLive
          }
        ]
      },
      # Hub-side BRIDGE descriptor for a module that doesn't self-declare
      # (phoenix_kit_comments is BeamLab-maintained): the show page's
      # comments drawer, re-fronted as a per-project toggle. The drawer's
      # own availability check still applies — this gate composes with it.
      %{
        key: "discussions",
        name: gettext_noop("Discussions"),
        description: gettext_noop("Comment threads on the project and its tasks"),
        icon: "hero-chat-bubble-left-right",
        module_key: "comments",
        default_enabled: true,
        permission_actions: [:comment]
      },
      # Public portal (Phase J): anonymous issue intake + a public issue
      # list/status page behind a random capability link. Off by default
      # everywhere; the security model lives in PhoenixKitProjects.Portal
      # (2026-08-06 design doc + the external security panel's findings).
      %{
        key: "portal",
        name: gettext_noop("Public portal"),
        description:
          gettext_noop(
            "Anonymous issue submission and a public status page behind a private link"
          ),
        icon: "hero-globe-alt",
        module_key: nil,
        default_enabled: false,
        permission_actions: [:edit_tasks],
        on_enable: {PhoenixKitProjects.Portal, :ensure_portal},
        feature_flags: [
          %{key: "portal_submit", label: gettext_noop("Public issue submission"), default: true},
          %{key: "portal_list", label: gettext_noop("Public issue list"), default: true},
          %{key: "portal_status", label: gettext_noop("Public status summary"), default: true}
        ]
      }
    ]
  end

  # ── Dashboard slots ────────────────────────────────────────────────

  @doc """
  Places a dashboard may be shown inside this module — the duck-typed
  `phoenix_kit_dashboard_slots/0` contract (no dependency on
  `phoenix_kit_dashboards`, no `@impl`, exactly like `phoenix_kit_widgets/0`).

  Declaring these is CONSENT. The dashboards package is able to inject a
  sub-tab under any module's sidebar entry without asking — core groups
  sub-tabs by parent id with no ownership check — and deliberately does not.
  Nothing appears under Projects that is not declared right here.

  Two places:

  * **Projects dashboard** — a sidebar sub-tab beside the list and the
    Overview. Context-free: it is about the whole module, so widgets bound to
    "the project this page is about" have nothing to read and say so. A widget
    bound to *the viewer's own* project resolves fine here, which is what makes
    one shared board work for every project manager.
  * **Project page** — the Dashboard tab inside a project. It supplies
    `projects.project`, so one shared board serves every project instead of
    needing a copy each. It is the SAME tab this module's dashboard extension
    contributes, and the two settle by specificity: a project that picks its
    own board in its Modules panel overrides the placement, everything else
    follows it.

  The list stays the project list: neither slot is a landing page. An overview
  and a dashboard are different things, which is why Dashboard sits next to
  Overview rather than replacing it.
  """
  @spec phoenix_kit_dashboard_slots() :: [map()]
  def phoenix_kit_dashboard_slots do
    [
      %{
        key: "projects.module",
        # Names and descriptions are OUR strings, so they translate through
        # OUR catalogue — the dashboards package cannot hold msgids for text
        # this module authors. `gettext_noop/1` pins them for the extractor,
        # exactly as the project-extension catalog above does.
        name: gettext_noop("Projects dashboard"),
        description: gettext_noop("A dashboard beside the project list"),
        # The URL segment. Without it the slug derives from the key and reads
        # `projects-module`, which leaks how the contract is spelled rather
        # than naming the thing.
        slug: "projects",
        gettext_backend: PhoenixKitProjects.Gettext,
        gettext_domain: "default",
        icon: "hero-squares-2x2",
        surface: :module_tab,
        parent_tab: :admin_projects,
        module_key: module_key(),
        provides: [],
        cardinality: :many,
        priority: 690
      },
      %{
        key: "projects.project",
        name: gettext_noop("Project page"),
        description:
          gettext_noop("The Dashboard tab on every project — a project can override it"),
        gettext_backend: PhoenixKitProjects.Gettext,
        gettext_domain: "default",
        icon: "hero-rectangle-group",
        surface: :record_tab,
        module_key: module_key(),
        provides: ["projects.project"],
        cardinality: :one,
        priority: 691
      }
    ]
  end

  @doc """
  Resolves "**my** project" for a viewer — the `viewer` bind source in the
  dashboards package.

  This is the half of the design that a page subject cannot supply: a shared
  "Project managers" dashboard in the sidebar has no current project, yet each
  manager needs their own. Only this module can answer that question, so the
  dashboards package asks rather than guessing.

  Deliberately conservative. It answers only when there is exactly ONE project
  the viewer can reach, and otherwise `nil` — which renders as "pick a project"
  rather than a confident wrong answer. Guessing "most recently visited" was
  considered and rejected: it is wrong every Monday morning, and being silently
  shown the wrong project's numbers is worse than being shown none.
  """
  @spec phoenix_kit_dashboard_viewer_context(String.t(), term()) :: String.t() | nil
  def phoenix_kit_dashboard_viewer_context("projects.project", scope) do
    case PhoenixKitProjects.Projects.list_projects_for(scope, limit: 2) do
      [project] -> project.uuid
      _ -> nil
    end
  rescue
    # Degrading to "pick a project" is the right answer for the viewer, but it
    # must not be the only trace: a schema drift that makes this raise on every
    # call would leave every shared board showing a placeholder forever with
    # nothing in the log to explain it. Mirrors `ext_tabs_for`'s handling.
    e ->
      Logger.warning(
        "[Projects] phoenix_kit_dashboard_viewer_context failed: #{Exception.message(e)}"
      )

      nil
  catch
    :exit, _ -> nil
  end

  def phoenix_kit_dashboard_viewer_context(_kind, _scope), do: nil

  # Paths reach the matcher normalised (URL prefix + locale stripped, no
  # trailing slash): the landing itself and every project page under it —
  # i.e. anything under `projects` that is not one of the sibling subtabs
  # (`tasks`, `templates`, `hours`, `time`, `overview`). Legacy `list/…` addresses redirect
  # before they render, so they need no match. A function, not a module
  # attribute — a compiled Regex holds a reference and cannot be injected
  # into a function body.
  defp projects_list_match,
    do:
      {:regex,
       ~r{^/admin/projects(?!/(tasks|templates|hours|time|overview|api-keys)(/|$))(/.*)?$}}

  @impl PhoenixKit.Module
  def admin_tabs do
    parent = [
      %Tab{
        id: :admin_projects,
        label: "Projects",
        gettext_backend: PhoenixKitProjects.Gettext,
        gettext_domain: "default",
        icon: "hero-clipboard-document-list",
        path: "projects",
        priority: 660,
        level: :admin,
        permission: module_key(),
        match: :prefix,
        group: :admin_modules,
        subtab_display: :when_active,
        highlight_with_subtabs: false,
        # The landing page IS the project list (boss, 2026-09-04). The
        # Overview keeps its own value next to a dashboards-module board
        # (boss, 2026-09-05: "an overview and a dashboard are different
        # things") — it lives on as the LAST subtab, at `projects/overview`.
        live_view: {PhoenixKitProjects.Web.ProjectsLive, :index}
      }
    ]

    visible_subtabs = [
      %Tab{
        id: :admin_projects_list,
        label: "Projects",
        gettext_backend: PhoenixKitProjects.Gettext,
        gettext_domain: "default",
        icon: "hero-clipboard-document-list",
        path: "projects",
        priority: 661,
        level: :admin,
        permission: module_key(),
        # Lit on the landing page AND on every project page under it,
        # without claiming Tasks/Templates/Overview. Tabs match
        # independently (no longest-prefix arbitration), so a plain
        # `:prefix` on `projects` would light this one everywhere.
        match: projects_list_match(),
        parent: :admin_projects,
        live_view: {PhoenixKitProjects.Web.ProjectsLive, :index}
      },
      %Tab{
        id: :admin_projects_templates,
        label: "Templates",
        gettext_backend: PhoenixKitProjects.Gettext,
        gettext_domain: "default",
        icon: "hero-document-duplicate",
        path: "projects/templates",
        priority: 662,
        level: :admin,
        permission: module_key(),
        match: :prefix,
        parent: :admin_projects,
        live_view: {PhoenixKitProjects.Web.TemplatesLive, :index}
      },
      %Tab{
        id: :admin_projects_tasks,
        label: "Tasks",
        gettext_backend: PhoenixKitProjects.Gettext,
        gettext_domain: "default",
        icon: "hero-rectangle-stack",
        path: "projects/tasks",
        priority: 663,
        level: :admin,
        permission: module_key(),
        match: :prefix,
        parent: :admin_projects,
        live_view: {PhoenixKitProjects.Web.TasksLive, :index}
      },
      # Hours across every project the viewer may see: the same page as a
      # project's Hours tab, with a project filter.
      %Tab{
        id: :admin_projects_hours,
        label: "Hours",
        gettext_backend: PhoenixKitProjects.Gettext,
        gettext_domain: "default",
        icon: "hero-clock",
        path: "projects/hours",
        priority: 664,
        level: :admin,
        permission: module_key(),
        match: :prefix,
        parent: :admin_projects,
        live_view: {PhoenixKitProjects.Web.ProjectHoursLive, :index}
      },
      # Every API key a person has, and what each may do per project
      # (V24: keys live outside projects — Max, 2026-10-15).
      # A section of its own with two children in the sidebar (Max,
      # 2026-10-19: "use the Phoenix kit admin sidebar subtabs"), the same
      # shape as core's Settings › Integrations: the parent only links to
      # its first child.
      %Tab{
        id: :admin_projects_api_keys,
        label: "API keys",
        gettext_backend: PhoenixKitProjects.Gettext,
        gettext_domain: "default",
        icon: "hero-key",
        path: "projects/api-keys",
        priority: 665,
        level: :admin,
        permission: module_key(),
        match: :prefix,
        parent: :admin_projects,
        subtab_display: :when_active,
        redirect_to_first_subtab: true,
        highlight_with_subtabs: false
      },
      %Tab{
        id: :admin_projects_api_keys_list,
        label: gettext_noop("Keys"),
        gettext_backend: PhoenixKitProjects.Gettext,
        gettext_domain: "default",
        icon: "hero-key",
        path: "projects/api-keys",
        priority: 665,
        level: :admin,
        permission: module_key(),
        match: :exact,
        parent: :admin_projects_api_keys,
        live_view: {PhoenixKitProjects.Web.ApiKeysLive, :index}
      },
      %Tab{
        id: :admin_projects_api_keys_usage,
        label: gettext_noop("Usage"),
        gettext_backend: PhoenixKitProjects.Gettext,
        gettext_domain: "default",
        icon: "hero-chart-bar",
        path: "projects/api-keys/usage",
        priority: 665,
        level: :admin,
        permission: module_key(),
        match: :exact,
        parent: :admin_projects_api_keys,
        live_view: {PhoenixKitProjects.Web.ApiKeysLive, :usage}
      },
      # Time: each person's day across every project — planned against
      # actually done (boss, 2026-10-29). Next to the Overview, its
      # managerial sibling.
      %Tab{
        id: :admin_projects_time,
        label: "Time",
        gettext_backend: PhoenixKitProjects.Gettext,
        gettext_domain: "default",
        icon: "hero-calendar-days",
        path: "projects/time",
        priority: 666,
        level: :admin,
        permission: module_key(),
        match: :prefix,
        parent: :admin_projects,
        live_view: {PhoenixKitProjects.Web.TimeLive, :index}
      },
      # Last on purpose: the list is where the work is, the Overview is
      # the read-only picture of it. Its pieces are also dashboards-module
      # widgets (`DashboardWidgets`) for anyone who wants them on a board.
      %Tab{
        id: :admin_projects_overview,
        label: "Overview",
        gettext_backend: PhoenixKitProjects.Gettext,
        gettext_domain: "default",
        icon: "hero-home",
        path: "projects/overview",
        priority: 667,
        level: :admin,
        permission: module_key(),
        match: :prefix,
        parent: :admin_projects,
        live_view: {PhoenixKitProjects.Web.OverviewLive, :index}
      }
    ]

    hidden_subtabs = [
      # Legacy `projects/list/…` addresses (the list lived there until
      # 2026-09, with every project page nested under it). Both tabs
      # redirect to the same path without the segment, so bookmarks and
      # older embeds' `redirect_to` values keep landing. Declared FIRST
      # among the hidden tabs: routes are emitted in this order and Phoenix
      # matches in declaration order, so the bare `projects/list` must be
      # seen before `projects/:id` would swallow it as an id.
      %Tab{
        id: :admin_projects_list_legacy,
        label: "Projects",
        gettext_backend: PhoenixKitProjects.Gettext,
        gettext_domain: "default",
        path: "projects/list",
        priority: 665,
        level: :admin,
        permission: module_key(),
        match: :exact,
        parent: :admin_projects,
        visible: false,
        live_view: {PhoenixKitProjects.Web.ListRedirectLive, :index}
      },
      %Tab{
        id: :admin_projects_list_legacy_glob,
        label: "Projects",
        gettext_backend: PhoenixKitProjects.Gettext,
        gettext_domain: "default",
        path: "projects/list/*rest",
        priority: 666,
        level: :admin,
        permission: module_key(),
        match: :exact,
        parent: :admin_projects,
        visible: false,
        live_view: {PhoenixKitProjects.Web.ListRedirectLive, :index}
      },
      %Tab{
        id: :admin_projects_files,
        label: "Project Files",
        gettext_backend: PhoenixKitProjects.Gettext,
        gettext_domain: "default",
        path: "projects/:id/files",
        level: :admin,
        permission: module_key(),
        parent: :admin_projects,
        visible: false,
        live_view: {PhoenixKitProjects.Web.ProjectFilesLive, :edit}
      },
      %Tab{
        id: :admin_projects_activity,
        label: "Project Activity",
        gettext_backend: PhoenixKitProjects.Gettext,
        gettext_domain: "default",
        path: "projects/:id/activity",
        level: :admin,
        permission: module_key(),
        parent: :admin_projects,
        visible: false,
        live_view: {PhoenixKitProjects.Web.ProjectActivityLive, :index}
      },
      %Tab{
        id: :admin_projects_members,
        label: "Project Members",
        gettext_backend: PhoenixKitProjects.Gettext,
        gettext_domain: "default",
        path: "projects/:id/members",
        level: :admin,
        permission: module_key(),
        parent: :admin_projects,
        visible: false,
        live_view: {PhoenixKitProjects.Web.ProjectMembersLive, :edit}
      },
      %Tab{
        id: :admin_projects_api,
        label: "Your API key",
        gettext_backend: PhoenixKitProjects.Gettext,
        gettext_domain: "default",
        path: "projects/:id/api",
        level: :admin,
        permission: module_key(),
        parent: :admin_projects,
        visible: false,
        live_view: {PhoenixKitProjects.Web.ProjectApiLive, :show}
      },
      %Tab{
        id: :admin_projects_modules,
        label: "Project Modules",
        gettext_backend: PhoenixKitProjects.Gettext,
        gettext_domain: "default",
        path: "projects/:id/modules",
        level: :admin,
        permission: module_key(),
        parent: :admin_projects,
        visible: false,
        live_view: {PhoenixKitProjects.Web.ProjectModulesLive, :edit}
      },
      %Tab{
        id: :admin_projects_task_new,
        label: "New Task",
        gettext_backend: PhoenixKitProjects.Gettext,
        gettext_domain: "default",
        path: "projects/tasks/new",
        level: :admin,
        permission: Authz.manage_library_key(),
        parent: :admin_projects,
        visible: false,
        live_view: {PhoenixKitProjects.Web.TaskFormLive, :new}
      },
      %Tab{
        id: :admin_projects_task_edit,
        label: "Edit Task",
        gettext_backend: PhoenixKitProjects.Gettext,
        gettext_domain: "default",
        path: "projects/tasks/:id/edit",
        level: :admin,
        permission: Authz.manage_library_key(),
        parent: :admin_projects,
        visible: false,
        live_view: {PhoenixKitProjects.Web.TaskFormLive, :edit}
      },
      %Tab{
        id: :admin_projects_project_new,
        label: "New Project",
        gettext_backend: PhoenixKitProjects.Gettext,
        gettext_domain: "default",
        path: "projects/new",
        level: :admin,
        permission: module_key(),
        parent: :admin_projects,
        visible: false,
        live_view: {PhoenixKitProjects.Web.ProjectFormLive, :new}
      },
      %Tab{
        id: :admin_projects_project_edit,
        label: "Edit Project",
        gettext_backend: PhoenixKitProjects.Gettext,
        gettext_domain: "default",
        path: "projects/:id/edit",
        level: :admin,
        permission: module_key(),
        parent: :admin_projects,
        visible: false,
        live_view: {PhoenixKitProjects.Web.ProjectFormLive, :edit}
      },
      %Tab{
        id: :admin_projects_project_show,
        label: "Project",
        gettext_backend: PhoenixKitProjects.Gettext,
        gettext_domain: "default",
        path: "projects/:id",
        level: :admin,
        permission: module_key(),
        parent: :admin_projects,
        visible: false,
        live_view: {PhoenixKitProjects.Web.ProjectShowLive, :show}
      },
      %Tab{
        id: :admin_projects_project_board,
        label: "Board",
        gettext_backend: PhoenixKitProjects.Gettext,
        gettext_domain: "default",
        path: "projects/:id/board",
        level: :admin,
        permission: module_key(),
        parent: :admin_projects,
        visible: false,
        # The board was added as a tab without a route, so it was the one
        # view you could not link anyone to: the URL stayed on the list and
        # a reload dropped you back there. Same LiveView, different
        # live_action, exactly like the gantt and calendar below.
        live_view: {PhoenixKitProjects.Web.ProjectShowLive, :board}
      },
      %Tab{
        id: :admin_projects_project_gantt,
        label: "Timeline",
        gettext_backend: PhoenixKitProjects.Gettext,
        gettext_domain: "default",
        path: "projects/:id/gantt",
        level: :admin,
        permission: module_key(),
        parent: :admin_projects,
        visible: false,
        # Same LiveView as the show page, different live_action — the gantt is a
        # tab on the show page, not a separate page. `:gantt` selects that tab.
        live_view: {PhoenixKitProjects.Web.ProjectShowLive, :gantt}
      },
      %Tab{
        id: :admin_projects_project_calendar,
        label: "Calendar",
        gettext_backend: PhoenixKitProjects.Gettext,
        gettext_domain: "default",
        path: "projects/:id/calendar",
        level: :admin,
        permission: module_key(),
        parent: :admin_projects,
        visible: false,
        # Same LiveView as the show page, different live_action — the calendar
        # is a tab on the show page, not a separate page. `:calendar` selects it.
        live_view: {PhoenixKitProjects.Web.ProjectShowLive, :calendar}
      },
      # ── The project page's top-level tabs (2026-09-05, the boss) ──
      # Tasks holds the task views; every enabled extension and Comments are
      # its peers. The canonical addresses are `/tasks[/board|timeline|calendar]`,
      # `/comments` and `/<extension tab key>` — the `/board`, `/gantt` and
      # `/calendar` routes above keep every old link landing on its tab.
      %Tab{
        id: :admin_projects_project_tasks,
        label: "Tasks",
        gettext_backend: PhoenixKitProjects.Gettext,
        gettext_domain: "default",
        path: "projects/:id/tasks",
        level: :admin,
        permission: module_key(),
        parent: :admin_projects,
        visible: false,
        live_view: {PhoenixKitProjects.Web.ProjectShowLive, :tasks}
      },
      %Tab{
        id: :admin_projects_project_tasks_board,
        label: "Board",
        gettext_backend: PhoenixKitProjects.Gettext,
        gettext_domain: "default",
        path: "projects/:id/tasks/board",
        level: :admin,
        permission: module_key(),
        parent: :admin_projects,
        visible: false,
        live_view: {PhoenixKitProjects.Web.ProjectShowLive, :board}
      },
      %Tab{
        id: :admin_projects_project_tasks_timeline,
        label: "Timeline",
        gettext_backend: PhoenixKitProjects.Gettext,
        gettext_domain: "default",
        path: "projects/:id/tasks/timeline",
        level: :admin,
        permission: module_key(),
        parent: :admin_projects,
        visible: false,
        live_view: {PhoenixKitProjects.Web.ProjectShowLive, :gantt}
      },
      %Tab{
        id: :admin_projects_project_tasks_calendar,
        label: "Calendar",
        gettext_backend: PhoenixKitProjects.Gettext,
        gettext_domain: "default",
        path: "projects/:id/tasks/calendar",
        level: :admin,
        permission: module_key(),
        parent: :admin_projects,
        visible: false,
        live_view: {PhoenixKitProjects.Web.ProjectShowLive, :calendar}
      },
      %Tab{
        id: :admin_projects_project_comments,
        label: "Comments",
        gettext_backend: PhoenixKitProjects.Gettext,
        gettext_domain: "default",
        path: "projects/:id/comments",
        level: :admin,
        permission: module_key(),
        parent: :admin_projects,
        visible: false,
        live_view: {PhoenixKitProjects.Web.ProjectShowLive, :comments}
      },
      %Tab{
        id: :admin_projects_project_history,
        label: "History",
        gettext_backend: PhoenixKitProjects.Gettext,
        gettext_domain: "default",
        path: "projects/:id/history",
        level: :admin,
        permission: module_key(),
        parent: :admin_projects,
        visible: false,
        live_view: {PhoenixKitProjects.Web.ProjectShowLive, :history}
      },
      %Tab{
        id: :admin_projects_template_new,
        label: "New Template",
        gettext_backend: PhoenixKitProjects.Gettext,
        gettext_domain: "default",
        path: "projects/templates/new",
        level: :admin,
        permission: module_key(),
        parent: :admin_projects,
        visible: false,
        live_view: {PhoenixKitProjects.Web.TemplateFormLive, :new}
      },
      %Tab{
        id: :admin_projects_template_edit,
        label: "Edit Template",
        gettext_backend: PhoenixKitProjects.Gettext,
        gettext_domain: "default",
        path: "projects/templates/:id/edit",
        level: :admin,
        permission: module_key(),
        parent: :admin_projects,
        visible: false,
        live_view: {PhoenixKitProjects.Web.TemplateFormLive, :edit}
      },
      %Tab{
        id: :admin_projects_template_show,
        label: "Template",
        gettext_backend: PhoenixKitProjects.Gettext,
        gettext_domain: "default",
        path: "projects/templates/:id",
        level: :admin,
        permission: module_key(),
        parent: :admin_projects,
        visible: false,
        live_view: {PhoenixKitProjects.Web.ProjectShowLive, :show_template}
      },
      %Tab{
        id: :admin_projects_assignment_new,
        label: "Add Task",
        gettext_backend: PhoenixKitProjects.Gettext,
        gettext_domain: "default",
        path: "projects/:project_id/assignments/new",
        level: :admin,
        permission: module_key(),
        parent: :admin_projects,
        visible: false,
        live_view: {PhoenixKitProjects.Web.AssignmentFormLive, :new}
      },
      %Tab{
        id: :admin_projects_assignment_edit,
        label: "Edit Assignment",
        gettext_backend: PhoenixKitProjects.Gettext,
        gettext_domain: "default",
        path: "projects/:project_id/assignments/:id/edit",
        level: :admin,
        permission: module_key(),
        parent: :admin_projects,
        visible: false,
        live_view: {PhoenixKitProjects.Web.AssignmentFormLive, :edit}
      },
      %Tab{
        id: :admin_projects_assignment_view,
        label: "Task",
        gettext_backend: PhoenixKitProjects.Gettext,
        gettext_domain: "default",
        path: "projects/:project_id/assignments/:id",
        level: :admin,
        permission: module_key(),
        parent: :admin_projects,
        visible: false,
        live_view: {PhoenixKitProjects.Web.AssignmentViewLive, :show}
      },
      # `/projects/:id/<extension tab>` — LAST on purpose: Phoenix matches in
      # declaration order, so every literal sibling above (edit, files,
      # members, modules, api, activity, board, gantt, calendar, tasks, comments,
      # history)
      # AND `projects/templates/*` (whose first segment would otherwise read
      # as an id) win before this catch-all; an unknown segment lands on the
      # project's first tab. Extension tab keys must not reuse those literals.
      %Tab{
        id: :admin_projects_project_ext_tab,
        label: "Project",
        gettext_backend: PhoenixKitProjects.Gettext,
        gettext_domain: "default",
        path: "projects/:id/:tab",
        level: :admin,
        permission: module_key(),
        parent: :admin_projects,
        visible: false,
        live_view: {PhoenixKitProjects.Web.ProjectShowLive, :ext_tab}
      }
    ]

    parent ++ visible_subtabs ++ hidden_subtabs
  end

  @impl PhoenixKit.Module
  # The member-facing surface (Phase I): a "My Projects" page on the USER
  # dashboard — membership-gated, no admin permission. The `live_view`
  # field makes core's authenticated route table generate
  # `/dashboard/projects` automatically (the user_dashboard_tabs route
  # discovery this module is the first consumer of).
  def user_dashboard_tabs do
    [
      %Tab{
        id: :dashboard_projects,
        label: "My Projects",
        gettext_backend: PhoenixKitProjects.Gettext,
        gettext_domain: "default",
        icon: "hero-briefcase",
        path: "projects",
        priority: 250,
        match: :prefix,
        group: :main,
        live_view: {PhoenixKitProjects.Web.MemberProjectsLive, :index}
      }
    ]
  end

  @impl PhoenixKit.Module
  def settings_tabs do
    [
      Tab.new!(
        id: :admin_settings_projects,
        label: "Projects",
        gettext_backend: PhoenixKitProjects.Gettext,
        gettext_domain: "default",
        icon: "hero-clipboard-document-list",
        path: "projects",
        priority: 930,
        level: :admin,
        parent: :admin_settings,
        # The settings page is its own sub-key, not the everyday base key.
        permission: Authz.settings_key(),
        live_view: {PhoenixKitProjects.Web.ProjectsSettingsLive, :settings}
      )
    ]
  end
end
