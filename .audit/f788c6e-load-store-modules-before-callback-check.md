# audit f788c6e — Load store modules before checking their callbacks

verdict: clean, one observation recorded (not applied)
scope: `lib/mpp/tempo/store.ex` (new `dedup_capable?/1`, `update_capable?/1`),
       `lib/mpp/plug.ex`, `lib/mpp/methods/tempo.ex`, `lib/mpp/methods/evm.ex`, store tests
reviewers: Claude only — Codex second-opinion not dispatched (session policy)

## Categories 1-6

- **Cat 1 — the fix itself is correct.** `function_exported?/3` answers `false` for a compiled but
  unloaded module, so store validation was order-dependent: a valid custom store was accepted or
  rejected depending on whether anything had already called it. `Code.ensure_loaded?/1` before the
  export check removes that dependence. The regression test unloads `TempoMemoryStore` and asserts
  both predicates still answer true (`test/mpp/tempo/store_test.exs:54-66`).
- **Cat 2 — de-duplication is real, not cosmetic.** Three copies of the same three-way
  `function_exported?` conjunction collapse into one predicate, and the private
  `sponsor_store_supports_update?/1` (which had the same unloaded-module bug) is deleted.

### Observation — `store_ref()` type is wider than the accepted config (Cat 6, priority 3, NOT applied)

`MPP.Tempo.Store.store_ref :: module() | {module(), keyword()}` advertises a generic
`{Mod, opts}` tuple, but every `validate_store!/1` raises for any tuple that isn't
`{MPP.Tempo.ConCacheStore, opts}` (`plug.ex:171`, `evm.ex:390`, same in `tempo.ex`).
`update_capable?/1`'s ConCacheStore-only tuple clause is therefore **consistent with the enforced
policy**, not a gap — my first read flagged it as a bug and the call-site check disproved that.

Not applied: narrowing the typespec to the ConCacheStore tuple would ripple through
`SponsorBudget`'s specs (`reserve/3`, `transition/4`, `release/3`, `sweep/2` all take
`Store.store_ref()`) for a documentation-grade gain, and the policy is already stated in each
raise message. Worth folding into a future store-API task if the tuple form is ever generalized.
