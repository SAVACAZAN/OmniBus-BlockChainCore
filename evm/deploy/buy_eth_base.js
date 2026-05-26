const { HDKey } = require("@scure/bip32");
const { mnemonicToSeedSync } = require("@scure/bip39");
const { Wallet, JsonRpcProvider, Contract, keccak256, toUtf8Bytes, parseEther, formatEther } = require("ethers");
const fs = require("fs");

const DEX_ABI = [
  {name:"placeBuyOrderNative",type:"function",stateMutability:"payable",
    inputs:[{name:"orderId",type:"uint256"},{name:"omniRecipient",type:"bytes32"},{name:"expiresAt",type:"uint64"}],outputs:[]},
];
const DEX = "0xAEE1B7dC7a010b6C6D6097BD7d9dDf227aF719EB"; // Base Sepolia

const m = fs.readFileSync(".mnemonic", "utf8").trim();
const root = HDKey.fromMasterSeed(mnemonicToSeedSync(m));
const leaf = root.derive("m/44'/60'/0'/0/0");
const provider = new JsonRpcProvider("https://sepolia.base.org", 84532);
const wallet = new Wallet("0x" + Buffer.from(leaf.privateKey).toString("hex"), provider);

const buyerOmni = "ob1qzhrauq0xe9hg033ccup7vlgsdmj6kcxyza9zp0";
const ethAmount = parseEther("0.0001");
const orderId = BigInt(Date.now()) * 1000n + BigInt(Math.floor(Math.random() * 1000));
const expiresAt = Math.floor(Date.now() / 1000) + 24 * 3600;
const omniCommit = keccak256(toUtf8Bytes(buyerOmni));

(async () => {
  console.log(`buyer ${wallet.address} ETH: ${formatEther(await provider.getBalance(wallet.address))} ETH`);
  const dex = new Contract(DEX, DEX_ABI, wallet);
  console.log(`placeBuyOrderNative on Base Sepolia, orderId=${orderId}`);
  const tx = await dex.placeBuyOrderNative(orderId, omniCommit, expiresAt, { value: ethAmount });
  console.log(`tx: ${tx.hash}`);
  await tx.wait();
  console.log(`locked. ORDER_ID=${orderId.toString()}`);
})();
