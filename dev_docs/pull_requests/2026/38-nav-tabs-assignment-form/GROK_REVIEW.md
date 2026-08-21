# Grok Review — PR #38 "Remove the local TabsStrip in favour of core's nav_tabs, and fix the daisyUI tabs class"

**Merge commit:** 0a414db
**Author:** mdon (fix/daisyui-tabs-box)
**Files:** `lib/phoenix_kit_projects/web/components/tabs_strip.ex` (deleted), `assignment_form_live.ex`, `components.ex`, three live tests, `AGENTS.md`

## Summary of the change

Projects' `TabsStrip` was the other copy of core event-mode tabs. Its
payload key was literally `value`, which needed a native `value=`
attribute to work around LiveView's `extractMeta` overwriting
`meta.value` with a button's empty `.value`. Core's component
standardises on `tab`, so that hack goes away.

`set_task_mode` / `set_sp_mode` handlers now match `%{"tab" => mode}`.
The three live tests click `button[phx-value-tab='new']` instead of
`phx-value-value`. The barrel import in `components.ex` is gone with the
file.

## Findings

### 1. IMPROVEMENT - MEDIUM — AGENTS.md still documented the deleted component

The PR updated the tree comment from `tabs-boxed` to `tabs-box` but left
the `tabs_strip.ex` line in the file tree, and the sub-project form
section still said `<.tabs_strip event="set_sp_mode">`. **Fixed** both:
dropped the tree entry, and the usage line now reads
`<.nav_tabs on_change="set_sp_mode">`.

Historical mentions in CHANGELOG and old review docs left as history.
