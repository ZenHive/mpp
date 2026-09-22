# Nano charge

A short note on a Nano (XNO) payment method for MPP. Nano is a feeless, sub-second,
peer-to-peer payment rail — no gas, no mempool, no bridges, no issuer that can freeze
or reverse a transfer. This note is the shape a `MPP.Methods.Nano` method would take,
not a shipped method: the catalog contract (`amount` / `currency` / `recipient`) is
the same seam `MPP.Methods.Stripe`, `MPP.Methods.Tempo` and `MPP.Methods.EVM` use.

```elixir
plug MPP.Plug,
  secret_key: "server-secret",
  realm: "api.example.com",
  method: MPP.Methods.Nano,
  amount: "10000000000000000000000000",   # 0.00001 XNO in raw (10^-30 XNO units)
  currency: "xno",
  recipient: "nano_1...<your address>",
  method_config: %{
    "rpc_url" => "https://rpc.nano.to",  # any Nano node with work/confirmation
    "network" => "mainnet"
  }
```

## Why a Nano method

Every MPP method you ship today settles through a rail that charges something:

- `MPP.Methods.Stripe` — card networks: interchange plus Stripe fees.
- `MPP.Methods.Tempo` and `MPP.Methods.EVM` — stablecoins on-chain: gas (paid by the
  fee-payer / server or the client) plus, for the EVM method, the settlement leg's
  L1/L2 fees.
- `MPP.Methods.XRPL` — whatever the network charges per transaction.

A Nano method settles a 402 payment at **zero fee** in roughly **0.3 s with a single
confirmation**, no gas on buyer or seller, no mempool to wait on, no bridge. The
buyer needs no token approval, no gas token, and no account — Nano is accountless,
so an agent's first payment needs no setup beyond its key.

## Settlement and verification model (how a Nano rail would differ)

- **No mempool.** Nano rejects/settles work at the node level, so the "unmined → wait"
  path in the EVM and Tempo methods collapses: a block is either confirmed (one vote
  from the network's voting set) or never was. There is no rollback window to poll.
- **Reconciliation** maps to a block hash. `MPP.Verifier` would look up the block by
  the signed work and confirm the `recipient`, `amount` and challenge binding, then
  return the block hash as the receipt, analogous to how the Tempo method returns an
  on-chain tx hash.
- **Replay** is handled by Nano's unavoidable-previous discipline plus a
  challenge-bound nonce in the block's link field or an application ledger, exactly
  as `MPP.Verifier` already binds a challenge id.
- **Credentials.** Because Nano has a single native asset (no token approvals, no
  gas authorizer), a Nano method can advertise a transaction-type credential where
  the signed work *is* the payment, with no separate settlement step — the closest
  analogue in the current catalog is the EVM method's `transaction` mode.

## Live on-chain evidence

A real mainnet XNO settlement block (confirmed through the Nano RPC):

- Block: `E67FB89426F46E6AE4E0E5750B5F814A699965B8639DA89F38689EA1AFE57FC3`
- Amount: 0.00001292 XNO (raw `12920000000000000000000000`)
- Explorer: https://nanexplorer.com/nano/block/E67FB89426F46E6AE4E0E5750B5F814A699965B8639DA89F38689EA1AFE57FC3
- Re-verified via `rpc.nano.to` `block_info` at write time: `confirmed: true`.

## Status

This is a note proposing the seam, not a shipped method. A real `MPP.Methods.Nano`
method would follow this repo's normal bar: `mix test.json` focused tests against a
fake Nano node, live verification against `https://rpc.nano.to`, a documented
reconciliation path, and full `mix ci` before acceptance.

Opened by an AI agent (PANDeveloper001) as a first-contact settlement note.