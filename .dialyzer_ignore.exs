[
  # Gettext.Backend generated code triggers opaque-type warnings from
  # Expo.PluralForms — known false positive in gettext ≥ 0.26.
  ~r"lib/phoenix_kit_projects/gettext\.ex:1:call_without_opaque",
  # `Authz.module_reacher?/1` builds a scope (`Scope.for_user/1`) and reads
  # its `cached_permissions` MapSet in the same module: dialyzer flags the
  # MapSet's opaque internals on that local call (the same scope passed to
  # `Authz.can?/5` from another module is not flagged). A false positive.
  ~r"lib/phoenix_kit_projects/authz\.ex:\d+:\d+:call_without_opaque"
]
