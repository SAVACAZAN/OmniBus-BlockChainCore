const { HDKey } = require("@scure/bip32");
const { mnemonicToSeedSync } = require("@scure/bip39");
const { secp256k1 } = require("@noble/curves/secp256k1");
const { keccak_256 } = require("@noble/hashes/sha3");
function addr(pub) {
  const point = secp256k1.ProjectivePoint.fromHex(pub);
  return "0x" + Buffer.from(keccak_256(point.toRawBytes(false).slice(1)).slice(12)).toString("hex");
}
const dev = "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about";
const root = HDKey.fromMasterSeed(mnemonicToSeedSync(dev));
console.log("dev slot 2 EVM:", addr(root.derive("m/44'/60'/0'/0/2").publicKey));
