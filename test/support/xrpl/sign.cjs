// Test-only signing with the XRPL-owned SDK; production verification is native Elixir.
const xrpl = require(process.env.XRPL_JS_PATH || '../../../tmp/xrpl/node_modules/xrpl');
const input = JSON.parse(process.argv[2]);
const wallet = input.seed
  ? xrpl.Wallet.fromSeed(input.seed, input.algorithm ? {algorithm: input.algorithm} : {})
  : input.algorithm
    ? xrpl.Wallet.generate(input.algorithm)
    : xrpl.Wallet.generate();
if (input.claim) {
  const signature = xrpl.authorizeChannel(wallet, input.claim.channel, input.claim.amount);
  process.stdout.write(
    JSON.stringify({
      signature,
      publicKey: wallet.publicKey,
      address: wallet.address,
      seed: wallet.seed,
    }),
  );
} else if (input.tx) {
  process.stdout.write(JSON.stringify(wallet.sign(input.tx)));
} else {
  process.stdout.write(
    JSON.stringify({seed: wallet.seed, address: wallet.address, publicKey: wallet.publicKey}),
  );
}
