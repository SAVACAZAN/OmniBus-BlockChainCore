const { HDKey } = require("@scure/bip32");
const { mnemonicToSeedSync } = require("@scure/bip39");
const { secp256k1 } = require("@noble/curves/secp256k1");
const { sha256 } = require("@noble/hashes/sha256");

const args = process.argv.slice(2);
const [mn, addr, sideStr, pairIdStr, priceStr, amountStr] = args;

const root = HDKey.fromMasterSeed(mnemonicToSeedSync(mn));
const leaf = root.derive("m/44'/777'/0'/0/0");
const pubkey = Buffer.from(leaf.publicKey).toString("hex");

const nonce = Date.now();
const msg = `EXCHANGE_ORDER_V1\n${sideStr}\n${pairIdStr}\n${priceStr}\n${amountStr}\n${nonce}\n${addr}`;
const h1 = sha256(new TextEncoder().encode(msg));
const h2 = sha256(h1);  // double SHA256
const sig = secp256k1.sign(h2, leaf.privateKey, { lowS: true });
const sigBytes = sig.toCompactRawBytes();
console.log(JSON.stringify({
  trader: addr, side: sideStr, pairId: Number(pairIdStr),
  price: Number(priceStr), amount: Number(amountStr), nonce,
  signature: Buffer.from(sigBytes).toString("hex"),
  publicKey: pubkey,
}));
