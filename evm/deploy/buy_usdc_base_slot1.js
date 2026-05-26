// Slot #1 (0x2680...3E0) has 20 USDC on Base Sepolia. Lock 5 USDC into
// the OmnibusDEX as a BUY-OMNI escrow. Buyer's OMNI side is slot 1
// (ob1q8wm5est4fft7mrj937sg9uyaz2nskgttf3ku5u).

const { HDKey } = require("@scure/bip32");
const { mnemonicToSeedSync } = require("@scure/bip39");
const { Wallet, JsonRpcProvider, Contract, keccak256, toUtf8Bytes, parseUnits, formatUnits } = require("ethers");
const fs = require("fs");

const ERC20_ABI = [
  {name:"approve",type:"function",stateMutability:"nonpayable",inputs:[{name:"s",type:"address"},{name:"a",type:"uint256"}],outputs:[{type:"bool"}]},
  {name:"allowance",type:"function",stateMutability:"view",inputs:[{name:"o",type:"address"},{name:"s",type:"address"}],outputs:[{type:"uint256"}]},
];
const DEX_ABI = [
  {name:"placeBuyOrder",type:"function",stateMutability:"nonpayable",
    inputs:[{name:"orderId",type:"uint256"},{name:"token",type:"address"},{name:"amount",type:"uint256"},{name:"omniRecipient",type:"bytes32"},{name:"expiresAt",type:"uint64"}],outputs:[]},
];

const USDC = "0x036CbD53842c5426634e7929541eC2318f3dCF7e"; // USDC Circle Base Sepolia
const DEX  = "0xAEE1B7dC7a010b6C6D6097BD7d9dDf227aF719EB"; // OmnibusDEX Base Sepolia

const m = fs.readFileSync(".mnemonic", "utf8").trim();
const root = HDKey.fromMasterSeed(mnemonicToSeedSync(m));
const leaf = root.derive("m/44'/60'/0'/0/1"); // slot 1 EVM
const provider = new JsonRpcProvider("https://sepolia.base.org", 84532);
const wallet = new Wallet("0x" + Buffer.from(leaf.privateKey).toString("hex"), provider);

const buyerOmni = "ob1q8wm5est4fft7mrj937sg9uyaz2nskgttf3ku5u"; // slot 1 OMNI
const amount = parseUnits("5", 6); // 5 USDC
const orderId = BigInt(Date.now()) * 1000n + BigInt(Math.floor(Math.random() * 1000));
const expiresAt = Math.floor(Date.now() / 1000) + 24 * 3600;
const omniCommit = keccak256(toUtf8Bytes(buyerOmni));

(async () => {
  console.log(`buyer EVM (slot 1): ${wallet.address}`);
  const usdc = new Contract(USDC, ERC20_ABI, wallet);
  const dex  = new Contract(DEX, DEX_ABI, wallet);

  console.log("=== Step 1: approve(DEX, 5 USDC) ===");
  const current = await usdc.allowance(wallet.address, DEX);
  console.log("  current allowance:", formatUnits(current, 6), "USDC");
  if (current < amount) {
    const ap = await usdc.approve(DEX, amount);
    console.log("  approve tx:", ap.hash);
    await ap.wait();
    console.log("  approved");
  } else {
    console.log("  allowance sufficient, skip");
  }

  console.log("\n=== Step 2: placeBuyOrder on Base Sepolia ===");
  console.log("  orderId:", orderId.toString());
  const tx = await dex.placeBuyOrder(orderId, USDC, amount, omniCommit, expiresAt);
  console.log("  tx:", tx.hash);
  await tx.wait();
  console.log("  locked\n");
  console.log("ORDER_ID=" + orderId.toString());
})();
