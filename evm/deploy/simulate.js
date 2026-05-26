const { JsonRpcProvider, Contract, Wallet } = require("ethers");
const { HDKey } = require("@scure/bip32");
const { mnemonicToSeedSync } = require("@scure/bip39");
const fs = require("fs");

const ABI = [
  { name: "settle", type: "function", stateMutability: "nonpayable",
    inputs: [{name:"orderId",type:"uint256"},{name:"seller",type:"address"}], outputs: [] },
  { name: "getOrder", type: "function", stateMutability: "view",
    inputs: [{name:"orderId",type:"uint256"}],
    outputs: [{type:"tuple",components:[
      {name:"owner",type:"address"},{name:"token",type:"address"},
      {name:"amount",type:"uint256"},{name:"omniRecipient",type:"bytes32"},
      {name:"expiresAt",type:"uint64"},{name:"state",type:"uint8"}
    ]}]},
];

const founder = fs.readFileSync(".mnemonic", "utf8").trim();
const root = HDKey.fromMasterSeed(mnemonicToSeedSync(founder));
const operatorLeaf = root.derive("m/44'/60'/0'/0/2");
const privHex = "0x" + Buffer.from(operatorLeaf.privateKey).toString("hex");

const provider = new JsonRpcProvider("https://ethereum-sepolia-rpc.publicnode.com", 11155111);
const wallet = new Wallet(privHex, provider);
const dex = new Contract("0xC21fD92e5f568a7981d16b9008E3C190842818aE", ABI, wallet);

(async () => {
  console.log("Operator:", wallet.address);
  console.log("Operator bal:", (await provider.getBalance(wallet.address)).toString(), "wei");
  
  // Check order state
  const orderId = 1778863529431322n;
  const o = await dex.getOrder(orderId);
  console.log("\nOrder", orderId);
  console.log("  state:", o.state, "(1=open 2=settled 3=cancelled)");
  console.log("  amount:", o.amount.toString());
  console.log("  owner:", o.owner);
  
  if (o.state === 1n) {
    console.log("\nAttempting settle...");
    try {
      const tx = await dex.settle(orderId, "0x9858effd232b4033e47d90003d41ec34ecaeda94", { gasLimit: 200000 });
      console.log("tx:", tx.hash);
      const r = await tx.wait();
      console.log("✓ mined", r.blockNumber);
    } catch (e) {
      console.log("✗", e.shortMessage || e.message);
    }
  }
})();
