// Probe the settle() call as the operator — use callStatic to get the revert reason.
const { HDKey } = require("@scure/bip32");
const { mnemonicToSeedSync } = require("@scure/bip39");
const { Wallet, JsonRpcProvider, Contract } = require("ethers");
const fs = require("fs");

const DEX = "0xC21fD92e5f568a7981d16b9008E3C190842818aE";
const ABI = [
  "function settle(uint256 orderId, address seller)",
  "function operator() view returns (address)",
];

const m = fs.readFileSync(".mnemonic", "utf8").trim();
const root = HDKey.fromMasterSeed(mnemonicToSeedSync(m));
// Operator is slot 2 (m/44'/60'/0'/0/2)
const slot2 = root.derive("m/44'/60'/0'/0/2");
const provider = new JsonRpcProvider("https://ethereum-sepolia-rpc.publicnode.com", 11155111);
const wallet = new Wallet("0x" + Buffer.from(slot2.privateKey).toString("hex"), provider);

(async () => {
  console.log(`our operator key (slot 2): ${wallet.address}`);
  const dex = new Contract(DEX, ABI, wallet);
  const onchain_op = await dex.operator();
  console.log(`contract operator():     ${onchain_op}`);
  console.log(`match: ${onchain_op.toLowerCase() === wallet.address.toLowerCase()}`);

  // Try to estimate gas — if it reverts, ethers surfaces the reason.
  const seller = "0xc5A63d78B451768Ba1dc799Fb08Ad41c6b37C938";
  const orderId = 1778969273121603n;
  try {
    const gas = await dex.settle.estimateGas(orderId, seller);
    console.log(`gas estimate ok: ${gas}`);
    const bal = await provider.getBalance(wallet.address);
    console.log(`operator ETH balance: ${bal} wei`);
  } catch (e) {
    console.log(`estimateGas revert: ${e.shortMessage || e.message}`);
    console.log(`  data: ${e.data || "none"}`);
  }
})();
