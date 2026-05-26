// Manual operator settle — same call the Zig settler is trying but failing to submit.
const { HDKey } = require("@scure/bip32");
const { mnemonicToSeedSync } = require("@scure/bip39");
const { Wallet, JsonRpcProvider, Contract } = require("ethers");
const fs = require("fs");

const DEX = "0xC21fD92e5f568a7981d16b9008E3C190842818aE";
const ABI = ["function settle(uint256 orderId, address seller)"];

const m = fs.readFileSync(".mnemonic", "utf8").trim();
const root = HDKey.fromMasterSeed(mnemonicToSeedSync(m));
const slot2 = root.derive("m/44'/60'/0'/0/2"); // operator
const provider = new JsonRpcProvider("https://ethereum-sepolia-rpc.publicnode.com", 11155111);
const wallet = new Wallet("0x" + Buffer.from(slot2.privateKey).toString("hex"), provider);

(async () => {
  const dex = new Contract(DEX, ABI, wallet);
  const seller = "0xc5A63d78B451768Ba1dc799Fb08Ad41c6b37C938";
  const orderId = 1778969273121603n;
  console.log(`settle(${orderId}, ${seller}) as ${wallet.address}`);
  const tx = await dex.settle(orderId, seller);
  console.log(`tx: ${tx.hash}`);
  const r = await tx.wait();
  console.log(`settled in block ${r.blockNumber}, gas ${r.gasUsed}`);
})();
