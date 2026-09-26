defmodule PhoenixKitProjects.MediaReorganizerTest do
  @moduledoc false
  use PhoenixKitProjects.DataCase, async: false

  import Ecto.Query
  import ExUnit.CaptureLog

  alias PhoenixKit.Modules.Storage
  alias PhoenixKit.Users.Auth
  alias PhoenixKitProjects.Attachments
  alias PhoenixKitProjects.MediaReorganizer
  alias PhoenixKitProjects.Projects
  alias PhoenixKitProjects.QueryCounter
  alias PhoenixKitProjects.Schemas.Project
  alias PhoenixKitProjects.Test.Repo

  defmodule Hook do
    @moduledoc false
    def parent(:project, _actor, %Project{} = resource) do
      bump(:parent_calls)
      Process.put(:last_parent_resource, resource)
      parent_result(resource)
    end

    def parent(_kind, _actor, _resource), do: nil

    def name(%Project{} = resource, _actor) do
      bump(:name_calls)
      name_result(resource)
    end

    def name(_resource, _actor), do: nil

    defp parent_result(_resource), do: {:ok, Process.get(:target_folder)}
    defp name_result(_resource), do: {:ok, Process.get(:target_name) || nil}

    defp bump(key), do: Process.put(key, (Process.get(key) || 0) + 1)
  end

  defmodule RaisingHook do
    @moduledoc false
    def parent(:project, _actor, _resource), do: raise("boom")
  end

  defmodule BadReturnHook do
    @moduledoc false
    def parent(:project, _actor, _resource), do: {:error, :timeout}
  end

  defmodule BareNilHook do
    @moduledoc false
    def parent(:project, _actor, _resource), do: nil
  end

  defmodule FullStructHook do
    @moduledoc false
    # Raises when handed a struct that dropped `description` — a light
    # select (`struct(p, [...])`) leaves it `nil`; only the full row
    # carries the seeded value. Proves the record reaching the hook is
    # the complete `Project` row (R9 amended).
    def parent(:project, _actor, %Project{description: description} = resource) do
      if is_nil(description), do: raise("missing struct field: description")
      Process.put(:last_parent_resource, resource)
      {:ok, Process.get(:target_folder)}
    end
  end

  defmodule BadUuidParentHook do
    @moduledoc false
    def parent(:project, _actor, _resource), do: {:ok, "not-a-uuid"}
  end

  defmodule RaisingNameHook do
    @moduledoc false
    def parent(:project, _actor, _resource), do: {:ok, Process.get(:target_folder)}
    def name(%Project{}, _actor), do: raise("boom")
  end

  defmodule BadReturnNameHook do
    @moduledoc false
    def parent(:project, _actor, _resource), do: {:ok, Process.get(:target_folder)}
    def name(%Project{}, _actor), do: :not_a_valid_answer
  end

  defmodule MixedHook do
    @moduledoc false
    # Fails the PARENT hook for the project named `:fail_parent_project_name`
    # and the NAME hook for the project named `:fail_name_project_name` —
    # lets one plan exercise both a parent-hook failure and a name-hook
    # failure among different candidates.
    def parent(:project, _actor, %Project{name: name}) do
      if name == Process.get(:fail_parent_project_name) do
        raise "boom parent"
      else
        {:ok, Process.get(:target_folder)}
      end
    end

    def name(%Project{name: name}, _actor) do
      if name == Process.get(:fail_name_project_name) do
        raise "boom name"
      else
        {:ok, nil}
      end
    end
  end

  setup do
    on_exit(fn ->
      Application.delete_env(:phoenix_kit_projects, :attachments_parent_folder)
      Application.delete_env(:phoenix_kit_projects, :attachments_folder_name)
    end)

    :ok
  end

  defp project!(attrs \\ %{}) do
    {:ok, project} =
      Projects.create_project(
        Map.merge(
          %{"name" => "P #{System.unique_integer([:positive])}", "start_mode" => "immediate"},
          attrs
        )
      )

    project
  end

  defp configure_parent_hook(target_folder_uuid) do
    Process.put(:target_folder, target_folder_uuid)
    Application.put_env(:phoenix_kit_projects, :attachments_parent_folder, {Hook, :parent})
  end

  defp configure_name_hook(name) do
    Process.put(:target_name, name)
    Application.put_env(:phoenix_kit_projects, :attachments_folder_name, {Hook, :name})
  end

  test "no hooks configured, legacy folder at root → nothing planned" do
    project = project!()
    {:ok, _folder} = Storage.create_folder(%{name: "project-#{project.uuid}"})

    actions = MediaReorganizer.plan(nil, [])
    refute Enum.any?(actions, &(&1.kind == :project and &1.label == project.name))
  end

  test "no hook, no legacy folder → no action" do
    project = project!()

    actions = MediaReorganizer.plan(nil, [])
    refute Enum.any?(actions, &(&1.kind == :project and &1.label == project.name))
  end

  test "no hook configured, legacy folder relocated away from root → left untouched" do
    project = project!()
    {:ok, elsewhere} = Storage.create_folder(%{name: "Somewhere else"})

    {:ok, _relocated} =
      Storage.create_folder(%{name: "project-#{project.uuid}", parent_uuid: elsewhere.uuid})

    actions = MediaReorganizer.plan(nil, [])
    refute Enum.any?(actions, &(&1.label == project.name))
  end

  # Files pages look the host name up at the root too, so the renamed
  # folder is still found.
  test "parent hook resolves nil, name hook resolves a host name → root legacy folder takes the host name in place" do
    project = project!(%{"name" => "Käepide"})
    {:ok, folder} = Storage.create_folder(%{name: "project-#{project.uuid}"})

    configure_parent_hook(nil)
    configure_name_hook("Host Name")

    actions = MediaReorganizer.plan(nil, [])
    action = Enum.find(actions, &(&1.label == project.name))
    assert %{op: :move, parent_uuid: nil, name: "Host Name"} = action
    assert action.folder.uuid == folder.uuid
  end

  test "parent hook configured, legacy folder at root → one move action, name kept" do
    project = project!(%{"name" => "Käepide"})
    {:ok, target} = Storage.create_folder(%{name: "Projects"})
    {:ok, folder} = Storage.create_folder(%{name: "project-#{project.uuid}"})

    configure_parent_hook(target.uuid)

    actions = MediaReorganizer.plan(nil, [])
    action = Enum.find(actions, &(&1.kind == :project and &1.label == project.name))

    refute is_nil(action)
    assert action.source == "projects"
    assert action.op == :move
    assert action.folder.uuid == folder.uuid
    assert action.parent_uuid == target.uuid
    assert action.name == folder.name
    assert action.on_conflict == :report
    assert action.counts == {0, 0}
    assert is_nil(action.after_move)
  end

  test "parent + name hooks configured → move and rename" do
    project = project!(%{"name" => "Käepide"})
    {:ok, target} = Storage.create_folder(%{name: "Projects"})
    {:ok, folder} = Storage.create_folder(%{name: "project-#{project.uuid}"})

    configure_parent_hook(target.uuid)
    configure_name_hook("Nice project")

    actions = MediaReorganizer.plan(nil, [])
    action = Enum.find(actions, &(&1.kind == :project and &1.label == project.name))

    refute is_nil(action)
    assert action.folder.uuid == folder.uuid
    assert action.parent_uuid == target.uuid
    assert action.name == "Nice project"
  end

  test "folder already at the right parent/name → nothing planned (no pointer, so never an after_move)" do
    project = project!()
    {:ok, target} = Storage.create_folder(%{name: "Projects"})

    {:ok, _folder} =
      Storage.create_folder(%{name: "project-#{project.uuid}", parent_uuid: target.uuid})

    configure_parent_hook(target.uuid)

    actions = MediaReorganizer.plan(nil, [])
    refute Enum.any?(actions, &(&1.kind == :project and &1.label == project.name))
  end

  test "a 'name (N)' suffix variant is never a candidate — nothing planned, hooks never called" do
    project = project!()
    {:ok, target} = Storage.create_folder(%{name: "Projects"})

    {:ok, _folder} =
      Storage.create_folder(%{
        name: "project-#{project.uuid} (2)",
        parent_uuid: target.uuid
      })

    configure_parent_hook(target.uuid)

    actions = MediaReorganizer.plan(nil, [])
    refute Enum.any?(actions, &(&1.label == project.name))
    refute Enum.any?(actions, &(&1.kind == :orphan))
    assert Process.get(:parent_calls) == nil
  end

  test "hook configured, legacy folder lives away from root/resolved parent → reported relocated, not moved" do
    project = project!()
    {:ok, target} = Storage.create_folder(%{name: "Projects"})
    {:ok, elsewhere} = Storage.create_folder(%{name: "Somewhere else"})

    {:ok, relocated} =
      Storage.create_folder(%{name: "project-#{project.uuid}", parent_uuid: elsewhere.uuid})

    configure_parent_hook(target.uuid)

    actions = MediaReorganizer.plan(nil, [])
    refute Enum.any?(actions, &(&1.op == :move and &1.label == project.name))

    action = Enum.find(actions, &(&1.kind == :relocated and &1.label == project.name))
    refute is_nil(action)
    assert action.op == :report
    assert action.folder.uuid == relocated.uuid
  end

  test "legacy-named twin live elsewhere is reported relocated alongside the project's own move (stray_legacy)" do
    project = project!()
    {:ok, target} = Storage.create_folder(%{name: "Projects"})
    {:ok, elsewhere} = Storage.create_folder(%{name: "Somewhere else"})
    {:ok, current} = Storage.create_folder(%{name: "project-#{project.uuid}"})

    {:ok, stray} =
      Storage.create_folder(%{name: "project-#{project.uuid}", parent_uuid: elsewhere.uuid})

    configure_parent_hook(target.uuid)

    actions = MediaReorganizer.plan(nil, [])

    move = Enum.find(actions, &(&1.kind == :project and &1.label == project.name))
    refute is_nil(move)
    assert move.op == :move
    assert move.folder.uuid == current.uuid

    relocated =
      Enum.find(
        actions,
        &(&1.kind == :relocated and &1.op == :report and &1.folder.uuid == stray.uuid)
      )

    refute is_nil(relocated)
    assert relocated.label == project.name
  end

  test "legacy folder live at both root and under the resolved parent → one duplicate report, no move" do
    project = project!()
    {:ok, target} = Storage.create_folder(%{name: "Projects"})
    {:ok, _root_folder} = Storage.create_folder(%{name: "project-#{project.uuid}"})

    {:ok, _under_folder} =
      Storage.create_folder(%{name: "project-#{project.uuid}", parent_uuid: target.uuid})

    configure_parent_hook(target.uuid)

    actions = MediaReorganizer.plan(nil, [])
    refute Enum.any?(actions, &(&1.op == :move and &1.label == project.name))

    action = Enum.find(actions, &(&1.kind == :duplicate and &1.label == project.name))
    refute is_nil(action)
    assert action.op == :report
  end

  test "hooks run exactly once per project across a batch, not once per project per lookup tier" do
    project1 = project!()
    project2 = project!()
    {:ok, target} = Storage.create_folder(%{name: "Projects"})
    {:ok, _f1} = Storage.create_folder(%{name: "project-#{project1.uuid}"})
    {:ok, _f2} = Storage.create_folder(%{name: "project-#{project2.uuid}"})

    configure_parent_hook(target.uuid)
    configure_name_hook("Nice project")

    _actions = MediaReorganizer.plan(nil, [])

    assert Process.get(:parent_calls) == 2
    assert Process.get(:name_calls) == 2
  end

  test "project without any legacy folder never triggers the hooks; a candidate triggers them once" do
    {:ok, target} = Storage.create_folder(%{name: "Projects"})
    configure_parent_hook(target.uuid)
    configure_name_hook("Nice project")

    _no_folder_project = project!()
    candidate = project!()
    {:ok, _folder} = Storage.create_folder(%{name: "project-#{candidate.uuid}"})

    _actions = MediaReorganizer.plan(nil, [])

    assert Process.get(:parent_calls) == 1
    assert Process.get(:name_calls) == 1
  end

  test "current-folder resolution is batched — statement count is flat regardless of project count needing a move" do
    {:ok, target} = Storage.create_folder(%{name: "Projects"})
    configure_parent_hook(target.uuid)

    project1 = project!()
    {:ok, _folder1} = Storage.create_folder(%{name: "project-#{project1.uuid}"})

    {actions_one, one_project_queries} =
      QueryCounter.count(fn -> MediaReorganizer.plan(nil, []) end)

    assert Enum.count(actions_one, &(&1.op == :move)) == 1

    for _ <- 1..4 do
      project = project!()
      {:ok, _folder} = Storage.create_folder(%{name: "project-#{project.uuid}"})
    end

    {actions_five, five_project_queries} =
      QueryCounter.count(fn -> MediaReorganizer.plan(nil, []) end)

    assert Enum.count(actions_five, &(&1.op == :move)) == 5
    assert five_project_queries == one_project_queries
  end

  describe "orphan folders" do
    test "legacy folder with no matching project record → orphan report with counts" do
      folder_uuid = Ecto.UUID.generate()
      {:ok, folder} = Storage.create_folder(%{name: "project-#{folder_uuid}"})

      actions = MediaReorganizer.plan(nil, [])
      action = Enum.find(actions, &(&1.kind == :orphan and &1.folder.uuid == folder.uuid))

      refute is_nil(action)
      assert action.source == "projects"
      assert action.op == :report
      assert action.counts == {0, 0}
      assert action.reason =~ "missing"
    end

    test "legacy folder with an uppercase uuid still matches its live project (not a false orphan)" do
      project = project!()
      {:ok, folder} = Storage.create_folder(%{name: "project-" <> String.upcase(project.uuid)})

      actions = MediaReorganizer.plan(nil, [])
      refute Enum.any?(actions, &(&1.kind == :orphan and &1.folder.uuid == folder.uuid))
    end

    test "malformed legacy-looking folder name is not treated as an orphan" do
      {:ok, folder} = Storage.create_folder(%{name: "project-not-a-real-uuid"})

      actions = MediaReorganizer.plan(nil, [])
      refute Enum.any?(actions, &(&1.kind == :orphan and &1.folder.uuid == folder.uuid))
    end

    test "legacy folder of a live project → not reported as orphan" do
      project = project!()
      {:ok, folder} = Storage.create_folder(%{name: "project-#{project.uuid}"})

      actions = MediaReorganizer.plan(nil, [])
      refute Enum.any?(actions, &(&1.kind == :orphan and &1.folder.uuid == folder.uuid))
    end

    test "legacy folder of an archived project → not reported as orphan (archived is live)" do
      project = project!()
      {:ok, folder} = Storage.create_folder(%{name: "project-#{project.uuid}"})
      {:ok, _project} = Projects.archive_project(project)

      actions = MediaReorganizer.plan(nil, [])
      refute Enum.any?(actions, &(&1.kind == :orphan and &1.folder.uuid == folder.uuid))
    end

    test "archived project's legacy folder still gets a move action (archived is live)" do
      project = project!()
      {:ok, project} = Projects.archive_project(project)
      {:ok, target} = Storage.create_folder(%{name: "Projects"})
      {:ok, folder} = Storage.create_folder(%{name: "project-#{project.uuid}"})

      configure_parent_hook(target.uuid)

      actions = MediaReorganizer.plan(nil, [])
      action = Enum.find(actions, &(&1.kind == :project and &1.label == project.name))

      refute is_nil(action)
      assert action.folder.uuid == folder.uuid
    end

    test "orphan candidates are also scanned under a resolved parent" do
      {:ok, target} = Storage.create_folder(%{name: "Projects"})
      configure_parent_hook(target.uuid)

      stray_uuid = Ecto.UUID.generate()

      {:ok, folder} =
        Storage.create_folder(%{name: "project-#{stray_uuid}", parent_uuid: target.uuid})

      # A live project with its own legacy folder so the hook resolves
      # `target` into `desired` and it lands in `resolved_parents`.
      project = project!()
      {:ok, _own_folder} = Storage.create_folder(%{name: "project-#{project.uuid}"})

      actions = MediaReorganizer.plan(nil, [])
      action = Enum.find(actions, &(&1.kind == :orphan and &1.folder.uuid == folder.uuid))

      refute is_nil(action)
    end

    test "a folder claimed via an ambiguous match is not also reported orphan (R4)" do
      project = project!()
      {:ok, target} = Storage.create_folder(%{name: "Projects"})
      {:ok, _own_folder} = Storage.create_folder(%{name: "project-#{project.uuid}"})

      # A different, deleted project's leftover legacy folder — live under
      # the resolved parent.
      other_uuid = Ecto.UUID.generate()

      {:ok, stray} =
        Storage.create_folder(%{name: "project-#{other_uuid}", parent_uuid: target.uuid})

      configure_parent_hook(target.uuid)
      # A naive host-name hook that (mis)resolves every project to the
      # same fixed string — here it happens to collide with the deleted
      # project's legacy folder name.
      configure_name_hook("project-#{other_uuid}")

      actions = MediaReorganizer.plan(nil, [])

      dup = Enum.find(actions, &(&1.kind == :duplicate and &1.op == :report))
      refute is_nil(dup)
      assert dup.reason =~ stray.uuid

      refute Enum.any?(actions, &(&1.kind == :orphan and &1.folder.uuid == stray.uuid))
    end
  end

  describe "shared destinations (X5)" do
    test "two projects whose current folder resolves to the same live folder → one duplicate report, no moves" do
      project1 = project!()
      project2 = project!()
      {:ok, target} = Storage.create_folder(%{name: "Projects"})
      {:ok, shared} = Storage.create_folder(%{name: "Shared name", parent_uuid: target.uuid})
      {:ok, elsewhere} = Storage.create_folder(%{name: "Elsewhere"})

      # Each project's own legacy folder lives somewhere unrelated to the
      # resolved parent/root — enough to make it a candidate, but never a
      # tier match, so only the shared "Shared name" folder resolves.
      {:ok, _folder1} =
        Storage.create_folder(%{name: "project-#{project1.uuid}", parent_uuid: elsewhere.uuid})

      {:ok, _folder2} =
        Storage.create_folder(%{name: "project-#{project2.uuid}", parent_uuid: elsewhere.uuid})

      configure_parent_hook(target.uuid)
      configure_name_hook("Shared name")

      actions = MediaReorganizer.plan(nil, [])

      refute Enum.any?(actions, &(&1.op == :move))

      dup =
        Enum.find(
          actions,
          &(&1.kind == :duplicate and &1.op == :report and &1.label == shared.name)
        )

      refute is_nil(dup)
      assert dup.reason =~ project1.name
      assert dup.reason =~ project2.name
    end
  end

  test "counts include a trashed file — the engine re-measures the same way at apply time" do
    {:ok, user} =
      Auth.register_user(%{
        "email" => "reorg-#{System.unique_integer([:positive])}@example.com",
        "password" => "ValidPassword123!"
      })

    project = project!()
    {:ok, target} = Storage.create_folder(%{name: "Projects"})
    {:ok, folder} = Storage.create_folder(%{name: "project-#{project.uuid}"})

    {:ok, _trashed_file} =
      Storage.create_file(%{
        original_file_name: "old.pdf",
        file_name: "old.pdf",
        mime_type: "application/pdf",
        file_type: "document",
        ext: "pdf",
        file_checksum: "checksum-trashed-#{System.unique_integer([:positive])}",
        user_file_checksum: "user-checksum-trashed-#{System.unique_integer([:positive])}",
        size: 10,
        status: "trashed",
        folder_uuid: folder.uuid,
        user_uuid: user.uuid
      })

    configure_parent_hook(target.uuid)

    actions = MediaReorganizer.plan(nil, [])
    action = Enum.find(actions, &(&1.kind == :project and &1.label == project.name))

    refute is_nil(action)
    assert action.counts == {1, 0}
  end

  describe "converging targets (R7)" do
    test "two projects whose desired destination coincides → one duplicate report, no moves" do
      project1 = project!()
      project2 = project!()
      {:ok, target} = Storage.create_folder(%{name: "Projects"})
      {:ok, _folder1} = Storage.create_folder(%{name: "project-#{project1.uuid}"})
      {:ok, _folder2} = Storage.create_folder(%{name: "project-#{project2.uuid}"})

      configure_parent_hook(target.uuid)
      # Both projects resolve to the very same host name — a naive host hook.
      configure_name_hook("Shared name")

      actions = MediaReorganizer.plan(nil, [])

      refute Enum.any?(actions, &(&1.op == :move))

      dup = Enum.find(actions, &(&1.kind == :duplicate and &1.op == :report))
      refute is_nil(dup)
      assert dup.label =~ project1.name
      assert dup.label =~ project2.name
    end

    test "two projects resolving to different destinations still move independently" do
      project1 = project!()
      project2 = project!()
      {:ok, target} = Storage.create_folder(%{name: "Projects"})
      {:ok, _folder1} = Storage.create_folder(%{name: "project-#{project1.uuid}"})
      {:ok, _folder2} = Storage.create_folder(%{name: "project-#{project2.uuid}"})

      configure_parent_hook(target.uuid)

      actions = MediaReorganizer.plan(nil, [])

      assert Enum.count(actions, &(&1.op == :move)) == 2
      refute Enum.any?(actions, &(&1.kind == :duplicate))
    end
  end

  describe "a noop's occupied destination never spuriously collides as a converging duplicate (U2/F6)" do
    test "an already-placed project and a would-be mover targeting the same slot both report shared, no move" do
      project1 = project!()
      project2 = project!()
      {:ok, target} = Storage.create_folder(%{name: "Projects"})
      {:ok, elsewhere} = Storage.create_folder(%{name: "Elsewhere"})

      # project1 already sits exactly at the resolved destination (a
      # genuine no-op for it) — plus keeps a stray copy of its own legacy
      # name elsewhere so it still qualifies as a candidate.
      {:ok, _already_placed} =
        Storage.create_folder(%{name: "Shared name", parent_uuid: target.uuid})

      {:ok, _stray1} =
        Storage.create_folder(%{name: "project-#{project1.uuid}", parent_uuid: elsewhere.uuid})

      # project2 has never moved — its own legacy folder lives elsewhere,
      # undetected by the desired-parent/root tiers, so the only match it
      # finds is project1's already-placed folder.
      {:ok, _folder2} =
        Storage.create_folder(%{name: "project-#{project2.uuid}", parent_uuid: elsewhere.uuid})

      configure_parent_hook(target.uuid)
      configure_name_hook("Shared name")

      actions = MediaReorganizer.plan(nil, [])

      # Neither project is silently left as a plain no-op, and neither is
      # moved into the occupied name — the already-placed folder is a
      # real conflict for project2, reported once, never a `:move`. Both
      # entries resolve to the SAME already-live folder (host_match), so
      # this is a `split_shared` collision, never a `split_converging`
      # one — the phantom converging-duplicate class this test guards
      # against is structurally unreachable here.
      refute Enum.any?(actions, &(&1.op == :move))

      dup = Enum.find(actions, &(&1.kind == :duplicate and &1.op == :report))
      refute is_nil(dup)
      assert dup.reason =~ "claimed by more than one project"
      assert dup.reason =~ project1.name
      assert dup.reason =~ project2.name
    end
  end

  describe "hook failures (R2)" do
    test "a parent hook that raises is a failure, not root — project skipped, reported once" do
      project = project!()
      {:ok, _folder} = Storage.create_folder(%{name: "project-#{project.uuid}"})

      Application.put_env(
        :phoenix_kit_projects,
        :attachments_parent_folder,
        {RaisingHook, :parent}
      )

      actions = MediaReorganizer.plan(nil, [])

      refute Enum.any?(actions, &(&1.kind == :project and &1.label == project.name))

      error_action = Enum.find(actions, &(&1.kind == :hook_error))
      refute is_nil(error_action)
      assert error_action.op == :report
      assert error_action.reason =~ "1"
    end

    test "a parent hook returning {:error, _} is a failure, not root" do
      project = project!()
      {:ok, _folder} = Storage.create_folder(%{name: "project-#{project.uuid}"})

      Application.put_env(
        :phoenix_kit_projects,
        :attachments_parent_folder,
        {BadReturnHook, :parent}
      )

      actions = MediaReorganizer.plan(nil, [])

      refute Enum.any?(actions, &(&1.kind == :project and &1.label == project.name))
      assert Enum.any?(actions, &(&1.kind == :hook_error))
    end

    test "a parent hook returning a bare nil is an explicit root, not a failure" do
      project = project!(%{"name" => "Käepide"})
      {:ok, folder} = Storage.create_folder(%{name: "project-#{project.uuid}"})

      Application.put_env(
        :phoenix_kit_projects,
        :attachments_parent_folder,
        {BareNilHook, :parent}
      )

      actions = MediaReorganizer.plan(nil, [])

      refute Enum.any?(actions, &(&1.kind == :hook_error))
      refute Enum.any?(actions, &(&1.kind == :project and &1.label == project.name))
      assert folder.parent_uuid == nil
    end

    test "two failing candidates are counted into one hook_error report" do
      project1 = project!()
      project2 = project!()
      {:ok, _folder1} = Storage.create_folder(%{name: "project-#{project1.uuid}"})
      {:ok, _folder2} = Storage.create_folder(%{name: "project-#{project2.uuid}"})

      Application.put_env(
        :phoenix_kit_projects,
        :attachments_parent_folder,
        {RaisingHook, :parent}
      )

      actions = MediaReorganizer.plan(nil, [])

      error_actions = Enum.filter(actions, &(&1.kind == :hook_error))
      assert length(error_actions) == 1
      assert hd(error_actions).reason =~ "2"
    end
  end

  test "relocated report mentions the hook may still resolve it for other actors (E6)" do
    project = project!()
    {:ok, target} = Storage.create_folder(%{name: "Projects"})
    {:ok, elsewhere} = Storage.create_folder(%{name: "Somewhere else"})

    {:ok, _relocated} =
      Storage.create_folder(%{name: "project-#{project.uuid}", parent_uuid: elsewhere.uuid})

    configure_parent_hook(target.uuid)

    actions = MediaReorganizer.plan(nil, [])
    action = Enum.find(actions, &(&1.kind == :relocated and &1.label == project.name))

    refute is_nil(action)
    assert action.reason =~ "actor"
  end

  test "candidate's full Project row reaches the parent hook, not a light struct (R9 amended)" do
    project = project!(%{"description" => "a very long description that must not be dropped"})
    {:ok, target} = Storage.create_folder(%{name: "Projects"})
    {:ok, _folder} = Storage.create_folder(%{name: "project-#{project.uuid}"})

    Process.put(:target_folder, target.uuid)

    Application.put_env(
      :phoenix_kit_projects,
      :attachments_parent_folder,
      {FullStructHook, :parent}
    )

    actions = MediaReorganizer.plan(nil, [])

    refute Enum.any?(actions, &(&1.kind == :hook_error))

    resource = Process.get(:last_parent_resource)
    refute is_nil(resource)
    assert resource.uuid == project.uuid
    assert resource.description == "a very long description that must not be dropped"
  end

  describe "uncallable hook (T3)" do
    test "a configured parent hook whose module/function does not exist is a distinct failure from no hook" do
      project = project!()
      {:ok, _folder} = Storage.create_folder(%{name: "project-#{project.uuid}"})

      Application.put_env(
        :phoenix_kit_projects,
        :attachments_parent_folder,
        {NoSuchModuleForMediaReorganizerTest, :parent}
      )

      actions = MediaReorganizer.plan(nil, [])

      refute Enum.any?(actions, &(&1.kind == :project and &1.label == project.name))

      error_action = Enum.find(actions, &(&1.kind == :hook_error))
      refute is_nil(error_action)
      assert error_action.reason =~ "not callable"
    end

    test "a parent hook answering a non-uuid string is a failure, never sent into a query (T1)" do
      project = project!()
      {:ok, _folder} = Storage.create_folder(%{name: "project-#{project.uuid}"})

      Application.put_env(
        :phoenix_kit_projects,
        :attachments_parent_folder,
        {BadUuidParentHook, :parent}
      )

      actions = MediaReorganizer.plan(nil, [])

      refute Enum.any?(actions, &(&1.kind == :project and &1.label == project.name))
      assert Enum.any?(actions, &(&1.kind == :hook_error))
    end
  end

  describe "garbage (not even a well-shaped tuple) parent hook config is a hook_error, never silent no-hook (V3/U7)" do
    test "a bare string config is a hook_error, no moves" do
      project = project!()
      {:ok, _folder} = Storage.create_folder(%{name: "project-#{project.uuid}"})

      Application.put_env(:phoenix_kit_projects, :attachments_parent_folder, "garbage")

      actions = MediaReorganizer.plan(nil, [])

      refute Enum.any?(actions, &(&1.kind == :project and &1.label == project.name))
      error_action = Enum.find(actions, &(&1.kind == :hook_error))
      refute is_nil(error_action)
      assert error_action.reason =~ "not callable"
    end

    test "a wrong-arity tuple config is a hook_error, no moves" do
      project = project!()
      {:ok, _folder} = Storage.create_folder(%{name: "project-#{project.uuid}"})

      Application.put_env(
        :phoenix_kit_projects,
        :attachments_parent_folder,
        {Hook, :parent, :extra}
      )

      actions = MediaReorganizer.plan(nil, [])

      refute Enum.any?(actions, &(&1.kind == :project and &1.label == project.name))
      assert Enum.any?(actions, &(&1.kind == :hook_error))
    end

    test "a tuple of non-atoms config is a hook_error, no moves" do
      project = project!()
      {:ok, _folder} = Storage.create_folder(%{name: "project-#{project.uuid}"})

      Application.put_env(:phoenix_kit_projects, :attachments_parent_folder, {"Hook", "parent"})

      actions = MediaReorganizer.plan(nil, [])

      refute Enum.any?(actions, &(&1.kind == :project and &1.label == project.name))
      assert Enum.any?(actions, &(&1.kind == :hook_error))
    end
  end

  describe "name hook (R8/F3/T9)" do
    test "the name hook is never called for a project with no folder" do
      _project = project!()

      configure_parent_hook(nil)
      configure_name_hook("Host Name")

      _actions = MediaReorganizer.plan(nil, [])

      refute Process.get(:name_calls)
    end

    test "a raising name hook is a hook error, not a silent fallback to the legacy name" do
      project = project!()
      {:ok, target} = Storage.create_folder(%{name: "Projects"})
      {:ok, _folder} = Storage.create_folder(%{name: "project-#{project.uuid}"})

      Process.put(:target_folder, target.uuid)

      Application.put_env(
        :phoenix_kit_projects,
        :attachments_parent_folder,
        {RaisingNameHook, :parent}
      )

      Application.put_env(
        :phoenix_kit_projects,
        :attachments_folder_name,
        {RaisingNameHook, :name}
      )

      actions = MediaReorganizer.plan(nil, [])

      refute Enum.any?(actions, &(&1.kind == :project and &1.label == project.name))
      error_action = Enum.find(actions, &(&1.kind == :hook_error))
      refute is_nil(error_action)
    end

    test "a name hook returning a non-string, non-nil answer is a hook error" do
      project = project!()
      {:ok, target} = Storage.create_folder(%{name: "Projects"})
      {:ok, _folder} = Storage.create_folder(%{name: "project-#{project.uuid}"})

      Process.put(:target_folder, target.uuid)

      Application.put_env(
        :phoenix_kit_projects,
        :attachments_parent_folder,
        {BadReturnNameHook, :parent}
      )

      Application.put_env(
        :phoenix_kit_projects,
        :attachments_folder_name,
        {BadReturnNameHook, :name}
      )

      actions = MediaReorganizer.plan(nil, [])

      refute Enum.any?(actions, &(&1.kind == :project and &1.label == project.name))
      assert Enum.any?(actions, &(&1.kind == :hook_error))
    end
  end

  describe "every stray copy is reported, not only the first (F5)" do
    test "two legacy-named twins live elsewhere both get their own relocated report" do
      project = project!()
      {:ok, target} = Storage.create_folder(%{name: "Projects"})
      {:ok, elsewhere1} = Storage.create_folder(%{name: "Elsewhere one"})
      {:ok, elsewhere2} = Storage.create_folder(%{name: "Elsewhere two"})
      {:ok, current} = Storage.create_folder(%{name: "project-#{project.uuid}"})

      {:ok, stray1} =
        Storage.create_folder(%{name: "project-#{project.uuid}", parent_uuid: elsewhere1.uuid})

      {:ok, stray2} =
        Storage.create_folder(%{name: "project-#{project.uuid}", parent_uuid: elsewhere2.uuid})

      configure_parent_hook(target.uuid)

      actions = MediaReorganizer.plan(nil, [])

      move = Enum.find(actions, &(&1.kind == :project and &1.label == project.name))
      refute is_nil(move)
      assert move.folder.uuid == current.uuid

      relocated_uuids =
        actions
        |> Enum.filter(&(&1.kind == :relocated and &1.label == project.name))
        |> Enum.map(& &1.folder.uuid)
        |> Enum.sort()

      assert relocated_uuids == Enum.sort([stray1.uuid, stray2.uuid])
    end
  end

  describe "a stray copy beside an ambiguous match is still reported" do
    test "legacy folder at root AND under the target, plus a third copy elsewhere → duplicate + relocated" do
      project = project!()
      {:ok, target} = Storage.create_folder(%{name: "Projects"})
      {:ok, elsewhere} = Storage.create_folder(%{name: "Elsewhere"})
      {:ok, root_folder} = Storage.create_folder(%{name: "project-#{project.uuid}"})

      {:ok, under_folder} =
        Storage.create_folder(%{name: "project-#{project.uuid}", parent_uuid: target.uuid})

      {:ok, stray} =
        Storage.create_folder(%{name: "project-#{project.uuid}", parent_uuid: elsewhere.uuid})

      configure_parent_hook(target.uuid)

      actions = MediaReorganizer.plan(nil, [])
      refute Enum.any?(actions, &(&1.op == :move))

      assert [_dup] = Enum.filter(actions, &(&1.kind == :duplicate and &1.label == project.name))

      relocated = Enum.filter(actions, &(&1.kind == :relocated and &1.label == project.name))
      assert Enum.map(relocated, & &1.folder.uuid) == [stray.uuid]
      assert hd(relocated).reason =~ "Elsewhere"

      refute Enum.any?(
               relocated,
               &(&1.folder.uuid in [root_folder.uuid, under_folder.uuid])
             )
    end
  end

  describe "R10 deterministic order" do
    test "move actions follow the same inserted_at/uuid order as the candidate query, not a group_by map's iteration order" do
      {:ok, target} = Storage.create_folder(%{name: "Projects"})
      configure_parent_hook(target.uuid)

      projects =
        for _ <- 1..8 do
          project = project!()
          {:ok, _folder} = Storage.create_folder(%{name: "project-#{project.uuid}"})
          project
        end

      candidate_uuids = Enum.map(projects, & &1.uuid)

      # The order the implementation's own candidate query promises
      # (`inserted_at`/`uuid`) — `inserted_at` has second precision
      # (`timestamps(type: :utc_datetime)`), so a batch created within the
      # same test can legitimately tie and fall to the uuid tiebreak; the
      # plan's order must match this query's order exactly, not the wall-
      # clock sequence the projects happened to be created in.
      expected_names =
        Project
        |> where([p], p.uuid in ^candidate_uuids)
        |> order_by([p], asc: p.inserted_at, asc: p.uuid)
        |> select([p], p.name)
        |> Repo.all()

      actions = MediaReorganizer.plan(nil, [])

      move_labels =
        actions
        |> Enum.filter(&(&1.kind == :project and &1.label in expected_names))
        |> Enum.map(& &1.label)

      assert move_labels == expected_names
    end
  end

  describe "nil hook answer never moves a nested folder to root (F1)" do
    test "parent hook resolves nil while the folder lives under a different parent → hook_nil report, not moved" do
      project = project!()
      {:ok, old_parent} = Storage.create_folder(%{name: "Old parent"})

      {:ok, _folder} =
        Storage.create_folder(%{name: "project-#{project.uuid}", parent_uuid: old_parent.uuid})

      configure_parent_hook(nil)

      actions = MediaReorganizer.plan(nil, [])

      refute Enum.any?(actions, &(&1.op == :move and &1.label == project.name))
      refute Enum.any?(actions, &(&1.kind == :relocated))

      hook_nil = Enum.find(actions, &(&1.kind == :hook_nil))

      refute is_nil(hook_nil)
      assert hook_nil.op == :report
      assert hook_nil.reason =~ "1 record(s)"
    end
  end

  describe "duplicate: host-named and legacy-named folders both live under the same parent (§11 R3)" do
    test "host-named and deterministic-named folders both live under the resolved parent → duplicate, no move" do
      project = project!()
      {:ok, target} = Storage.create_folder(%{name: "Projects"})

      {:ok, _host_folder} =
        Storage.create_folder(%{name: "Nice project", parent_uuid: target.uuid})

      {:ok, _legacy_folder} =
        Storage.create_folder(%{name: "project-#{project.uuid}", parent_uuid: target.uuid})

      configure_parent_hook(target.uuid)
      configure_name_hook("Nice project")

      actions = MediaReorganizer.plan(nil, [])

      refute Enum.any?(actions, &(&1.op == :move and &1.label == project.name))

      dup = Enum.find(actions, &(&1.kind == :duplicate and &1.label == project.name))
      refute is_nil(dup)
      assert dup.op == :report
    end
  end

  describe "rename in place under the resolved parent" do
    test "folder already under the resolved parent, name hook picks a host name → renamed without moving parents" do
      project = project!()
      {:ok, target} = Storage.create_folder(%{name: "Projects"})

      {:ok, folder} =
        Storage.create_folder(%{name: "project-#{project.uuid}", parent_uuid: target.uuid})

      configure_parent_hook(target.uuid)
      configure_name_hook("Nice project")

      actions = MediaReorganizer.plan(nil, [])
      action = Enum.find(actions, &(&1.kind == :project and &1.label == project.name))

      refute is_nil(action)
      assert action.op == :move
      assert action.folder.uuid == folder.uuid
      assert action.parent_uuid == target.uuid
      assert folder.parent_uuid == target.uuid
      assert action.name == "Nice project"
    end
  end

  describe "relocated reason names the actual place (U3)" do
    test "a stray copy under a third-party parent names that parent" do
      project = project!()
      {:ok, target} = Storage.create_folder(%{name: "Projects"})
      {:ok, elsewhere} = Storage.create_folder(%{name: "Elsewhere HQ"})

      {:ok, current} = Storage.create_folder(%{name: "project-#{project.uuid}"})

      {:ok, stray} =
        Storage.create_folder(%{name: "project-#{project.uuid}", parent_uuid: elsewhere.uuid})

      configure_parent_hook(target.uuid)

      actions = MediaReorganizer.plan(nil, [])

      relocated = Enum.find(actions, &(&1.kind == :relocated and &1.folder.uuid == stray.uuid))
      refute is_nil(relocated)
      assert relocated.reason =~ "Elsewhere HQ"
      refute is_nil(Enum.find(actions, &(&1.folder && &1.folder.uuid == current.uuid)))
    end

    test "a stray copy with no adopted current folder at all is reported by its own parent's name" do
      project = project!()
      {:ok, target} = Storage.create_folder(%{name: "Projects"})
      {:ok, elsewhere} = Storage.create_folder(%{name: "Somewhere else"})

      {:ok, relocated_folder} =
        Storage.create_folder(%{name: "project-#{project.uuid}", parent_uuid: elsewhere.uuid})

      configure_parent_hook(target.uuid)

      actions = MediaReorganizer.plan(nil, [])

      action = Enum.find(actions, &(&1.kind == :relocated and &1.label == project.name))
      refute is_nil(action)
      assert action.folder.uuid == relocated_folder.uuid
      assert action.reason =~ "Somewhere else"
    end
  end

  describe "not-callable name hook is a hook error, not a silent fallback (U7/V3)" do
    test "a configured name hook whose module/function does not exist is reported, never a silent legacy-name move" do
      project = project!()
      {:ok, target} = Storage.create_folder(%{name: "Projects"})
      {:ok, _folder} = Storage.create_folder(%{name: "project-#{project.uuid}"})

      configure_parent_hook(target.uuid)

      Application.put_env(
        :phoenix_kit_projects,
        :attachments_folder_name,
        {NoSuchModuleForMediaReorganizerTest, :name}
      )

      actions = MediaReorganizer.plan(nil, [])

      refute Enum.any?(actions, &(&1.kind == :project and &1.label == project.name))
      error_action = Enum.find(actions, &(&1.kind == :hook_error))
      refute is_nil(error_action)
    end
  end

  describe "garbage (not even a well-shaped tuple) name hook config is a hook_error, never a silent deterministic-name fallback (V3/U7)" do
    test "a bare string config is a hook_error, no silent deterministic-name move" do
      project = project!()
      {:ok, target} = Storage.create_folder(%{name: "Projects"})
      {:ok, _folder} = Storage.create_folder(%{name: "project-#{project.uuid}"})

      configure_parent_hook(target.uuid)
      Application.put_env(:phoenix_kit_projects, :attachments_folder_name, "garbage")

      actions = MediaReorganizer.plan(nil, [])

      refute Enum.any?(actions, &(&1.kind == :project and &1.label == project.name))
      error_action = Enum.find(actions, &(&1.kind == :hook_error))
      refute is_nil(error_action)
    end

    test "a wrong-arity tuple config is a hook_error, no silent deterministic-name move" do
      project = project!()
      {:ok, target} = Storage.create_folder(%{name: "Projects"})
      {:ok, _folder} = Storage.create_folder(%{name: "project-#{project.uuid}"})

      configure_parent_hook(target.uuid)

      Application.put_env(
        :phoenix_kit_projects,
        :attachments_folder_name,
        {Hook, :name, :extra}
      )

      actions = MediaReorganizer.plan(nil, [])

      refute Enum.any?(actions, &(&1.kind == :project and &1.label == project.name))
      assert Enum.any?(actions, &(&1.kind == :hook_error))
    end
  end

  describe "hook log lines carry {mod, fun} and bad returns are logged (U6)" do
    test "a parent hook returning a bad value is logged with the module and function" do
      project = project!()
      {:ok, _folder} = Storage.create_folder(%{name: "project-#{project.uuid}"})

      Application.put_env(
        :phoenix_kit_projects,
        :attachments_parent_folder,
        {BadReturnHook, :parent}
      )

      log = capture_log(fn -> MediaReorganizer.plan(nil, []) end)

      assert log =~ "BadReturnHook"
      assert log =~ "parent"
      assert log =~ ":timeout"
    end

    test "a parent hook returning a non-uuid string is logged with the bad value" do
      project = project!()
      {:ok, _folder} = Storage.create_folder(%{name: "project-#{project.uuid}"})

      Application.put_env(
        :phoenix_kit_projects,
        :attachments_parent_folder,
        {BadUuidParentHook, :parent}
      )

      log = capture_log(fn -> MediaReorganizer.plan(nil, []) end)

      # The answer's shape, not its text: an answer can carry the hook's arguments.
      assert log =~ "BadUuidParentHook"
      assert log =~ "not a uuid"
    end

    test "a name hook returning a bad value is logged with the module and function" do
      project = project!()
      {:ok, target} = Storage.create_folder(%{name: "Projects"})
      {:ok, _folder} = Storage.create_folder(%{name: "project-#{project.uuid}"})

      Process.put(:target_folder, target.uuid)

      Application.put_env(
        :phoenix_kit_projects,
        :attachments_parent_folder,
        {BadReturnNameHook, :parent}
      )

      Application.put_env(
        :phoenix_kit_projects,
        :attachments_folder_name,
        {BadReturnNameHook, :name}
      )

      log = capture_log(fn -> MediaReorganizer.plan(nil, []) end)

      assert log =~ "BadReturnNameHook"
      assert log =~ "not_a_valid_answer"
    end
  end

  describe "hook_error/hook_nil reports list record labels, not only a count (U8)" do
    test "hook_error report names the failing records" do
      project1 = project!(%{"name" => "Alpha Project"})
      project2 = project!(%{"name" => "Beta Project"})
      {:ok, _f1} = Storage.create_folder(%{name: "project-#{project1.uuid}"})
      {:ok, _f2} = Storage.create_folder(%{name: "project-#{project2.uuid}"})

      Application.put_env(
        :phoenix_kit_projects,
        :attachments_parent_folder,
        {RaisingHook, :parent}
      )

      actions = MediaReorganizer.plan(nil, [])

      error_action = Enum.find(actions, &(&1.kind == :hook_error))
      assert error_action.reason =~ "Alpha Project"
      assert error_action.reason =~ "Beta Project"
    end

    test "hook_error report lists at most 10 labels, then a trailing count" do
      projects =
        for i <- 1..12 do
          p = project!(%{"name" => "Proj #{i}"})
          {:ok, _f} = Storage.create_folder(%{name: "project-#{p.uuid}"})
          p
        end

      Application.put_env(
        :phoenix_kit_projects,
        :attachments_parent_folder,
        {RaisingHook, :parent}
      )

      actions = MediaReorganizer.plan(nil, [])

      error_action = Enum.find(actions, &(&1.kind == :hook_error))
      assert error_action.reason =~ "12 record(s)"
      assert error_action.reason =~ "… and 2 more"

      shown = Enum.count(projects, &(error_action.reason =~ &1.name))
      assert shown == 10
    end

    test "hook_nil report names the adopted record" do
      project = project!(%{"name" => "Gamma Project"})
      {:ok, old_parent} = Storage.create_folder(%{name: "Old parent"})

      {:ok, _folder} =
        Storage.create_folder(%{name: "project-#{project.uuid}", parent_uuid: old_parent.uuid})

      configure_parent_hook(nil)

      actions = MediaReorganizer.plan(nil, [])

      hook_nil = Enum.find(actions, &(&1.kind == :hook_nil))
      refute is_nil(hook_nil)
      assert hook_nil.reason =~ "Gamma Project"
    end
  end

  describe "hook_error report names the actual failing hook (N4-3)" do
    test "a parent-hook-only failure is reported as the parent hook" do
      project = project!(%{"name" => "Only Parent Fails"})
      {:ok, _folder} = Storage.create_folder(%{name: "project-#{project.uuid}"})

      Application.put_env(
        :phoenix_kit_projects,
        :attachments_parent_folder,
        {RaisingHook, :parent}
      )

      actions = MediaReorganizer.plan(nil, [])

      error_action = Enum.find(actions, &(&1.kind == :hook_error))
      assert error_action.label == "attachments parent hook"
      assert error_action.reason =~ "the configured parent hook"
    end

    test "a name-hook-only failure is reported as the folder-name hook, not the parent hook" do
      project = project!(%{"name" => "Only Name Fails"})
      {:ok, target} = Storage.create_folder(%{name: "Projects"})
      {:ok, _folder} = Storage.create_folder(%{name: "project-#{project.uuid}"})

      configure_parent_hook(target.uuid)

      Application.put_env(
        :phoenix_kit_projects,
        :attachments_folder_name,
        {RaisingNameHook, :name}
      )

      actions = MediaReorganizer.plan(nil, [])

      error_action = Enum.find(actions, &(&1.kind == :hook_error))
      refute is_nil(error_action)
      assert error_action.label == "attachments folder-name hook"
      assert error_action.reason =~ "the configured folder-name hook"
      refute error_action.reason =~ "the configured parent hook"
    end

    test "a parent-hook failure and a name-hook failure among different candidates are reported as both hooks" do
      parent_fail_project = project!(%{"name" => "Parent Fails Here"})
      name_fail_project = project!(%{"name" => "Name Fails Here"})
      {:ok, target} = Storage.create_folder(%{name: "Projects"})

      {:ok, _f1} = Storage.create_folder(%{name: "project-#{parent_fail_project.uuid}"})
      {:ok, _f2} = Storage.create_folder(%{name: "project-#{name_fail_project.uuid}"})

      # `name_fail_project`'s parent must resolve to a real (non-root)
      # folder — the name hook is only ever called when a parent WAS
      # resolved (R8) — so its name-hook failure is actually exercised.
      Process.put(:target_folder, target.uuid)
      Process.put(:fail_parent_project_name, parent_fail_project.name)
      Process.put(:fail_name_project_name, name_fail_project.name)
      Application.put_env(:phoenix_kit_projects, :attachments_parent_folder, {MixedHook, :parent})
      Application.put_env(:phoenix_kit_projects, :attachments_folder_name, {MixedHook, :name})

      actions = MediaReorganizer.plan(nil, [])

      error_action = Enum.find(actions, &(&1.kind == :hook_error))
      refute is_nil(error_action)
      assert error_action.label == "attachments hooks"
      assert error_action.reason =~ "the configured parent/folder-name hooks"
      assert error_action.reason =~ parent_fail_project.name
      assert error_action.reason =~ name_fail_project.name
    end
  end

  describe "orphan scope includes every parent a successful hook answer resolved (U4)" do
    test "a candidate's parent hook succeeds but its name hook fails afterwards — the parent still scopes the orphan scan" do
      project = project!()
      {:ok, parent} = Storage.create_folder(%{name: "Sub-order folder"})

      {:ok, _folder} =
        Storage.create_folder(%{name: "project-#{project.uuid}", parent_uuid: parent.uuid})

      orphan_uuid = Ecto.UUID.generate()

      {:ok, orphan_folder} =
        Storage.create_folder(%{name: "project-#{orphan_uuid}", parent_uuid: parent.uuid})

      Process.put(:target_folder, parent.uuid)

      Application.put_env(
        :phoenix_kit_projects,
        :attachments_parent_folder,
        {RaisingNameHook, :parent}
      )

      Application.put_env(
        :phoenix_kit_projects,
        :attachments_folder_name,
        {RaisingNameHook, :name}
      )

      actions = MediaReorganizer.plan(nil, [])

      assert Enum.any?(actions, &(&1.kind == :hook_error))

      orphan_action =
        Enum.find(actions, &(&1.kind == :orphan and &1.folder.uuid == orphan_folder.uuid))

      refute is_nil(orphan_action)
    end
  end

  describe "parity with Attachments.find_resource_folder/2 (N10)" do
    test "no legacy folder anywhere → neither the source nor find_resource_folder/2 finds a current folder" do
      project = project!()

      refute Enum.any?(MediaReorganizer.plan(nil, []), &(&1.label == project.name))
      assert Attachments.find_resource_folder(project, nil) == nil
    end

    test "a folder that needs to move → the planned move's folder is the same one find_resource_folder/2 resolves before the move" do
      project = project!()
      {:ok, target} = Storage.create_folder(%{name: "Projects"})
      {:ok, folder} = Storage.create_folder(%{name: "project-#{project.uuid}"})

      configure_parent_hook(target.uuid)

      move =
        Enum.find(
          MediaReorganizer.plan(nil, []),
          &(&1.kind == :project and &1.label == project.name)
        )

      refute is_nil(move)
      assert move.folder.uuid == folder.uuid

      assert Attachments.find_resource_folder(project, nil).uuid == folder.uuid
    end

    test "a folder already exactly at the resolved target → no move planned, matching find_resource_folder/2" do
      project = project!()
      {:ok, target} = Storage.create_folder(%{name: "Projects"})

      {:ok, folder} =
        Storage.create_folder(%{name: "project-#{project.uuid}", parent_uuid: target.uuid})

      configure_parent_hook(target.uuid)

      refute Enum.any?(
               MediaReorganizer.plan(nil, []),
               &(&1.kind == :project and &1.label == project.name)
             )

      assert Attachments.find_resource_folder(project, nil).uuid == folder.uuid
    end

    test "hook resolves root while the only live copy sits under a real parent (F1) → left in place, matching find_resource_folder/2's own fallback" do
      project = project!()
      {:ok, old_parent} = Storage.create_folder(%{name: "Old parent"})

      {:ok, folder} =
        Storage.create_folder(%{name: "project-#{project.uuid}", parent_uuid: old_parent.uuid})

      configure_parent_hook(nil)

      actions = MediaReorganizer.plan(nil, [])
      refute Enum.any?(actions, &(&1.op == :move and &1.label == project.name))
      refute Enum.any?(actions, &(&1.kind == :relocated and &1.label == project.name))

      assert Attachments.find_resource_folder(project, nil).uuid == folder.uuid
    end
  end
end
