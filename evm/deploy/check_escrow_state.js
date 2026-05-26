const { JsonRpcProvider, Contract } = require("ethers");
const p = new JsonRpcProvider("https://ethereum-sepolia-rpc.publicnode.com", 11155111);
const abi = [{
  name: "getOrder", type: "function", stateMutability: "view",
  inputs: [{name:"orderId",type:"uint256"}],
  outputs: [{type:"tuple",components:[
    {name:"owner",type:"address"},{name:"token",type:"address"},
    {name:"amount",type:"uint256"},{name:"omniRecipient",type:"bytes32"},
    {name:"expiresAt",type:"uint64"},{name:"state",type:"uint8"}
  ]}]
}];
const dex = new Contract("0xC21fD92e5f568a7981d16b9008E3C190842818aE", abi, p);
const ORDER_ID = 1778864423854121n;
const STATES = {0:"NONE",1:"OPEN",2:"SETTLED",3:"CANCELLED",4:"EXPIRED"};
(async () => {
  const o = await dex.getOrder(ORDER_ID);
  console.log(`orderId=${ORDER_ID}`);
  console.log(`  owner=${o.owner}`);
  console.log(`  token=${o.token}`);
  console.log(`  amount=${o.amount}`);
  console.log(`  omniRecipient=${o.omniRecipient}`);
  console.log(`  expiresAt=${o.expiresAt} (${new Date(Number(o.expiresAt)*1000).toISOString()})`);
  console.log(`  state=${o.state} (${STATES[Number(o.state)] || "?"})`);
})();
