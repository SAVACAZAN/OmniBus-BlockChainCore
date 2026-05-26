const { JsonRpcProvider, Contract, formatEther } = require("ethers");
const p = new JsonRpcProvider("https://sepolia.base.org", 84532);
const TX = "0x202970571bd5398fa0b9fb0fa6b6a2a277dedacb2c52bf884d58c4ad8ab73afb";
const DEX = "0xAEE1B7dC7a010b6C6D6097BD7d9dDf227aF719EB";
const ORDER_ID = 1778887231368406n;
const SELLER = "0x9858effd232b4033e47d90003d41ec34ecaeda94";
const abi = [{
  name:"getOrder", type:"function", stateMutability:"view",
  inputs:[{name:"orderId",type:"uint256"}],
  outputs:[{type:"tuple",components:[
    {name:"owner",type:"address"},{name:"token",type:"address"},
    {name:"amount",type:"uint256"},{name:"omniRecipient",type:"bytes32"},
    {name:"expiresAt",type:"uint64"},{name:"state",type:"uint8"}
  ]}]
}];
const STATES = {0:"NONE",1:"OPEN",2:"SETTLED",3:"CANCELLED",4:"EXPIRED"};
(async () => {
  const r = await p.getTransactionReceipt(TX);
  console.log("tx status:", r ? (r.status === 1 ? "SUCCESS" : "FAIL") : "PENDING");
  if (r) console.log("  block:", r.blockNumber, "gas:", r.gasUsed.toString());
  const dex = new Contract(DEX, abi, p);
  const o = await dex.getOrder(ORDER_ID);
  console.log(`escrow state: ${o.state} (${STATES[Number(o.state)] || "?"})`);
  console.log(`seller ETH:  ${formatEther(await p.getBalance(SELLER))} ETH`);
  console.log(`DEX    ETH:  ${formatEther(await p.getBalance(DEX))} ETH`);
})();
