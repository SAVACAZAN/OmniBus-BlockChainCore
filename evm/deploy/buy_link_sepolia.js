// Slot 6 has 25 LINK on Sepolia. Lock 1 LINK in OmnibusDEX as a BUY-OMNI
// escrow for pair_id=7 (OMNI/LINK).
const { HDKey } = require("@scure/bip32");
const { mnemonicToSeedSync } = require("@scure/bip39");
const { Wallet, JsonRpcProvider, Contract, keccak256, toUtf8Bytes, parseUnits, formatUnits } = require("ethers");
const fs = require("fs");

const LINK_SEPOLIA = "0x779877A7B0D9E8603169DdbD7836e478b4624789";
const DEX_SEPOLIA  = "0xC21fD92e5f568a7981d16b9008E3C190842818aE";

const ERC20_ABI = [
  {name:"approve",type:"function",stateMutability:"nonpayable",inputs:[{name:"s",type:"address"},{name:"a",type:"uint256"}],outputs:[{type:"bool"}]},
  {name:"allowance",type:"function",stateMutability:"view",inputs:[{name:"o",type:"address"},{name:"s",type:"address"}],outputs:[{type:"uint256"}]},
];
const DEX_ABI = [
  {name:"placeBuyOrder",type:"function",stateMutability:"nonpayable",
    inputs:[{name:"orderId",type:"uint256"},{name:"token",type:"address"},{name:"amount",type:"uint256"},{name:"omniRecipient",type:"bytes32"},{name:"expiresAt",type:"uint64"}],outputs:[]},
];

const m = fs.readFileSync(".mnemonic", "utf8").trim();
const root = HDKey.fromMasterSeed(mnemonicToSeedSync(m));
// Slot 6 has the LINK
const slot6 = root.derive("m/44'/60'/0'/0/6");
const provider = new JsonRpcProvider("https://ethereum-sepolia-rpc.publicnode.com", 11155111);
const wallet = new Wallet("0x" + Buffer.from(slot6.privateKey).toString("hex"), provider);

// We'll use slot 6's OMNI side as the buyer recipient
const buyerOmni = root.derive("m/44'/777'/0'/0/6");
const buyerOmniAddr = require("@noble/hashes/ripemd160").ripemd160;  // not used here — just commit
const omniRecipientStr = "ob1q_slot6_link_test"; // any string; chain computes keccak
const omniCommit = keccak256(toUtf8Bytes(omniRecipientStr));

const amount = parseUnits("1", 18); // 1 LINK (18 decimals)
const orderId = BigInt(Date.now()) * 1000n + BigInt(Math.floor(Math.random() * 1000));
const expiresAt = Math.floor(Date.now() / 1000) + 24 * 3600;

(async () => {
  console.log(`buyer EVM (slot 6): ${wallet.address}`);
  const link = new Contract(LINK_SEPOLIA, ERC20_ABI, wallet);
  const dex = new Contract(DEX_SEPOLIA, DEX_ABI, wallet);

  console.log("=== Step 1: approve(DEX, 1 LINK) ===");
  const current = await link.allowance(wallet.address, DEX_SEPOLIA);
  console.log(`  current allowance: ${formatUnits(current, 18)} LINK`);
  if (current < amount) {
    const ap = await link.approve(DEX_SEPOLIA, amount);
    console.log(`  approve tx: ${ap.hash}`);
    await ap.wait();
    console.log(`  approved`);
  }

  console.log("\n=== Step 2: placeBuyOrder(orderId, LINK, 1 LINK, omniCommit, expiresAt) ===");
  console.log(`  orderId: ${orderId}`);
  const tx = await dex.placeBuyOrder(orderId, LINK_SEPOLIA, amount, omniCommit, expiresAt);
  console.log(`  tx: ${tx.hash}`);
  await tx.wait();
  console.log(`  locked`);
  console.log(`\nORDER_ID=${orderId.toString()}`);
})();
