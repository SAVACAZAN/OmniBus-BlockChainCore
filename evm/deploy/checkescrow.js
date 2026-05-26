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
// Use the buy_order_id from fill #10 - likely matching the OMNI order id
(async () => {
  // Check matching engine order id 5 (the BUY order from previous logs)
  for (const id of [5, 6, 7, 8, 9, 10]) {
    try {
      const o = await dex.getOrder(id);
      if (o.state > 0) {
        console.log(`order ${id}: state=${o.state} amount=${o.amount} token=${o.token}`);
      }
    } catch (e) { /* skip */ }
  }
  console.log("done — empty = no orders ever placed on EVM contract");
})();
