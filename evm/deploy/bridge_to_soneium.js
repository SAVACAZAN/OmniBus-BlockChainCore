// Bridge 0.05 ETH from Sepolia → Soneium Minato testnet using the
// official L1StandardBridge. ETH lands at the same address on L2 (~3 min).
//
// Contract addresses from docs.soneium.org/builders/contracts:
//   L1StandardBridge:  0x5f5a404A5edabcDD80DB05E8e54A78c9EBF000C2
//   OptimismPortal:    0x65ea1489741A5D72fFdD8e6485B216bBdcC15Af3
//
// The L1StandardBridge.bridgeETH(uint32 _minGasLimit, bytes _extraData)
// sends msg.value to msg.sender on L2 by default. minGasLimit=200_000
// covers the simple deposit case.

const { HDKey } = require("@scure/bip32");
const { mnemonicToSeedSync } = require("@scure/bip39");
const { Wallet, JsonRpcProvider, Contract, parseEther, formatEther } = require("ethers");
const fs = require("fs");

const L1_BRIDGE = "0x5f5a404A5edabcDD80DB05E8e54A78c9EBF000C2";
const ABI = [
  "function bridgeETH(uint32 _minGasLimit, bytes _extraData) payable",
];

const m = fs.readFileSync(".mnemonic", "utf8").trim();
const root = HDKey.fromMasterSeed(mnemonicToSeedSync(m));
const slot6 = root.derive("m/44'/60'/0'/0/6");
const provider = new JsonRpcProvider("https://ethereum-sepolia-rpc.publicnode.com", 11155111);
const wallet = new Wallet("0x" + Buffer.from(slot6.privateKey).toString("hex"), provider);

(async () => {
  console.log(`deployer ${wallet.address}`);
  console.log(`Sepolia ETH balance: ${formatEther(await provider.getBalance(wallet.address))}`);
  const bridge = new Contract(L1_BRIDGE, ABI, wallet);
  const amount = parseEther("0.05");
  console.log(`bridging ${formatEther(amount)} ETH Sepolia → Soneium Minato…`);
  const tx = await bridge.bridgeETH(200000, "0x", { value: amount });
  console.log(`L1 tx: ${tx.hash}`);
  await tx.wait();
  console.log(`L1 confirmed. ETH lands on Minato in ~3 min at the same address.`);
})();
