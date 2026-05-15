defmodule PhoenixKitProjects.Web.PopupHostLiveTest do
  @moduledoc """
  Behaviour tests for `PopupHostLive` — the opinionated wrapper that
  manages the modal stack and consumes emit-mode PubSub events.

  Tests use `live_isolated/3` and either send events directly to the LV
  process or broadcast on the host topic; modal child LVs that get
  pushed onto the stack are real (`OverviewLive` etc.) so we exercise
  the full mount-via-`live_render` path inside the modal.
  """

  use PhoenixKitProjects.LiveCase, async: false

  alias PhoenixKit.Users.Auth
  alias PhoenixKitProjects.PubSub, as: ProjectsPubSub

  setup %{conn: conn} do
    {:ok, user} =
      Auth.register_user(%{
        "email" => "popup-host-#{System.unique_integer([:positive])}@example.com",
        "password" => "PopupHostPass123!"
      })

    scope = fake_scope(user_uuid: user.uuid)
    conn = put_test_scope(conn, scope)
    {:ok, conn: conn, actor_uuid: user.uuid}
  end

  describe "mount validation" do
    test "raises when pubsub_topic is missing", %{conn: conn} do
      assert_raise ArgumentError, ~r/pubsub_topic/, fn ->
        live_isolated(conn, PhoenixKitProjects.Web.PopupHostLive, session: %{})
      end
    end

    test "raises when pubsub_topic is empty", %{conn: conn} do
      assert_raise ArgumentError, ~r/pubsub_topic/, fn ->
        live_isolated(conn, PhoenixKitProjects.Web.PopupHostLive,
          session: %{"pubsub_topic" => ""}
        )
      end
    end

    test "mounts with a valid topic, empty stack, no root view", %{conn: conn} do
      topic = unique_topic()

      {:ok, _view, html} =
        live_isolated(conn, PhoenixKitProjects.Web.PopupHostLive,
          session: %{"pubsub_topic" => topic}
        )

      refute html =~ "modal-open"
    end

    test "wrapper_class override replaces default", %{conn: conn} do
      topic = unique_topic()

      {:ok, _view, html} =
        live_isolated(conn, PhoenixKitProjects.Web.PopupHostLive,
          session: %{
            "pubsub_topic" => topic,
            "wrapper_class" => "test-wrapper-class"
          }
        )

      assert html =~ "test-wrapper-class"
    end
  end

  describe "root_view rendering" do
    test "renders the root LV inline when root_view is supplied", %{conn: conn} do
      topic = unique_topic()

      {:ok, _view, html} =
        live_isolated(conn, PhoenixKitProjects.Web.PopupHostLive,
          session: %{
            "pubsub_topic" => topic,
            "root_view" => %{
              "lv" => "Elixir.PhoenixKitProjects.Web.OverviewLive",
              "session" => %{}
            }
          }
        )

      # OverviewLive's standard heading content makes it past the embed.
      assert html =~ "Projects"
    end

    test "logs a warning and renders without root when root_view.lv is not whitelisted",
         %{conn: conn} do
      topic = unique_topic()

      {:ok, _view, html} =
        live_isolated(conn, PhoenixKitProjects.Web.PopupHostLive,
          session: %{
            "pubsub_topic" => topic,
            "root_view" => %{
              "lv" => "Elixir.PhoenixKitProjects.Projects",
              "session" => %{}
            }
          }
        )

      refute html =~ "modal-open"
    end
  end

  describe "modal stack management via PubSub events" do
    test "broadcasts :opened pushes a frame and renders the modal", %{conn: conn} do
      topic = unique_topic()

      {:ok, view, html_before} =
        live_isolated(conn, PhoenixKitProjects.Web.PopupHostLive,
          session: %{"pubsub_topic" => topic}
        )

      refute html_before =~ "modal-open"

      ProjectsPubSub.broadcast_embed(topic, :opened, %{
        lv: PhoenixKitProjects.Web.OverviewLive,
        session: %{},
        frame_ref: nil
      })

      html_after = render(view)
      assert html_after =~ "modal-open"
      assert html_after =~ "Projects"
    end

    test "rejects :opened for non-whitelisted LV (no push)", %{conn: conn} do
      topic = unique_topic()

      {:ok, view, _} =
        live_isolated(conn, PhoenixKitProjects.Web.PopupHostLive,
          session: %{"pubsub_topic" => topic}
        )

      ProjectsPubSub.broadcast_embed(topic, :opened, %{
        lv: PhoenixKitProjects.Projects,
        session: %{},
        frame_ref: nil
      })

      assert :sys.get_state(view.pid).socket.assigns.modal_stack == []
    end

    test ":closed with matching top frame_ref pops the modal", %{conn: conn} do
      topic = unique_topic()

      {:ok, view, _} =
        live_isolated(conn, PhoenixKitProjects.Web.PopupHostLive,
          session: %{"pubsub_topic" => topic}
        )

      ProjectsPubSub.broadcast_embed(topic, :opened, %{
        lv: PhoenixKitProjects.Web.OverviewLive,
        session: %{},
        frame_ref: nil
      })

      # Force render to flush handle_info, then capture the assigned frame_ref.
      _ = render(view)
      [%{frame_ref: ref}] = :sys.get_state(view.pid).socket.assigns.modal_stack

      ProjectsPubSub.broadcast_embed(topic, :closed, %{frame_ref: ref})

      _ = render(view)
      assert :sys.get_state(view.pid).socket.assigns.modal_stack == []
    end

    test ":closed with a stale frame_ref leaves the stack untouched", %{conn: conn} do
      topic = unique_topic()

      {:ok, view, _} =
        live_isolated(conn, PhoenixKitProjects.Web.PopupHostLive,
          session: %{"pubsub_topic" => topic}
        )

      ProjectsPubSub.broadcast_embed(topic, :opened, %{
        lv: PhoenixKitProjects.Web.OverviewLive,
        session: %{},
        frame_ref: nil
      })

      _ = render(view)
      [%{frame_ref: ref}] = :sys.get_state(view.pid).socket.assigns.modal_stack

      # Wrong ref — must NOT pop.
      ProjectsPubSub.broadcast_embed(topic, :closed, %{frame_ref: ref + 9999})

      _ = render(view)
      [%{frame_ref: ^ref}] = :sys.get_state(view.pid).socket.assigns.modal_stack
    end

    test "explicit close_top_modal event (ESC / backdrop) pops top", %{conn: conn} do
      topic = unique_topic()

      {:ok, view, _} =
        live_isolated(conn, PhoenixKitProjects.Web.PopupHostLive,
          session: %{"pubsub_topic" => topic}
        )

      ProjectsPubSub.broadcast_embed(topic, :opened, %{
        lv: PhoenixKitProjects.Web.OverviewLive,
        session: %{},
        frame_ref: nil
      })

      _ = render(view)
      [%{frame_ref: top_ref}] = :sys.get_state(view.pid).socket.assigns.modal_stack

      # Modal-backdrop button triggers `phx-click="close_top_modal"` with
      # the frame's ref. R4-BM2: handler requires a valid ref or no-ops.
      render_click(view, "close_top_modal", %{"frame-ref" => to_string(top_ref)})

      assert :sys.get_state(view.pid).socket.assigns.modal_stack == []
    end

    test "close_top_modal without frame-ref is dropped (R4-BM2)", %{conn: conn} do
      topic = unique_topic()

      {:ok, view, _} =
        live_isolated(conn, PhoenixKitProjects.Web.PopupHostLive,
          session: %{"pubsub_topic" => topic}
        )

      ProjectsPubSub.broadcast_embed(topic, :opened, %{
        lv: PhoenixKitProjects.Web.OverviewLive,
        session: %{},
        frame_ref: nil
      })

      _ = render(view)
      assert length(:sys.get_state(view.pid).socket.assigns.modal_stack) == 1

      # Missing frame-ref → no-op. A stale/adversarial event must not
      # close the wrong modal.
      render_click(view, "close_top_modal", %{})

      assert length(:sys.get_state(view.pid).socket.assigns.modal_stack) == 1
    end
  end

  describe "Codex H2 regression: ESC binds only on top frame" do
    # Helper: push N frames by chaining emitter frame_refs (root → frame1
    # → frame2 → ...). After R4-BM1, only the current top is a valid
    # opener, so each :opened must carry the prior frame's ref.
    defp push_n_frames(topic, view, n) do
      Enum.each(1..n, fn _ ->
        top_ref =
          case List.last(:sys.get_state(view.pid).socket.assigns.modal_stack) do
            %{frame_ref: ref} -> ref
            _ -> nil
          end

        ProjectsPubSub.broadcast_embed(topic, :opened, %{
          lv: PhoenixKitProjects.Web.OverviewLive,
          session: %{},
          frame_ref: top_ref
        })

        _ = render(view)
      end)
    end

    test "with 2 frames stacked, only the top dialog carries phx-window-keydown",
         %{conn: conn} do
      topic = unique_topic()

      {:ok, view, _} =
        live_isolated(conn, PhoenixKitProjects.Web.PopupHostLive,
          session: %{"pubsub_topic" => topic}
        )

      push_n_frames(topic, view, 2)
      html = render(view)

      # Exactly one dialog should carry the Escape window-keydown binding.
      keydown_count =
        Regex.scan(~r/phx-window-keydown="close_top_modal"/, html) |> length()

      assert keydown_count == 1,
             "expected exactly 1 dialog with phx-window-keydown, got #{keydown_count}"
    end

    test "close_top_modal with non-top frame-ref is a no-op", %{conn: conn} do
      topic = unique_topic()

      {:ok, view, _} =
        live_isolated(conn, PhoenixKitProjects.Web.PopupHostLive,
          session: %{"pubsub_topic" => topic}
        )

      push_n_frames(topic, view, 2)

      [%{frame_ref: bottom_ref}, %{frame_ref: _top_ref}] =
        :sys.get_state(view.pid).socket.assigns.modal_stack

      # Click the lower-frame backdrop (passing its frame-ref). The top
      # frame is unaffected — pop_if_top_matches drops the event.
      render_click(view, "close_top_modal", %{"frame-ref" => to_string(bottom_ref)})

      assert length(:sys.get_state(view.pid).socket.assigns.modal_stack) == 2
    end
  end

  describe "Codex M2 regression: malformed :opened payload" do
    test "missing :lv key — dropped + logged, no crash", %{conn: conn} do
      topic = unique_topic()

      {:ok, view, _} =
        live_isolated(conn, PhoenixKitProjects.Web.PopupHostLive,
          session: %{"pubsub_topic" => topic}
        )

      # Adversarial broadcast — only the topic ID is known.
      ProjectsPubSub.broadcast_embed(topic, :opened, %{not_what_we_expect: true})

      # If the LV crashed, render/1 would raise. Process should still be alive.
      _ = render(view)
      assert Process.alive?(view.pid)
      assert :sys.get_state(view.pid).socket.assigns.modal_stack == []
    end

    test "non-map :lv — dropped, no crash", %{conn: conn} do
      topic = unique_topic()

      {:ok, view, _} =
        live_isolated(conn, PhoenixKitProjects.Web.PopupHostLive,
          session: %{"pubsub_topic" => topic}
        )

      ProjectsPubSub.broadcast_embed(topic, :opened, %{lv: "not an atom", session: %{}})

      _ = render(view)
      assert Process.alive?(view.pid)
      assert :sys.get_state(view.pid).socket.assigns.modal_stack == []
    end
  end

  describe "Codex R3-M1 regression: list-LV :deleted doesn't pop the modal" do
    test ":deleted with close=false leaves the stack intact", %{conn: conn} do
      topic = unique_topic()

      {:ok, view, _} =
        live_isolated(conn, PhoenixKitProjects.Web.PopupHostLive,
          session: %{"pubsub_topic" => topic}
        )

      # Open ProjectsLive in a modal.
      ProjectsPubSub.broadcast_embed(topic, :opened, %{
        lv: PhoenixKitProjects.Web.ProjectsLive,
        session: %{},
        frame_ref: nil
      })

      _ = render(view)
      [%{frame_ref: list_ref}] = :sys.get_state(view.pid).socket.assigns.modal_stack

      # Simulate ProjectsLive (or any list) emitting :deleted with close: false.
      ProjectsPubSub.broadcast_embed(topic, :deleted, %{
        kind: :project,
        uuid: Ecto.UUID.generate(),
        close: false,
        frame_ref: list_ref
      })

      _ = render(view)
      # Modal stays open — list-LV is showing the post-delete state.
      assert [%{frame_ref: ^list_ref}] =
               :sys.get_state(view.pid).socket.assigns.modal_stack
    end

    test ":deleted with close=true pops the modal (terminal-resource path)",
         %{conn: conn} do
      topic = unique_topic()

      {:ok, view, _} =
        live_isolated(conn, PhoenixKitProjects.Web.PopupHostLive,
          session: %{"pubsub_topic" => topic}
        )

      # OverviewLive mounts cleanly without required session keys, giving us
      # a stable stack frame to exercise the close-flag branch against.
      ProjectsPubSub.broadcast_embed(topic, :opened, %{
        lv: PhoenixKitProjects.Web.OverviewLive,
        session: %{},
        frame_ref: nil
      })

      _ = render(view)
      [%{frame_ref: open_ref}] = :sys.get_state(view.pid).socket.assigns.modal_stack

      # Synthesize a "resource is gone" event — pop the modal.
      ProjectsPubSub.broadcast_embed(topic, :deleted, %{
        kind: :project,
        uuid: Ecto.UUID.generate(),
        close: true,
        frame_ref: open_ref
      })

      _ = render(view)
      assert :sys.get_state(view.pid).socket.assigns.modal_stack == []
    end
  end

  describe "Codex R4-IH regression: :saved.next replaces top frame" do
    test ":saved with close=true and next=... pops then pushes the follow-up LV",
         %{conn: conn} do
      topic = unique_topic()

      {:ok, view, _} =
        live_isolated(conn, PhoenixKitProjects.Web.PopupHostLive,
          session: %{"pubsub_topic" => topic}
        )

      ProjectsPubSub.broadcast_embed(topic, :opened, %{
        lv: PhoenixKitProjects.Web.OverviewLive,
        session: %{},
        frame_ref: nil
      })

      _ = render(view)
      [%{frame_ref: form_ref}] = :sys.get_state(view.pid).socket.assigns.modal_stack

      # Simulate a form save with :next — close current form, open
      # follow-up screen (e.g. the edit view of the just-created record).
      ProjectsPubSub.broadcast_embed(topic, :saved, %{
        kind: :task,
        action: :create,
        record: %{uuid: "any"},
        close: true,
        next: {PhoenixKitProjects.Web.ProjectsLive, %{}},
        frame_ref: form_ref
      })

      _ = render(view)
      [frame] = :sys.get_state(view.pid).socket.assigns.modal_stack
      assert frame.lv == PhoenixKitProjects.Web.ProjectsLive

      refute frame.frame_ref == form_ref,
             "next frame must get a fresh frame_ref, not reuse the popped one"
    end

    test "stale :saved.next is dropped — neither pop nor push (R5-BH)",
         %{conn: conn} do
      topic = unique_topic()

      {:ok, view, _} =
        live_isolated(conn, PhoenixKitProjects.Web.PopupHostLive,
          session: %{"pubsub_topic" => topic}
        )

      ProjectsPubSub.broadcast_embed(topic, :opened, %{
        lv: PhoenixKitProjects.Web.OverviewLive,
        session: %{},
        frame_ref: nil
      })

      _ = render(view)
      [%{frame_ref: top_ref}] = :sys.get_state(view.pid).socket.assigns.modal_stack

      # Stale :saved with a wrong frame_ref. Pre-R5-BH this would
      # silently no-op the pop AND still push `next`, injecting a
      # frame into the stack.
      ProjectsPubSub.broadcast_embed(topic, :saved, %{
        kind: :task,
        action: :create,
        record: %{uuid: "any"},
        close: true,
        next: {PhoenixKitProjects.Web.ProjectsLive, %{}},
        frame_ref: top_ref + 9999
      })

      _ = render(view)
      # Stack unchanged — same frame, same ref. No push.
      assert [%{frame_ref: ^top_ref, lv: PhoenixKitProjects.Web.OverviewLive}] =
               :sys.get_state(view.pid).socket.assigns.modal_stack
    end

    test ":saved.next pointing to a non-embeddable LV is ignored + logged",
         %{conn: conn} do
      topic = unique_topic()

      {:ok, view, _} =
        live_isolated(conn, PhoenixKitProjects.Web.PopupHostLive,
          session: %{"pubsub_topic" => topic}
        )

      ProjectsPubSub.broadcast_embed(topic, :opened, %{
        lv: PhoenixKitProjects.Web.OverviewLive,
        session: %{},
        frame_ref: nil
      })

      _ = render(view)
      [%{frame_ref: form_ref}] = :sys.get_state(view.pid).socket.assigns.modal_stack

      ProjectsPubSub.broadcast_embed(topic, :saved, %{
        kind: :project,
        action: :create,
        record: %{uuid: "any"},
        close: true,
        next: {PhoenixKitProjects.Projects, %{}},
        frame_ref: form_ref
      })

      _ = render(view)
      # Frame was popped (close: true) but the bogus next was rejected,
      # so the stack ends up empty rather than pushing a forbidden LV.
      assert :sys.get_state(view.pid).socket.assigns.modal_stack == []
    end
  end

  describe "C11 pinning: R7 root-frame ID disambiguation" do
    test "two PopupHostLive instances with different topics get distinct root IDs",
         %{conn: conn} do
      # Pre-R7: both renders used a hardcoded id like "embed-root-overview_live"
      # — duplicates in the DOM broke Phoenix LV's client-side targeting.
      # The R7 fix appends a topic-derived sha256 suffix to disambiguate.

      {:ok, _v1, html1} =
        live_isolated(conn, PhoenixKitProjects.Web.PopupHostLive,
          session: %{
            "pubsub_topic" => "host:orders:111",
            "root_view" => %{
              "lv" => "Elixir.PhoenixKitProjects.Web.OverviewLive",
              "session" => %{}
            }
          }
        )

      {:ok, _v2, html2} =
        live_isolated(conn, PhoenixKitProjects.Web.PopupHostLive,
          session: %{
            "pubsub_topic" => "host:orders:222",
            "root_view" => %{
              "lv" => "Elixir.PhoenixKitProjects.Web.OverviewLive",
              "session" => %{}
            }
          }
        )

      # Extract the root LV's id attribute. Both renders should contain
      # `embed-root-overview_live-<12-char-suffix>`. Without R7's suffix
      # they'd share the literal id "embed-root-overview_live".
      [id1] = Regex.run(~r/id="(embed-root-overview_live-[^"]+)"/, html1, capture: :all_but_first)
      [id2] = Regex.run(~r/id="(embed-root-overview_live-[^"]+)"/, html2, capture: :all_but_first)

      assert id1 != id2, "two PopupHost instances must produce distinct root LV IDs"

      assert String.length(id1) > String.length("embed-root-overview_live"),
             "id must include the topic-suffix disambiguator"
    end
  end

  describe "locale threading through the popup host (issue #8 follow-up)" do
    test "host locale flows into the root_view child LV", %{conn: conn} do
      topic = unique_topic()

      {:ok, _view, html} =
        live_isolated(conn, PhoenixKitProjects.Web.PopupHostLive,
          session: %{
            "pubsub_topic" => topic,
            "locale" => "et",
            "root_view" => %{
              "lv" => "Elixir.PhoenixKitProjects.Web.OverviewLive",
              "session" => %{}
            }
          }
        )

      # OverviewLive's heading is "Projects" in EN, "Projektid" in ET.
      # If locale didn't thread through the popup host into the root LV's
      # session, the live_render child mount would render English.
      assert html =~ "Projektid"
      refute html =~ "Projects · Phoenix Framework"
    end

    test "host locale flows into stacked modal frames too", %{conn: conn} do
      topic = unique_topic()

      {:ok, view, _} =
        live_isolated(conn, PhoenixKitProjects.Web.PopupHostLive,
          session: %{"pubsub_topic" => topic, "locale" => "et"}
        )

      # Open a modal frame for OverviewLive — host locale should be
      # stamped into the stacked child's session.
      ProjectsPubSub.broadcast_embed(topic, :opened, %{
        lv: PhoenixKitProjects.Web.OverviewLive,
        session: %{},
        frame_ref: nil
      })

      html = render(view)
      assert html =~ "Projektid"
    end

    test "absent locale is a no-op (English baseline)", %{conn: conn} do
      topic = unique_topic()

      {:ok, _view, html} =
        live_isolated(conn, PhoenixKitProjects.Web.PopupHostLive,
          session: %{
            "pubsub_topic" => topic,
            "root_view" => %{
              "lv" => "Elixir.PhoenixKitProjects.Web.OverviewLive",
              "session" => %{}
            }
          }
        )

      assert html =~ "Projects"
      refute html =~ "Projektid"
    end
  end

  describe "stack depth cap" do
    test "refuses to push beyond max_stack_depth (5)", %{conn: conn} do
      topic = unique_topic()

      {:ok, view, _} =
        live_isolated(conn, PhoenixKitProjects.Web.PopupHostLive,
          session: %{"pubsub_topic" => topic}
        )

      # Chain emitter frame_refs (post R4-BM1: each :opened must come
      # from the current top of the stack). Push 6; only the first 5
      # should make it onto the stack.
      for _i <- 1..6 do
        top_ref =
          case List.last(:sys.get_state(view.pid).socket.assigns.modal_stack) do
            %{frame_ref: ref} -> ref
            _ -> nil
          end

        ProjectsPubSub.broadcast_embed(topic, :opened, %{
          lv: PhoenixKitProjects.Web.OverviewLive,
          session: %{},
          frame_ref: top_ref
        })

        _ = render(view)
      end

      assert length(:sys.get_state(view.pid).socket.assigns.modal_stack) == 5
    end

    test "stale emitter frame_ref is rejected (R4-BM1)", %{conn: conn} do
      topic = unique_topic()

      {:ok, view, _} =
        live_isolated(conn, PhoenixKitProjects.Web.PopupHostLive,
          session: %{"pubsub_topic" => topic}
        )

      # Open from root.
      ProjectsPubSub.broadcast_embed(topic, :opened, %{
        lv: PhoenixKitProjects.Web.OverviewLive,
        session: %{},
        frame_ref: nil
      })

      _ = render(view)
      assert length(:sys.get_state(view.pid).socket.assigns.modal_stack) == 1

      # A *stale* second :opened from root (nil) — the current top is
      # the modal we just opened, not root. Must be dropped.
      ProjectsPubSub.broadcast_embed(topic, :opened, %{
        lv: PhoenixKitProjects.Web.ProjectsLive,
        session: %{},
        frame_ref: nil
      })

      _ = render(view)

      assert length(:sys.get_state(view.pid).socket.assigns.modal_stack) == 1,
             "stale-emit :opened must be rejected"
    end
  end

  defp unique_topic do
    "popup-host-test-#{System.unique_integer([:positive])}"
  end
end
