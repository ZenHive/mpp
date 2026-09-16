import { concat, createClient, http, keccak256 } from "viem"
import { tempoTestnet } from "viem/chains"
import { Actions, Account } from "viem/tempo"
import { generatePrivateKey, privateKeyToAccount } from "viem/accounts"
import { P256 } from "ox"
import { SignatureEnvelope } from "ox/tempo"

const { action, accessKeyAddress, rootPrivateKey, rpcUrl, digest, version = 0 } = JSON.parse(process.argv[2])
const root = privateKeyToAccount(rootPrivateKey)
const privateKey = generatePrivateKey()
const publicKey = P256.getPublicKey({ privateKey })
const accessKey = Account.fromP256(privateKey, { access: root })
const client = createClient({
  account: root,
  chain: tempoTestnet,
  transport: http(rpcUrl),
})

if (action === "revoke") {
  const { receipt } = await Actions.accessKey.revokeSync(client, { accessKey: accessKeyAddress })
  if (receipt.status !== "success") throw new Error("P-256 revocation reverted")
  console.log(JSON.stringify({ revoked: true }))
  process.exit(0)
}

const payload = version === 4 ? keccak256(concat(["0x04", digest, root.address])) : digest
const prefix = version ? concat([version === 3 ? "0x03" : "0x04", root.address]) : "0x"
const { receipt } = await Actions.accessKey.authorizeSync(client, { accessKey })
if (receipt.status !== "success") throw new Error("P-256 authorization reverted")
const signatures = [false, true].map((prehash) => SignatureEnvelope.serialize({
  type: "p256",
  prehash,
  publicKey,
  signature: P256.sign({ payload, privateKey, hash: prehash }),
}))
const wrongKey = Account.fromP256(generatePrivateKey())
console.log(JSON.stringify({
  accessKeyAddress: accessKey.accessKeyAddress,
  signatures,
  prefix,
  payload,
  wrongSignature: concat([prefix, await wrongKey.sign({ hash: payload })]),
  authorizationHash: receipt.transactionHash,
}))
