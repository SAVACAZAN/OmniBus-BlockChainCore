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

const USDC = "0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238";
const DEX  = "0xC21fD92e5f568a7981d16b9008E3C190842818aE";

const founder = fs.readFileSync(".mnemonic", "utf8").trim();
const root = HDKey.fromMasterSeed(mnemonicToSeedSync(founder));
const leaf = root.derive("m/44'/60'/0'/0/0");
const provider = new JsonRpcProvider("https://ethereum-sepolia-rpc.publicnode.com", 11155111);
const wallet = new Wallet("0x" + Buffer.from(leaf.privateKey).toString("hex"), provider);

const buyerOmni = "ob1qzhrauq0xe9hg033ccup7vlgsdmj6kcxyza9zp0";
const amount = parseUnits("5", 6); // 5 USDC (6 decimals)
const orderId = BigInt(Date.now()) * 1000n + BigInt(Math.floor(Math.random() * 1000));
const expiresAt = Math.floor(Date.now() / 1000) + 24 * 3600;
const omniCommit = keccak256(toUtf8Bytes(buyerOmni));

(async () => {
  const usdc = new Contract(USDC, ERC20_ABI, wallet);
  const dex  = new Contract(DEX, DEX_ABI, wallet);

  console.log("=== Step 1: approve(DEX, 5 USDC) ===");
  const current = await usdc.allowance(wallet.address, DEX);
  console.log("  current allowance:", formatUnits(current, 6), "USDC");
  if (current < amount) {
    const ap = await usdc.approve(DEX, amount);
    console.log("  approve tx:", ap.hash);
    await ap.wait();
    console.log("  ✓ approved");
  } else {
    console.log("  allowance sufficient, skip");
  }

  console.log("\n=== Step 2: placeBuyOrder(orderId, USDC, 5 USDC, omniRecip, expiresAt) ===");
  console.log("  orderId:", orderId.toString());
  console.log("  amount: ", formatUnits(amount, 6), "USDC");
  const tx = await dex.placeBuyOrder(orderId, USDC, amount, omniCommit, expiresAt);
  console.log("  tx:", tx.hash);
  await tx.wait();
  console.log("  ✓ locked");

  console.log("\nORDER_ID=" + orderId.toString());
})();
