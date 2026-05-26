const { JsonRpcProvider, Contract } = require("ethers");
const abi = [{name:"getOrder", type:"function", stateMutability:"view",
  inputs:[{name:"orderId",type:"uint256"}],
  outputs:[{type:"tuple",components:[
    {name:"owner",type:"address"},{name:"token",type:"address"},
    {name:"amount",type:"uint256"},{name:"omniRecipient",type:"bytes32"},
    {name:"expiresAt",type:"uint64"},{name:"state",type:"uint8"}]}]}];
const ID = 1778888573960547n;
const STATES = {0:"NONE",1:"OPEN",2:"SETTLED",3:"CANCELLED",4:"EXPIRED"};
(async () => {
  for (const [name, rpc, dex] of [
    ["Sepolia", "https://ethereum-sepolia-rpc.publicnode.com", "0xC21fD92e5f568a7981d16b9008E3C190842818aE"],
    ["Base Sep", "https://sepolia.base.org", "0xAEE1B7dC7a010b6C6D6097BD7d9dDf227aF719EB"],
  ]) {
    const p = new JsonRpcProvider(rpc);
    const c = new Contract(dex, abi, p);
    try {
      const o = await c.getOrder(ID);
      console.log(`${name}: state=${o.state} (${STATES[Number(o.state)]||"?"}) token=${o.token} amount=${o.amount}`);
    } catch (e) { console.log(`${name}: err ${e.code||e.message}`); }
  }
})();
