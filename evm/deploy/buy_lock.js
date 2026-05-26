const { HDKey } = require("@scure/bip32");
const { mnemonicToSeedSync } = require("@scure/bip39");
const { Wallet, JsonRpcProvider, Contract, parseEther, keccak256, toUtf8Bytes, formatEther } = require("ethers");
const fs = require("fs");

const ABI = [
  { name: "placeBuyOrderNative", type: "function", stateMutability: "payable",
    inputs: [
      { name: "orderId", type: "uint256" },
      { name: "omniRecipient", type: "bytes32" },
      { name: "expiresAt", type: "uint64" },
    ], outputs: [] },
];

const founder = fs.readFileSync(".mnemonic", "utf8").trim();
const root = HDKey.fromMasterSeed(mnemonicToSeedSync(founder));
const leaf = root.derive("m/44'/60'/0'/0/0");
const privHex = "0x" + Buffer.from(leaf.privateKey).toString("hex");

const provider = new JsonRpcProvider("https://ethereum-sepolia-rpc.publicnode.com", 11155111);
const wallet = new Wallet(privHex, provider);
const dex = new Contract("0xC21fD92e5f568a7981d16b9008E3C190842818aE", ABI, wallet);

// Seller's OMNI address (User A) as keccak256 of bech32 string
const sellerOmniAddr = "ob1qw6zhsqg29aht23fksk5w54lkgavatpgltqxlvl";
// The frontend computes keccak from the BUYER's OMNI address but the
// chain only uses this as a commitment to the recipient (= OMNI seller).
// For our test we put the seller's OMNI address.
const buyerOmniAddr = "ob1qzhrauq0xe9hg033ccup7vlgsdmj6kcxyza9zp0";
const omniCommit = keccak256(toUtf8Bytes(buyerOmniAddr));  // chain uses BUYER addr per current code
const orderId = BigInt(Date.now()) * 1000n + BigInt(Math.floor(Math.random() * 1000));
const expiresAt = Math.floor(Date.now() / 1000) + 24 * 3600;
const amountEth = parseEther("0.005");

console.log("Submitting placeBuyOrderNative...");
console.log("  buyer:    ", wallet.address);
console.log("  amount:   ", formatEther(amountEth), "ETH");
console.log("  orderId:  ", orderId.toString());
console.log("  expiresAt:", new Date(expiresAt*1000).toISOString());

(async () => {
  const tx = await dex.placeBuyOrderNative(orderId, omniCommit, expiresAt, { value: amountEth });
  console.log("  tx hash:", tx.hash);
  console.log("  waiting confirm...");
  const r = await tx.wait();
  console.log("  ✓ mined block", r.blockNumber);
  console.log("\nSAVE orderId for next step:");
  console.log("ORDER_ID=" + orderId.toString());
})();
