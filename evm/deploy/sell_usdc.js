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

// pair_id 0 = OMNI/USDC, price in micro-USD per OMNI, amount in SAT
// Sell 5 OMNI @ 1.0 USDC each = 5 USDC total (matches escrow)
const side="sell", pairId=0, price=1000000, amount=5000000000;
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
