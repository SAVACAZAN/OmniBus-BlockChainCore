const { JsonRpcProvider, Contract } = require("ethers");
const p = new JsonRpcProvider("https://ethereum-sepolia-rpc.publicnode.com", 11155111);
const ABI = [
  { name: "OrderSettled", type: "event", inputs: [
    {name:"orderId",type:"uint256",indexed:true},
    {name:"seller",type:"address",indexed:true},
    {name:"amount",type:"uint256",indexed:false}]},
];
(async () => {
  // Wait — receipt tx
  const r = await p.getTransactionReceipt("0x6e4d86e8266f45a5608f1f7bfe030f7e4622be7ccbc905dcc3f6f5741818689b");
  console.log("status:", r.status, "block:", r.blockNumber);
  console.log("logs:", r.logs.length);
  for (const l of r.logs) {
    console.log("  topic0:", l.topics[0]);
    console.log("  topics:", l.topics);
    console.log("  data:", l.data);
  }
})();
