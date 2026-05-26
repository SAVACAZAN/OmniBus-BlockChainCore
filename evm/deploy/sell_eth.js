const { HDKey } = require("@scure/bip32");
const { mnemonicToSeedSync } = require("@scure/bip39");
const { secp256k1 } = require("@noble/curves/secp256k1");
const { sha256 } = require("@noble/hashes/sha256");
const { keccak_256 } = require("@noble/hashes/sha3");

const dev = "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about";
const root = HDKey.fromMasterSeed(mnemonicToSeedSync(dev));
const leaf = root.derive("m/44'/777'/0'/0/0");
const evmLeaf = root.derive("m/44'/60'/0'/0/0");
const addr = "ob1qw6zhsqg29aht23fksk5w54lkgavatpgltqxlvl";
const sellerEvm = "0x" + Buffer.from(keccak_256(secp256k1.ProjectivePoint.fromHex(evmLeaf.publicKey).toRawBytes(false).slice(1)).slice(12)).toString("hex");

// pair_id=6 OMNI/ETH. For OMNI/ETH on testnet the chain uses price as
// the same scale as USDC (micro-USD); since this is testnet matching just
// needs price > 0 and amount > 0. Sell 1 OMNI @ price=100000 (arbitrary)
// = 0.1 in price-units. Amount=1_000_000_000 SAT = 1 OMNI.
const side="sell", pairId=6, price=100000, amount=1000000000;
const nonce=Date.now();
const msg=`EXCHANGE_ORDER_V1\n${side}\n${pairId}\n${price}\n${amount}\n${nonce}\n${addr}`;
const h=sha256(sha256(new TextEncoder().encode(msg)));
const sig=secp256k1.sign(h, leaf.privateKey, { lowS: true });
console.log(JSON.stringify({
  trader:addr, side, pairId, price, amount, nonce,
  signature: Buffer.from(sig.toCompactRawBytes()).toString("hex"),
  publicKey: Buffer.from(leaf.publicKey).toString("hex"),
  sellerEvm,
}));
