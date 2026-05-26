const { HDKey } = require("@scure/bip32");
const { mnemonicToSeedSync } = require("@scure/bip39");
const { secp256k1 } = require("@noble/curves/secp256k1");
const { sha256 } = require("@noble/hashes/sha256");
const { ripemd160 } = require("@noble/hashes/ripemd160");
const { bech32 } = require("@scure/base");
const fs = require("fs");

const m = fs.readFileSync(".mnemonic", "utf8").trim();
const root = HDKey.fromMasterSeed(mnemonicToSeedSync(m));
const leaf = root.derive("m/44'/777'/0'/0/1"); // slot 1 OMNI
const pub = secp256k1.ProjectivePoint.fromHex(leaf.publicKey).toRawBytes(true); // compressed
const h160 = ripemd160(sha256(pub));
const words = bech32.toWords(h160);
const addr = bech32.encode("ob", [0, ...words]);
console.log("slot 1 OMNI:", addr);
