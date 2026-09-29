// Signs a 32-byte digest with a fresh P-256 key through ox, the reference Tempo
// signer, and prints the 130-byte Tempo signature envelope plus the key's address.
// `prehash` picks both what ox signs (SHA256(digest) when true) and the envelope flag.
import { Address, P256 } from "ox"
import { SignatureEnvelope } from "ox/tempo"

const { digest, prehash } = JSON.parse(process.argv[2])
const privateKey = P256.randomPrivateKey()
const publicKey = P256.getPublicKey({ privateKey })
const signature = P256.sign({ payload: digest, privateKey, hash: prehash })

console.log(JSON.stringify({
  address: Address.fromPublicKey(publicKey),
  envelope: SignatureEnvelope.serialize({ type: "p256", prehash, publicKey, signature }),
  oxVerifies: SignatureEnvelope.verify(SignatureEnvelope.from({ type: "p256", prehash, publicKey, signature }), {
    payload: digest,
    publicKey,
  }),
}))
