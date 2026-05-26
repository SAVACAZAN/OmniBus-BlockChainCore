const { JsonRpcProvider, Contract } = require("ethers");
const abi = [{name:"getOrder", type:"function", stateMutability:"view",
  inputs:[{name:"orderId",type:"uint256"}],
  outputs:[{type:"tuple",components:[
    {name:"owner",type:"address"},{name:"token",type:"address"},
    {name:"amount",type:"uint256"},{name:"omniRecipient",type:"bytes32"},
    {name:"expiresAt",type:"uint64"},{name:"state",type:"uint8"}]}]}];
const STATES = {0:"NONE",1:"OPEN",2:"SETTLED",3:"CANCELLED",4:"EXPIRED"};
(async () => {
  const p = new JsonRpcProvider("https://sepolia.base.org");
  const c = new Contract("0xAEE1B7dC7a010b6C6D6097BD7d9dDf227aF719EB", abi, p);
  for (const id of [1778888573960547n, 1778935851833956n]) {
    const o = await c.getOrder(id);
    console.log(`Base orderId=${id}: state=${o.state} (${STATES[Number(o.state)]||"?"}) token=${o.token}`);
  }
})();
