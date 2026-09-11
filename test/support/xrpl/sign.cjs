// Test-only signing with the XRPL-owned SDK; production verification is native Elixir.
const xrpl = require(process.env.XRPL_JS_PATH || '../../../tmp/xrpl/node_modules/xrpl');
const input = JSON.parse(process.argv[2]);
const wallet = input.seed ? xrpl.Wallet.fromSeed(input.seed) : xrpl.Wallet.generate();
process.stdout.write(JSON.stringify(input.tx ? wallet.sign(input.tx) : {seed: wallet.seed, address: wallet.address}));
