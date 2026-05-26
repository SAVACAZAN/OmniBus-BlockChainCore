const { JsonRpcProvider, Contract, formatEther } = require("ethers");
const p = new JsonRpcProvider("https://ethereum-sepolia-rpc.publicnode.com", 11155111);
const TX = "0xa92b1cab3bd741e8564df3c2fb6088b17130c7a1fd5bda91f83600b56e977f37";
const DEX = "0xC21fD92e5f568a7981d16b9008E3C190842818aE";
const SELLER = "0x9858effd232b4033e47d90003d41ec34ecaeda94";
const BUYER = "0x58096A6921774938760a4b00062B92983c1Ca8C7";
const ORDER_ID = 1778886244196820n;
const orderAbi = [{
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
  const dex = new Contract(DEX, orderAbi, p);
  const o = await dex.getOrder(ORDER_ID);
  console.log(`escrow state: ${o.state} (${STATES[Number(o.state)] || "?"})`);
  console.log(`seller ETH:  ${formatEther(await p.getBalance(SELLER))} ETH`);
  console.log(`buyer  ETH:  ${formatEther(await p.getBalance(BUYER))} ETH`);
  console.log(`DEX    ETH:  ${formatEther(await p.getBalance(DEX))} ETH`);
})();
