// Sell 1 OMNI for 1 LINK on pair_id=7. sellerEvm = slot 6 (same as buyer for test).
const { HDKey } = require("@scure/bip32");
const { mnemonicToSeedSync } = require("@scure/bip39");
const { secp256k1 } = require("@noble/curves/secp256k1");
const { sha256 } = require("@noble/hashes/sha256");
const { keccak_256 } = require("@noble/hashes/sha3");

const dev = "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about";
const root = HDKey.fromMasterSeed(mnemonicToSeedSync(dev));
const leaf = root.derive("m/44'/777'/0'/0/0");

const addr = "ob1qw6zhsqg29aht23fksk5w54lkgavatpgltqxlvl";
// Deliver LINK to deployer slot 6 EVM addr (the buyer's own addr — fine for a round-trip test).
const sellerEvm = "0xc5A63d78B451768Ba1dc799Fb08Ad41c6b37C938";

const side = "sell", pairId = 7, price = 1000000, amount = 1000000000; // 1 OMNI @ 1 USDC
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
    publicKey: Buffer.from(leaf.publicKey).toString("hex"),
    sellerEvm,
  }
};

(async () => {
  const r = await fetch("http://127.0.0.1:18333", {
    method: "POST", headers: { "Content-Type": "application/json" },
    body: JSON.stringify(body),
  });
  console.log(await r.text());
})();
