# PR #9 Review — Emit Mode + Popup Host

**Reviewer:** Claude (Kimi Code CLI)  
**Date:** 2026-05-15  
**Branch:** `pr-9-max` (fedc6d5)  
**Baseline:** `main` (aba7c70)

---

## Executive Summary

A large, well-structured follow-up to PR #6 that ships the deferred emit-mode contract and an opinionated popup-host wrapper. 50+ navigation sites across all 9 LVs were converted from `<.link navigate>` / `push_navigate` to PubSub-broadcast UI-intent events, with a clean `<.smart_link>` / `<.smart_menu_link>` adapter layer.

**Build status:** `mix compile` clean, `mix format --check-formatted` clean, `mix credo --strict` clean. Unit tests pass (111 non-integration). The PR is **close to merge-ready** with one localized bug and a pair of defensive suggestions noted below.

---

## Findings

### BUG - MEDIUM

**Missing locale restore in `ProjectShowLive` fail-closed mount clause**

`ProjectShowLive` has a dedicated `mount/3` head for malformed emit sessions that lack `"id"`:

```elixir
# lib/phoenix_kit_projects/web/project_show_live.ex:37
def mount(:not_mounted_at_router, session, socket) do
  socket = WebHelpers.assign_embed_state(socket, session)
  {:ok,
   socket
   |> assign(...)
   |> put_flash(:error, gettext("Project not found."))
   |> WebHelpers.close_or_navigate(Paths.projects())}
end
```

This clause does **not** call `WebHelpers.maybe_put_locale(session)` before the `gettext` call. Every other LV's `mount/3` (and the other `ProjectShowLive` clause that *has* `"id"`) restores the locale first. The practical impact is low in emit mode because `close_or_navigate` pops the modal immediately, but in navigate mode a malformed `live_render` would flash English text regardless of the host's locale.

**Fix:** Add `WebHelpers.maybe_put_locale(session)` as the first line of this clause.

---

### IMPROVEMENT - HIGH

**`Jason.encode!` in render-time components is a latent crash vector**

`<.smart_link>` and `<.smart_menu_link>` call `Jason.encode!(session_overrides)` at render time:

```elixir
# lib/phoenix_kit_projects/web/components/smart_link.ex:69
|> assign(:session_json, Jason.encode!(session_overrides))

# lib/phoenix_kit_projects/web/components/smart_menu_link.ex:53
|> assign(:session_json, Jason.encode!(session_overrides))
```

All current internal callers pass simple string-keyed maps, so this won't crash today. But if a future caller passes a struct, tuple, atom value, or datetime, the LV process will crash on render. Because these components are the canonical navigation primitives for every embeddable LV, a single bad payload takes down the whole view.

**Fix:** Use `Jason.encode/1` with a fallback that logs and renders a disabled button (or falls back to navigate mode) instead of `encode!/1`.

```elixir
session_json =
  case Jason.encode(session_overrides) do
    {:ok, json} -> json
    {:error, _} ->
      Logger.warning("...")
      "{}"
  end
```

---

### IMPROVEMENT - MEDIUM

**`embed_close_on` is dead code**

`assign_embed_state/2` decodes `session["close_on"]` and assigns `:embed_close_on` to the socket, but nothing in the PR (including `PopupHostLive`) ever reads this assign. The docs say it's "reserved for future per-frame opt-in", which is fine, but it means every embeddable LV carries a `MapSet` that is never consumed. Not a blocker — just confirming this is intentional deferred work rather than an omission.

---

### NITPICK

**`PopupHostLive` `@max_stack_depth` is hard-coded**

The stack depth cap of 5 is a module attribute (`@max_stack_depth 5`). The moduledoc says "configurable in the LV", but the only way to change it is to edit the source. A future host that genuinely needs a deeper stack has no seam. Suggest making it overridable via session (e.g. `session["max_stack_depth"] || 5`) if the API is going to claim configurability.

---

## What was checked

| Check | Result |
|---|---|
| `mix compile` | Clean (no warnings from `phoenix_kit_projects`) |
| `mix format --check-formatted` | Clean |
| `mix credo --strict` | Clean (0 issues) |
| Unit tests (`--exclude integration`) | 111 tests, 0 failures |
| Integration tests | Excluded (no local DB) — PR claims 270/270 pass |
| Per-LV emit-mode coverage | All 9 LVs have `assign_embed_state` + `attach_open_embed_hook` |
| Navigation sites | 50+ converted to `<.smart_link>` / `<.smart_menu_link>` |
| Fail-closed mounts | Form LVs and `ProjectShowLive` have catch-all clauses for missing required keys |
| Whitelist consistency | `embeddable_lvs/0` is the single source of truth; no second list in `PopupHostLive` |
| Frame-ref race safety | `stale_safe_opener?/2` and `pop_if_top_matches/2` correctly gate every event |
| Locale forwarding | `PopupHostLive` threads locale into root view and stacked modal children |
| `next:` chain | TaskFormLive (:new→:edit), ProjectFormLive (:new→show), TemplateFormLive (:new→show) all use it correctly |
| `close:` flag semantics | `notify_deleted/3` emits `close: false` (list stays open); `notify_deleted_or_navigate/4` emits `close: true` (modal pops) |
| Open-redirect guard | Still present in `navigate_after_save/3` and `close_or_navigate/2` |
| Dialyzer | PR extends `@dialyzer {:no_opaque, ...}` to cover `list_task_groups/0` and `task_closure/2` |
| Docs | `AGENTS.md` and new `dev_docs/embedding_emit.md` are accurate and consistent with code |

---

## Recommendation

**Approve after fixing the missing `maybe_put_locale` call in `ProjectShowLive`'s fail-closed mount clause.**

The `Jason.encode!` → `Jason.encode` change is strongly recommended but can be a fast-follow if Max wants to land this PR now — it's defensive against future misuse, not a live bug.
