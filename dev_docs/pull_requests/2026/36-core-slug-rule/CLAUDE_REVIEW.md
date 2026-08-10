# PR #36 — Use core's slug rule for project status slugs

**Reviewed:** 2026-08-10 · **Author:** mdon · **Verdict:** merged, no changes
required. Released in **0.21.0**.

+38 / −6. Reviewed as part of the phoenix_kit 2.0 sweep.

Adds `transliterate: true` to `ProjectStatus.slugify/1`'s delegation to core.
Correct for the core this module was pinned to at the time: the option defaulted
to `false`, and without it core's `[^a-z0-9]+` pass deleted every non-ASCII
character, so a Cyrillic or Greek status name produced an empty slug — the exact
bug the comment above the call says was being fixed. Same defect class as
`phoenix_kit_document_creator#32`.

Under core **2.0** the option is accepted-and-ignored (romanization is always
on), so the argument is now redundant rather than load-bearing. Harmless, and
consistent with every other slug call site in the umbrella, so it stays.

`test/slug_generation_test.exs` follows the same conservative shape as
`phoenix_kit_posts#15`'s — asserting what holds regardless of which core
resolves, rather than pinning romanization output that varies by core version.

## Fixed on `main` — not from this PR

Merging this PR is what first built the module against **phoenix_kit_ai 0.18.0**,
released earlier in this sweep, and that surfaced a compile failure under
`--warnings-as-errors`:

```
module attribute @impl was not set for function source_fields/2 callback
(specified in PhoenixKitAI.Components.AITranslate.FormBinding)
```

`AITranslateBinding.source_fields/2` carried a comment explaining that `@impl`
was *deliberately* omitted, because the callback existed only in an unreleased
`phoenix_kit_ai` and annotating a callback the pinned behaviour does not declare
would itself warn. ai 0.18.0 is the release that adds `source_fields/2` to the
behaviour (as an optional callback, for its new VALUE MODE), and this module's
pin is now `~> 0.18` — so the annotation became correct and its *absence*
became the warning. Added `@impl true` and rewrote the comment to record the
resolution rather than the pending state.

This is the release-gating convention working as designed: the omission was
right while it was right, and had a note saying exactly when it would stop
being right.

## Verification

| Check | Result |
|---|---|
| `mix precommit` | **passes** against core 2.0.0, after the `@impl` fix |
| `mix test` | **232 tests, 0 failures** (1171 excluded — no Postgres available) |

Sibling pins raised in step: `phoenix_kit_ai` → `~> 0.18`, `phoenix_kit_staff`
→ `~> 0.8`, `phoenix_kit_comments` → `~> 0.3`, `phoenix_kit_entities` → `~> 0.3`.
