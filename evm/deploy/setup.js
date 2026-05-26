const { HDKey } = require("@scure/bip32");
const { mnemonicToSeedSync } = require("@scure/bip39");
const { secp256k1 } = require("@noble/curves/secp256k1");
const { keccak_256 } = require("@noble/hashes/sha3");
const { JsonRpcProvider, formatEther } = require("ethers");
const fs = require("fs");

function evmAddr(pub) {
  const point = secp256k1.ProjectivePoint.fromHex(pub);
  return "0x" + Buffer.from(keccak_256(point.toRawBytes(false).slice(1)).slice(12)).toString("hex");
}

const dev = "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about";
const rootA = HDKey.fromMasterSeed(mnemonicToSeedSync(dev));

const founder = fs.readFileSync(".mnemonic", "utf8").trim();
const rootB = HDKey.fromMasterSeed(mnemonicToSeedSync(founder));

console.log("=== User A (seller, dev) ===");
console.log("  OMNI slot 0:", "ob1qw6zhsqg29aht23fksk5w54lkgavatpgltqxlvl");
console.log("  EVM  slot 0:", evmAddr(rootA.derive("m/44'/60'/0'/0/0").publicKey));

console.log("\n=== User B (buyer, founder) ===");
console.log("  OMNI slot 0:", "ob1qzhrauq0xe9hg033ccup7vlgsdmj6kcxyza9zp0");
console.log("  EVM  slot 0:", evmAddr(rootB.derive("m/44'/60'/0'/0/0").publicKey));

const p = new JsonRpcProvider("https://ethereum-sepolia-rpc.publicnode.com", 11155111);
(async () => {
  const userBeth = await p.getBalance(evmAddr(rootB.derive("m/44'/60'/0'/0/0").publicKey));
  console.log("\nUser B Sepolia ETH balance:", formatEther(userBeth), "ETH");
})();
