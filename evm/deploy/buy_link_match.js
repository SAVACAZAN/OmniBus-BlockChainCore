// BUY 1 OMNI on pair 7, referencing the on-chain escrow.
const { HDKey } = require("@scure/bip32");
const { mnemonicToSeedSync } = require("@scure/bip39");
const { secp256k1 } = require("@noble/curves/secp256k1");
const { sha256 } = require("@noble/hashes/sha256");
const { ripemd160 } = require("@noble/hashes/ripemd160");
const { bech32 } = require("@scure/base");

const EVM_ORDER_ID = 1778969273121603;

const dev = "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about";
const root = HDKey.fromMasterSeed(mnemonicToSeedSync(dev));
const leaf = root.derive("m/44'/777'/0'/0/6");

// OMNI bech32: hrp="ob", witness v0 = 0 + program (20-byte ripemd160(sha256(pubkey)))
const pubkey = leaf.publicKey; // 33-byte compressed
const h160 = ripemd160(sha256(pubkey));
const words = bech32.toWords(h160);
const addr = bech32.encode("ob", [0, ...words]);
console.log("derived addr:", addr);

const side = "buy", pairId = 7, price = 1000000, amount = 1000000000;
const nonce = Date.now();
const msg = `EXCHANGE_ORDER_V1\n${side}\n${pairId}\n${price}\n${amount}\n${nonce}\n${addr}`;
const h = sha256(sha256(new TextEncoder().encode(msg)));
const sig = secp256k1.sign(h, leaf.privateKey, { lowS: true });

const body = {
  jsonrpc: "2.0", id: 1, method: "exchange_placeOrder",
  params: {
    trader: addr,
    side, pairId, price, amount, nonce,
    signature: Buffer.from(sig.toCompactRawBytes()).toString("hex"),
    publicKey: Buffer.from(pubkey).toString("hex"),
    evmOrderId: EVM_ORDER_ID,
  }
};

(async () => {
  const r = await fetch("http://127.0.0.1:18333", {
    method: "POST", headers: { "Content-Type": "application/json" },
    body: JSON.stringify(body),
  });
  console.log(await r.text());
})();
