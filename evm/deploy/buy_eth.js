// Place a native-ETH BUY order on OmnibusDEX Sepolia (pair_id=6 in OmniBus).
// User B (founder) locks a small amount of ETH so the chain can match it
// against a SELL OMNI order. On fill, the dex_settler pays the seller's
// EVM address that amount in ETH.

const { HDKey } = require("@scure/bip32");
const { mnemonicToSeedSync } = require("@scure/bip39");
const { Wallet, JsonRpcProvider, Contract, keccak256, toUtf8Bytes, parseEther, formatEther } = require("ethers");
const fs = require("fs");

const DEX_ABI = [
  {name:"placeBuyOrderNative",type:"function",stateMutability:"payable",
    inputs:[{name:"orderId",type:"uint256"},{name:"omniRecipient",type:"bytes32"},{name:"expiresAt",type:"uint64"}],outputs:[]},
];

const DEX = "0xC21fD92e5f568a7981d16b9008E3C190842818aE";

const founder = fs.readFileSync(".mnemonic", "utf8").trim();
const root = HDKey.fromMasterSeed(mnemonicToSeedSync(founder));
const leaf = root.derive("m/44'/60'/0'/0/0");
const provider = new JsonRpcProvider("https://ethereum-sepolia-rpc.publicnode.com", 11155111);
const wallet = new Wallet("0x" + Buffer.from(leaf.privateKey).toString("hex"), provider);

const buyerOmni = "ob1qzhrauq0xe9hg033ccup7vlgsdmj6kcxyza9zp0";
// Lock 0.0001 ETH — enough to land via gas, small enough to leave reserves.
const ethAmount = parseEther("0.0001");
const orderId = BigInt(Date.now()) * 1000n + BigInt(Math.floor(Math.random() * 1000));
const expiresAt = Math.floor(Date.now() / 1000) + 24 * 3600;
const omniCommit = keccak256(toUtf8Bytes(buyerOmni));

(async () => {
  const bal = await provider.getBalance(wallet.address);
  console.log("buyer EVM:", wallet.address);
  console.log("buyer ETH balance:", formatEther(bal));
  if (bal < ethAmount + parseEther("0.001")) {
    console.error("Not enough ETH — need at least 0.0011 for tx + escrow.");
    process.exit(1);
  }

  const dex = new Contract(DEX, DEX_ABI, wallet);
  console.log("\nplaceBuyOrderNative(orderId, omniRecip, expiresAt) value=0.0001 ETH");
  console.log("  orderId:", orderId.toString());
  const tx = await dex.placeBuyOrderNative(orderId, omniCommit, expiresAt, { value: ethAmount });
  console.log("  tx:", tx.hash);
  await tx.wait();
  console.log("  locked");

  console.log("\nORDER_ID=" + orderId.toString());
})();
