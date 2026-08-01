# Reach architecture/boundary policy. Empty = no-policy (valid): `mix reach.check
# --arch --smells` runs the arch + smell checks that need no policy. Populate
# layer/boundary rules as the architecture settles.
[
  # `--smells` is advisory unless strict is set (reach 2.8.2 config.ex ~L351);
  # this makes every `mix reach.check --arch --smells` invocation gate. Reach has
  # no `roots` config key — scope is pinned at the call site with `--path lib`
  # (see the precommit.full alias) so local and CI grade the same file set.
  smells: [strict: true]
]
