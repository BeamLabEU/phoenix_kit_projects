# Follow-up — PR #50

How the finding in `CLAUDE_REVIEW.md` stands against the current code.

- **NITPICK: the session keys are listed in two places** — **Fixed in this
  sweep.** The keys are listed once, in the `Extensions.Extension`
  moduledoc; AGENTS.md's embed-session table points there, and
  `ext_tab_session_test.exs` mounts a contributed tab and asserts the
  session it gets is exactly that list.
