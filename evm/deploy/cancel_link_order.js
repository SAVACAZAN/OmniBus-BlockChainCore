// Cancel order 1778963547691173 from buyer (slot 6) to refund 1 LINK.
const { HDKey } = require("@scure/bip32");
const { mnemonicToSeedSync } = require("@scure/bip39");
const { Wallet, JsonRpcProvider, Contract } = require("ethers");
const fs = require("fs");

const DEX = "0xC21fD92e5f568a7981d16b9008E3C190842818aE";
const ABI = ["function cancelOrder(uint256 orderId)"];

const m = fs.readFileSync(".mnemonic", "utf8").trim();
const root = HDKey.fromMasterSeed(mnemonicToSeedSync(m));
const slot6 = root.derive("m/44'/60'/0'/0/6");
const provider = new JsonRpcProvider("https://ethereum-sepolia-rpc.publicnode.com", 11155111);
const wallet = new Wallet("0x" + Buffer.from(slot6.privateKey).toString("hex"), provider);

(async () => {
  console.log(`canceller: ${wallet.address}`);
  const dex = new Contract(DEX, ABI, wallet);
  const tx = await dex.cancelOrder(1778963547691173n);
  console.log(`tx: ${tx.hash}`);
  const r = await tx.wait();
  console.log(`cancelled in block ${r.blockNumber}, gasUsed ${r.gasUsed}`);
})();
