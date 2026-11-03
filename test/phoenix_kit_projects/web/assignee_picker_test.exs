defmodule PhoenixKitProjects.Web.AssigneePickerTest do
  @moduledoc """
  The one assignee picker (`Web.Components.AssigneePicker`), shared by the
  task and sub-project popups, and its Recent chips: the viewer's own picks
  first — remembered on their account, so one removed again is still a press
  away (the boss, 2026-10-30) — then whom this project's tasks went to, then
  the site's.
  """

  use PhoenixKitProjects.LiveCase, async: false

  alias PhoenixKit.Users.Auth
  alias PhoenixKitProjects.{Assignees, AssigneeSet, Projects}
  alias PhoenixKitProjects.Schemas.Assignment
  alias PhoenixKitProjects.Test.Repo
  alias PhoenixKitStaff.Schemas.Person

  setup %{conn: conn} do
    me = embed_user_uuid!()
    conn = put_test_scope(conn, fake_scope(user_uuid: me))
    project = fixture_project(%{"start_mode" => "immediate"})

    {:ok, %{assignment: a}} =
      Projects.create_task_with_assignment(
        project.uuid,
        %{"title" => "Hang the cabinets", "ad_hoc" => true},
        %{}
      )

    {:ok, conn: conn, me: me, project: project, a: a}
  end

  defp person!(name) do
    {:ok, user} =
      Auth.register_user(%{
        "email" => "#{String.downcase(name)}-#{System.unique_integer([:positive])}@example.com",
        "password" => "ValidPassword123!",
        "first_name" => name
      })

    Repo.insert!(%Person{user_uuid: user.uuid, status: "active", name: name})
  end

  defp edit(ctx),
    do: live(ctx.conn, "/en/admin/projects/#{ctx.project.uuid}/assignments/#{ctx.a.uuid}/edit")

  describe "remembering picks" do
    test "newest first, once each, at most ten, and other custom fields kept", ctx do
      user = Auth.get_user(ctx.me)

      {:ok, _} =
        Auth.merge_user_custom_fields(user, %{"phone" => "555"}, ensure_definitions: false)

      uuids = for _ <- 1..12, do: Ecto.UUID.generate()
      Enum.each(uuids, &Assignees.remember_pick(ctx.me, "person", &1))
      Assignees.remember_pick(ctx.me, "person", Enum.at(uuids, 5))

      picks = Assignees.remembered_picks(ctx.me)
      assert length(picks) == 10
      assert hd(picks) == {"person", Enum.at(uuids, 5)}
      assert Enum.uniq(picks) == picks

      assert Auth.get_user(ctx.me).custom_fields["phone"] == "555"
    end

    test "a forged kind is not remembered", ctx do
      Assignees.remember_pick(ctx.me, "user", Ecto.UUID.generate())
      assert Assignees.remembered_picks(ctx.me) == []
    end
  end

  describe "Recent" do
    test "a person picked and removed again stays in Recent", ctx do
      dora = person!("Dora")
      {:ok, view, _} = edit(ctx)
      refute has_element?(view, "#assignment-assignee-recent", "Dora")

      render_click(view, "assignee_pick", %{"kind" => "person", "uuid" => dora.uuid})
      assert has_element?(view, "#assignment-assignee-chip-person-#{dora.uuid}", "Dora")
      # A card above the field now, so not offered again in Recent.
      refute has_element?(view, "#assignment-assignee-recent", "Dora")

      render_click(view, "assignee_remove", %{"kind" => "person", "uuid" => dora.uuid})
      refute has_element?(view, "#assignment-assignee-chip-person-#{dora.uuid}")
      assert has_element?(view, "#assignment-assignee-recent", "Dora")

      # And on the next form the viewer opens.
      {:ok, view, _} = edit(ctx)
      assert has_element?(view, "#assignment-assignee-recent", "Dora")
    end

    test "the viewer's own picks come before the project's assignees", ctx do
      carl = person!("Carl")
      erik = person!("Erik")

      {:ok, _} =
        Projects.create_task_with_assignment(
          ctx.project.uuid,
          %{"title" => "Cut the boards", "ad_hoc" => true},
          %{"assigned_person_uuid" => carl.uuid}
        )

      Assignees.remember_pick(ctx.me, "person", erik.uuid)

      labels = Enum.map(Assignees.recent_for_viewer(ctx.me, ctx.project.uuid), & &1.label)
      assert Enum.find_index(labels, &(&1 == "Erik")) < Enum.find_index(labels, &(&1 == "Carl"))
    end

    test "a remembered person who has been trashed is not offered", ctx do
      gone = person!("Gone")
      Assignees.remember_pick(ctx.me, "person", gone.uuid)
      gone |> Ecto.Changeset.change(status: "trashed") |> Repo.update!()

      refute Enum.any?(
               Assignees.recent_for_viewer(ctx.me, ctx.project.uuid),
               &(&1.uuid == gone.uuid)
             )
    end
  end

  describe "several assignees (V29)" do
    test "ticks two from the lists, both saved; one removed from its chip", ctx do
      ann = person!("Annike")
      bo = person!("Boris")
      {:ok, view, _} = edit(ctx)

      render_click(view, "assignee_toggle", %{"kind" => "person", "uuid" => ann.uuid})
      render_click(view, "assignee_toggle", %{"kind" => "person", "uuid" => bo.uuid})
      assert has_element?(view, "#assignment-assignee-chip-person-#{ann.uuid}")
      assert has_element?(view, "#assignment-assignee-chip-person-#{bo.uuid}")

      render_submit(view, "save", %{
        "assignment" => %{"assignees" => ["", "person:#{ann.uuid}", "person:#{bo.uuid}"]}
      })

      keys = ctx.a.uuid |> Projects.get_assignment() |> PhoenixKitProjects.AssigneeSet.keys()
      assert keys == [{"person", ann.uuid}, {"person", bo.uuid}]

      {:ok, view, _} = edit(ctx)
      assert has_element?(view, "#assignment-assignee-chip-person-#{bo.uuid}")
      render_click(view, "assignee_remove", %{"kind" => "person", "uuid" => ann.uuid})
      refute has_element?(view, "#assignment-assignee-chip-person-#{ann.uuid}")
    end

    test "opens on sections; Browse more lists one kind with a way back", ctx do
      for i <- 1..6, do: person!("Browse#{i}")
      {:ok, view, _} = edit(ctx)

      assert has_element?(view, "#assignment-assignee-home-person")
      view |> element("#assignment-assignee-home-person-more") |> render_click()
      assert has_element?(view, "#assignment-assignee-options [data-assignee^='person:']")
      refute has_element?(view, "#assignment-assignee-home-person")

      view |> element("#assignment-assignee-back") |> render_click()
      assert has_element?(view, "#assignment-assignee-home-person")
    end

    test "a tick in a list redraws as ticked", ctx do
      cleo = person!("Cleopatra#{System.unique_integer([:positive])}")
      {:ok, view, _} = edit(ctx)

      render_change(view, "assignee_query", %{"assignee_q" => cleo.name})
      sel = "#assignment-assignee-options [data-assignee='person:#{cleo.uuid}']"
      assert has_element?(view, sel <> "[aria-selected='false']")

      view |> element(sel) |> render_click()
      assert has_element?(view, sel <> "[aria-selected='true']")
    end
  end

  describe "who the lists are read for" do
    # They name every staff person and every account with no staff record
    # yet, with their email. Only someone who may assign here reads them.
    setup ctx do
      {:ok, outsider} =
        Auth.register_user(%{
          "email" => "listleak-#{System.unique_integer([:positive])}@example.com",
          "password" => "ValidPassword123!"
        })

      {:ok, viewer} =
        Auth.register_user(%{
          "email" => "viewer-#{System.unique_integer([:positive])}@example.com",
          "password" => "ValidPassword123!"
        })

      {:ok, _} = PhoenixKitProjects.Members.add_member(ctx.project, viewer.uuid, role: "viewer")

      {:ok, _} =
        PhoenixKitProjects.Authz.set_overrides(ctx.project, %{"assign_tasks" => "managers"})

      {:ok,
       outsider: outsider, viewer: fake_scope(user_uuid: viewer.uuid, permissions: ["projects"])}
    end

    test "a crafted search, query, browse or page from someone who may not assign reads nothing",
         ctx do
      {:ok, view, _} =
        ctx.conn
        |> put_test_scope(ctx.viewer)
        |> live("/en/admin/projects/#{ctx.project.uuid}/assignments/#{ctx.a.uuid}/edit")

      render_hook(view, "assignee_search", %{"q" => "listleak", "limit" => 1000})
      refute_push_event(view, "assignee_results", _)

      html = render_hook(view, "assignee_query", %{"assignee_q" => "listleak"})
      refute html =~ ctx.outsider.email
      html = render_hook(view, "assignee_browse", %{"kind" => "person"})
      refute html =~ "assignment-assignee-options"
    end

    test "a trashed person cannot be ticked, nor a forged one saved", ctx do
      gone = person!("Gone#{System.unique_integer([:positive])}")
      gone |> Ecto.Changeset.change(status: "trashed") |> Repo.update!()

      {:ok, view, _} = edit(ctx)
      render_hook(view, "assignee_toggle", %{"kind" => "person", "uuid" => gone.uuid})
      refute has_element?(view, "#assignment-assignee-chip-person-#{gone.uuid}")

      {:ok, view, _} = live(ctx.conn, "/en/admin/projects/#{ctx.project.uuid}/assignments/new")

      # Saved and gone back to the project (the foreign key used to fail
      # inside the save and take the form down), with nobody it was not
      # picked for.
      assert {:error, {:live_redirect, _}} =
               render_submit(view, "save", %{
                 "task_mode" => "new",
                 "task" => %{"title" => "Forged assignee"},
                 "assignment" => %{"assignees" => ["", "person:#{Ecto.UUID.generate()}"]}
               })

      assert Enum.any?(Projects.list_assignments(ctx.project.uuid), fn a ->
               Assignment.label(a) == "Forged assignee"
             end)

      for a <- Projects.list_assignments(ctx.project.uuid) do
        assert AssigneeSet.keys_by_task([a.uuid])[a.uuid] in [nil, []]
      end
    end

    test "someone who may assign still finds the account", ctx do
      {:ok, view, _} = edit(ctx)
      html = render_hook(view, "assignee_query", %{"assignee_q" => "listleak"})
      assert html =~ ctx.outsider.email
    end
  end

  describe "the sub-project popup" do
    test "has the task's header, tabs and picker", ctx do
      {:ok, view, html} =
        live(ctx.conn, "/en/admin/projects/#{ctx.project.uuid}/assignments/new?kind=subproject")

      assert html =~ "New sub-project"
      assert has_element?(view, "[id^='subproject-form-tabs-']")
      assert has_element?(view, "[id^='subproject-'][id$='-tab-subproject']")
      assert has_element?(view, "[id^='subproject-'][id$='-tab-schedule']")
      assert has_element?(view, "#subproject-assignee-search")
      refute html =~ ~s(name="assign_type" id=)

      view
      |> form("#subproject-form", %{"subproject" => %{"name" => "Kitchen island"}})
      |> render_change()

      assert view |> element("#subproject-form-header-title") |> render() =~ "Kitchen island"

      render_click(view, "set_form_pane", %{"pane" => "schedule"})
      refute has_element?(view, "[id^='subproject-'][id$='-pane-schedule'].hidden")
      assert has_element?(view, "[id^='subproject-'][id$='-pane-subproject'].hidden")
    end

    test "assigns the new sub-project through the picker", ctx do
      fia = person!("Fia")

      {:ok, view, _} =
        live(ctx.conn, "/en/admin/projects/#{ctx.project.uuid}/assignments/new?kind=subproject")

      view
      |> form("#subproject-form", %{"subproject" => %{"name" => "Pantry"}})
      |> render_change()

      render_click(view, "assignee_pick", %{"kind" => "person", "uuid" => fia.uuid})
      assert has_element?(view, "#subproject-assignee-chips", "Fia")

      view |> form("#subproject-form") |> render_submit()

      [child] =
        ctx.project.uuid
        |> Projects.list_assignments()
        |> Enum.filter(& &1.child_project_uuid)
        |> Enum.map(&Projects.get_project(&1.child_project_uuid))

      assert child.name == "Pantry"
      assert child.assigned_person_uuid == fia.uuid
    end
  end
end
