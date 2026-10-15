defmodule PhoenixKitProjects.Gettext do
  @moduledoc """
  Gettext backend for projects-module-specific UI strings.

  Files in this module that wrap domain-specific strings (project,
  task, template, assignment, dependency, schedule UI) declare
  `use Gettext, backend: PhoenixKitProjects.Gettext` and call
  `gettext(...)`. Translations live in `priv/gettext/` of this
  repo — `mix gettext.extract` + `mix gettext.merge priv/gettext`
  keep them in sync.

  Common/generic strings (`Save`, `Cancel`, month names, date
  templates, etc.) keep using core's `PhoenixKitWeb.Gettext`
  backend so they're translated once at the workspace level. See
  `dev_docs/i18n_triage.md` for the per-file bucket assignments.

  The Phoenix-request pipeline sets the locale globally via
  `Gettext.put_locale/1`, which every backend reads from the
  process dictionary — so a single locale switch in the parent app
  drives both this backend and `PhoenixKitWeb.Gettext`
  simultaneously.
  """

  # Generated Gettext.Backend callbacks trigger `call_without_opaque`
  # warnings from Expo.PluralForms — known false positive in gettext ≥ 0.26.
  @dialyzer {:no_opaque, []}

  # One compiled module per locale and domain: the catalogues are large, and
  # split modules compile in parallel instead of one long serial compile that
  # blocks every app depending on this package. Lookups are unchanged.
  use Gettext.Backend,
    otp_app: :phoenix_kit_projects,
    split_module_by: [:locale, :domain]
end
