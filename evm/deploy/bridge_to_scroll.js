// Bridge 0.05 ETH from Sepolia → Scroll Sepolia using L1ETHGateway.
// Contract from Scroll docs: 0x8A54A2347Da2562917304141ab67324615e9866d
//
// Standard Scroll ETH bridge: depositETH(uint256 _amount, uint256 _gasLimit) payable
// gasLimit = 200000 covers a simple ETH deposit on L2.

const { HDKey } = require("@scure/bip32");
const { mnemonicToSeedSync } = require("@scure/bip39");
const { Wallet, JsonRpcProvider, Contract, parseEther, formatEther } = require("ethers");
const fs = require("fs");

const L1_GATEWAY = "0x8A54A2347Da2562917304141ab67324615e9866d";
const ABI = [
  "function depositETH(uint256 _amount, uint256 _gasLimit) payable",
];

const m = fs.readFileSync(".mnemonic", "utf8").trim();
const root = HDKey.fromMasterSeed(mnemonicToSeedSync(m));
const slot6 = root.derive("m/44'/60'/0'/0/6");
const provider = new JsonRpcProvider("https://ethereum-sepolia-rpc.publicnode.com", 11155111);
const wallet = new Wallet("0x" + Buffer.from(slot6.privateKey).toString("hex"), provider);

(async () => {
  console.log(`from ${wallet.address}`);
  console.log(`Sepolia ETH: ${formatEther(await provider.getBalance(wallet.address))}`);
  const amount = parseEther("0.05");
  // Cover gas overhead: send slightly more than amount via msg.value
  const overhead = parseEther("0.001");
  const gateway = new Contract(L1_GATEWAY, ABI, wallet);
  const tx = await gateway.depositETH(amount, 200000, { value: amount + overhead });
  console.log(`L1 tx: ${tx.hash}`);
  await tx.wait();
  console.log(`bridged 0.05 ETH to Scroll Sepolia — lands at ${wallet.address} on L2 in ~10-30 min`);
})();
