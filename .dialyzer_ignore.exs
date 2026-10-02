[
  # Mix.Task callback info not available in Dialyzer PLT
  {"lib/mix/tasks/mpp.manifest.ex", :callback_info_missing},
  # onchain_tempo 0.13 types Transaction.t with non-nil `raw` and `signature`,
  # but its Builder signs a struct carrying `raw: nil` / `signature: nil`, so
  # Dialyzer infers build_signed_multicall/1 and build_fee_payer_multicall/1 as
  # never returning {:ok, _}. Live and unit tests exercise the success path.
  # Remove once onchain_tempo ships a Transaction.t that admits the unsigned shape.
  {"lib/mpp/client/providers/tempo.ex", :pattern_match},
  {"lib/mpp/client/providers/tempo.ex", :unused_fun}
]
