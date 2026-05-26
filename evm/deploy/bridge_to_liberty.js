// Bridge ETH from Sepolia → Liberty Chain testnet using the OP-stack
// portal at 0xC88823F0142f5c89273Cb6d5b152F6177608A3E9 (found from prior
// successful deposits by slot 0 founder and slot 1).
//
// We use receiveETH() / depositETH() variant common to OP-stack chains —
// for direct ETH bridge, sending msg.value to the OptimismPortal with
// data = "" triggers a deposit to msg.sender on L2.

const { HDKey } = require("@scure/bip32");
const { mnemonicToSeedSync } = require("@scure/bip39");
const { Wallet, JsonRpcProvider, parseEther, formatEther } = require("ethers");
const fs = require("fs");

const PORTAL = "0xC88823F0142f5c89273Cb6d5b152F6177608A3E9";
const m = fs.readFileSync(".mnemonic", "utf8").trim();
const root = HDKey.fromMasterSeed(mnemonicToSeedSync(m));
const slot6 = root.derive("m/44'/60'/0'/0/6");
const provider = new JsonRpcProvider("https://ethereum-sepolia-rpc.publicnode.com");
const wallet = new Wallet("0x" + Buffer.from(slot6.privateKey).toString("hex"), provider);

(async () => {
  console.log(`from ${wallet.address}`);
  console.log(`Sepolia ETH: ${formatEther(await provider.getBalance(wallet.address))}`);
  const amount = parseEther("0.05");
  // Direct send to portal — OP Stack handles this as "deposit eth to msg.sender on L2"
  const tx = await wallet.sendTransaction({ to: PORTAL, value: amount });
  console.log(`L1 tx: ${tx.hash}`);
  await tx.wait();
  console.log(`bridged 0.05 ETH to Liberty — ETH should land at ${wallet.address} on Liberty in ~3-5 min`);
})();
