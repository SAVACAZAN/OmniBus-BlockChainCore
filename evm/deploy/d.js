const { HDKey } = require("@scure/bip32");
const { mnemonicToSeedSync } = require("@scure/bip39");
const { secp256k1 } = require("@noble/curves/secp256k1");
const { keccak_256 } = require("@noble/hashes/sha3");
function addrFor(pub) {
  const point = secp256k1.ProjectivePoint.fromHex(pub);
  return "0x" + Buffer.from(keccak_256(point.toRawBytes(false).slice(1)).slice(12)).toString("hex");
}
const mA = "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about";
const sA = mnemonicToSeedSync(mA);
const rA = HDKey.fromMasterSeed(sA);
console.log("User A (dev) slot 0 EVM:", addrFor(rA.derive("m/44'/60'/0'/0/0").publicKey));
console.log("User A (dev) OMNI slot 0: ob1qw6zhsqg29aht23fksk5w54lkgavatpgltqxlvl");

// User B uses the founder mnemonic (the one stored in .mnemonic file)
const fs = require("fs");
const mB = fs.readFileSync(".mnemonic", "utf8").trim();
const sB = mnemonicToSeedSync(mB);
const rB = HDKey.fromMasterSeed(sB);
console.log("\nUser B (founder) slot 0 EVM:", addrFor(rB.derive("m/44'/60'/0'/0/0").publicKey));
