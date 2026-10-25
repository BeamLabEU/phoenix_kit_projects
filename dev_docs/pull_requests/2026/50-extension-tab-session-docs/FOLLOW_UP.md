# Follow-up — PR #50

How the finding in `CLAUDE_REVIEW.md` stands against the current code.

- **NITPICK: the session keys are listed in two places** — **Open.** The
  `Extensions.Extension` moduledoc (`lib/phoenix_kit_projects/extensions/extension.ex:37-60`)
  and the embed-session table in AGENTS.md (the shared rows and the
  extension-tab rows, `AGENTS.md:1381-1395`) still both list
  every key, and no test compares either to the session `ProjectShowLive`
  builds for an extension tab. Fixing it means one list citing the other, or
  a test asserting the built session's keys equal the documented ones.
