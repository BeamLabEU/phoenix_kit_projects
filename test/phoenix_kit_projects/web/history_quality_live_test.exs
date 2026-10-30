defmodule PhoenixKitProjects.Web.HistoryQualityLiveTest do
  @moduledoc """
  The page-level deltas of the History work that the other tests do not
  reach: names instead of emails, the start dialog in the viewer's zone,
  the form's typed rows, the feed's rendering (a deleted task, the drawer's
  short sentences, plain names in an emit embed) and the reserved tab key.
  """

  use PhoenixKitProjects.LiveCase, async: false

  import Ecto.Query
  import Phoenix.LiveViewTest

  alias PhoenixKit.Activity.Entry
  alias PhoenixKit.Users.Auth
  alias PhoenixKitProjects.Extensions.Extension
  alias PhoenixKitProjects.Projects
  alias PhoenixKitProjects.Test.Repo
  alias PhoenixKitProjects.Web.Components.HistoryFeed
  alias PhoenixKitStaff.Schemas.Person

  defp person!(name) do
    {:ok, user} =
      Auth.register_user(%{
        "email" =>
          "#{name |> String.downcase() |> String.replace(" ", ".")}-#{System.unique_integer([:positive])}@example.com",
        "password" => "ValidPassword123!"
      })

    {:ok, p} = Repo.insert(%Person{user_uuid: user.uuid, status: "active", name: name})
    {user, p}
  end

  test "a task row names its person, not their email", %{conn: conn} do
    conn = put_test_scope(conn, fake_scope(user_uuid: embed_user_uuid!()))
    project = fixture_project(%{"start_mode" => "immediate"})
    {user, p} = person!("Ada Lovelace")

    {:ok, _} =
      Projects.create_task_with_assignment(
        project.uuid,
        %{"title" => "Measure", "ad_hoc" => true},
        %{
          "assigned_person_uuid" => p.uuid
        }
      )

    {:ok, _view, html} = live(conn, "/en/admin/projects/#{project.uuid}")
    assert html =~ "Ada Lovelace"
    refute html =~ user.email
  end

  test "the start dialog reads the typed time in the viewer's zone", %{conn: conn} do
    conn =
      put_test_scope(
        conn,
        fake_scope(user_uuid: embed_user_uuid!(), user_timezone: "Europe/Tallinn")
      )

    project =
      fixture_project(%{
        "start_mode" => "scheduled",
        "scheduled_start_date" => DateTime.add(DateTime.utc_now(), 7, :day)
      })

    {:ok, view, _html} = live(conn, "/en/admin/projects/#{project.uuid}")
    render_click(view, "confirm_start_project", %{"start_at" => "2026-07-01T10:00"})

    assert Projects.get_project(project.uuid).started_at == ~U[2026-07-01 07:00:00Z]
  end

  test "a waiting-on set through the task form is its own row", %{conn: conn} do
    user_uuid = embed_user_uuid!()
    conn = put_test_scope(conn, fake_scope(user_uuid: user_uuid))
    project = fixture_project(%{"start_mode" => "immediate"})

    {:ok, %{assignment: a}} =
      Projects.create_task_with_assignment(
        project.uuid,
        %{"title" => "Pay", "ad_hoc" => true},
        %{}
      )

    {:ok, view, _} = live(conn, "/en/admin/projects/#{project.uuid}/assignments/#{a.uuid}/edit")

    # The form has no "Waiting on" field any more; the value still arrives
    # from the API and the same save path logs it.
    view
    |> element("#assignment-form")
    |> render_submit(%{"assignment" => %{"waiting_on" => "The client's transfer"}})

    assert [row] =
             Repo.all(
               from(e in Entry,
                 where: e.action == "projects.assignment_waiting" and e.resource_uuid == ^a.uuid
               )
             )

    assert row.metadata["waiting_on"] == "The client's transfer"
  end

  describe "the feed" do
    defp entry(attrs) do
      Map.merge(
        %{
          id: "a-#{System.unique_integer([:positive])}",
          at: ~U[2026-07-01 10:00:00Z],
          kind: :activity,
          action: "projects.assignment_completed",
          actor: "Marek",
          actor_uuid: nil,
          target: nil,
          target_uuid: nil,
          task: %{uuid: Ecto.UUID.generate(), label: "Measure the room"},
          quote: nil,
          told: [],
          auto: false,
          notice: false,
          meta: %{}
        },
        attrs
      )
    end

    defp feed(entries, opts \\ []) do
      render_component(&HistoryFeed.history_feed/1,
        id: "f",
        entries: entries,
        project: %{key: "K", uuid: Ecto.UUID.generate()},
        compact: Keyword.get(opts, :compact, false),
        links: Keyword.get(opts, :links, true)
      )
    end

    test "a deleted task is struck through and not linked" do
      html = feed([entry(%{task: %{uuid: Ecto.UUID.generate(), label: "Old task", gone: true}})])
      assert html =~ "line-through"
      assert html =~ "Old task"
      refute html =~ ~s(href=)
    end

    test "an emit-mode embed shows task names without links" do
      html = feed([entry(%{})], links: false)
      assert html =~ "Measure the room"
      refute html =~ ~s(href=)
    end

    test "the drawer's lines read whole without the task's name" do
      html =
        feed(
          [
            entry(%{kind: :comment, action: nil, quote: "Looks good"}),
            entry(%{kind: :time, action: nil, minutes: 85}),
            entry(%{action: "projects.assignment_reopened", quote: "Wall A"})
          ],
          compact: true
        )

      assert html =~ "commented"
      refute html =~ "commented on"
      assert html =~ "logged 1 h 25 min"
      refute html =~ "min on"
      assert html =~ "reopened it, because:"
      refute html =~ "Measure the room"
    end
  end

  test "an extension may not take the history tab key" do
    assert "history" in Extension.reserved_tab_keys()
  end
end
