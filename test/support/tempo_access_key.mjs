/**
 * Moderato access-key authorize/revoke for integration tests.
 *
 * Uses viem/tempo (npx-installed) — not a production dependency.
 * Invoked by `MPP.Test.TempoAccessKey` via `npx -p viem@2.55.18 node …`.
 */
import { createClient, http } from "viem"
import { tempoTestnet } from "viem/chains"
import { Actions, Account } from "viem/tempo"
import { generatePrivateKey, privateKeyToAccount } from "viem/accounts"

const input = JSON.parse(process.argv[2] ?? "{}")
const {
  action,
  rootPrivateKey,
  accessPrivateKey: accessPrivateKeyIn,
  rpcUrl,
  chainId = 42431,
  feeToken = "0x20c0000000000000000000000000000000000000",
} = input

if (!action || !rootPrivateKey || !rpcUrl) {
  console.error(JSON.stringify({ error: "missing action, rootPrivateKey, or rpcUrl" }))
  process.exit(1)
}

const rootAccount = privateKeyToAccount(rootPrivateKey)
const accessPrivateKey = accessPrivateKeyIn ?? generatePrivateKey()
const accessKey = Account.fromSecp256k1(accessPrivateKey, { access: rootAccount })

const client = createClient({
  account: rootAccount,
  chain: tempoTestnet.extend({ id: Number(chainId), feeToken }),
  transport: http(rpcUrl),
})

try {
  if (action === "authorize") {
    await Actions.accessKey.authorizeSync(client, {
      account: rootAccount,
      accessKey,
      feeToken,
    })

    console.log(
      JSON.stringify({
        rootAddress: rootAccount.address,
        accessPrivateKey,
        accessKeyAddress: accessKey.accessKeyAddress,
      }),
    )
  } else if (action === "revoke") {
    await Actions.accessKey.authorizeSync(client, {
      account: rootAccount,
      accessKey,
      feeToken,
    })
    await Actions.accessKey.revokeSync(client, {
      account: rootAccount,
      accessKey,
      feeToken,
    })

    console.log(
      JSON.stringify({
        rootAddress: rootAccount.address,
        accessPrivateKey,
        accessKeyAddress: accessKey.accessKeyAddress,
      }),
    )
  } else {
    console.error(JSON.stringify({ error: `unknown action: ${action}` }))
    process.exit(1)
  }
} catch (error) {
  console.error(JSON.stringify({ error: String(error?.message ?? error) }))
  process.exit(1)
}
