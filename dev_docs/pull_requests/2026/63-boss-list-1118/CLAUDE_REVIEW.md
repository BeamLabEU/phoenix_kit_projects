# Claude Review — PR #63

**PR:** Work through the boss's fourth list (mdon)
**Reviewed:** 2026-11-19


Reviewers: codex (GPT-6.1), read-only, both halves of the diff pasted in full; zai (GLM-5.3) on part A. Every finding below was checked against the code before acting.

## Part A: the project page and its dialogs

| # | Finding | Verdict | Action |
|---|---|---|---|
| A1b | The Done dialog makes kept recipients (e.g. the creator) members without a membership right | Real, by design | Kept: these are server-chosen defaults, and Max's rule is that whoever is told can open what they're told about. Listed as an open point in the PR. |
| A1e | Quick add uses the mount-time `outline_can.edit` | Same as every other outline event | Not changed: `outline_can` is refreshed on reload like the rest of the outline. |
| A2 | Choosing an account without a staff record in the Done picker makes the record before Confirm | Real, minor | Not changed: same as the task form's picker; the record is only made after the "Create a staff record?" Yes. |
| A3 | A crafted `{"person", uuid}` key reaches `update_assignment_form` | Partly: keys reach the parent only through core's picker, which vets each pick | Fixed anyway: `assign_added/3` vets each key with `Assignees.describe_pick/2`. |
| A6 | The "Added" note mangled a title containing `%{count}` or `$&` | Real | Fixed: count first, then title, by split/join. |
| A6 | Without the popover API, the fallback panel doesn't follow scrolling | Real, edge | Not changed: every supported browser has the API. |
| A8 | People added to a row kept idle were still assigned | Real | Fixed: only rows that are released apply their picker's additions. |
| A8 | `adopt_summary` sent directly overwrote an existing description | Real | Fixed: the button's rule (only while there's no description). |
| A8 | The AI-time chip opened an empty Notes tab when discussions are off | Real | Fixed: plain text then. |

## Part B: forms, picker source, members, notices, comments module

| # | Finding | Verdict | Action |
|---|---|---|---|
| B1 | `AssigneeField` passes through unvetted keys | Not reachable: `{:changed, keys}` is a process message from core's picker, which runs `Source.pick/2` on every pick | No change. |
| B2 | Held dependency changes are written at Save without re-checking the feature | Real | Fixed: Save re-reads the project and drops held dependency changes if the feature was turned off. |
| B2 | A file uploaded in an unsaved edit is logged as added at upload | Real, accepted | Listed as an Item 8 limit. |
| B3 | Archived project / actor without manage right can still admit | By design: assigning is the right that admits | No change. |
| B4 | The 4,000-character cap lets one character carry 100,000 combining marks | Real | Fixed: also capped at 16 KB, cut at a valid UTF-8 boundary. Test added. |
| B5 | `@` suggestions and the mention warning name people | Bounded: only the project's own people and accounts the viewer can already find | No change. |
| B6 | A pending-review assignment admitted its assignees | Real | Fixed: admission waits for acceptance. Test added. |

## zai (GLM-5.3), part A

| Finding | Verdict | Action |
|---|---|---|
| `remove_dependency` / `toggle_tracking` rights not re-checked at the write | Not real: both go through `gated_handle_event`, which asks `:edit_tasks` / `:update_status` and the feature | No change. |
| `rename_save` crashes on a crafted save with no title or a non-string one | Real | Fixed: a string guard and a catch-all clause. |
| `force` is unused in `build_next_up` | Not real: it is stored in the dialog state | No change. |
| `assignee_source` stays set after the dialog | Harmless: on the project page only the dialog reads it | No change. |
| PkpPop's scroll listener could outlive a re-rendered panel | Not real: LiveView patches the panel in place, so its `toggle` still fires | No change. |
| The kept-recipient admission and the staff record made before Confirm | Same as codex A1b and A2 | See above. |
