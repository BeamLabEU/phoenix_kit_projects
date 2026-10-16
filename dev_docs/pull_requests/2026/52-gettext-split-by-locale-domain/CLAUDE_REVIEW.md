# Claude (Sonnet 5.5) review — PR #52, after the merge (2026-10-16)

PR #52 (`mdon/main`, merge `0a893ba`): `PhoenixKitProjects.Gettext` now
`use Gettext.Backend … split_module_by: [:locale, :domain]`, so each locale's
catalogue compiles as its own module in parallel. Lookups are unchanged.

## Verified, no change needed

- **It works against the locked gettext (1.0.2).** The build holds one
  `PhoenixKitProjects.Gettext.T_<locale>_default` module per locale (de, es, et,
  fr, it, pl, ru) beside the backend module, and the suite resolves strings
  through them.
- **One domain only.** `priv/gettext/<locale>/LC_MESSAGES/default.po` is the sole
  domain, so splitting by domain adds nothing today and costs nothing.

## Noted, not changed

- **NITPICK:** `mix.exs` still declares `{:gettext, "~> 0.26 or ~> 1.0"}`. I could
  not confirm offline that `split_module_by` exists on every 0.26.x. It is moot in
  practice: `phoenix_kit` itself requires `gettext ~> 1.0`, so no resolution in
  this dependency tree can land on 0.26. Tightening the declared floor would be
  purely cosmetic.
