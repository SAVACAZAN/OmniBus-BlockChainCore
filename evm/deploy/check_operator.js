const { JsonRpcProvider, Contract } = require("ethers");
const p = new JsonRpcProvider("https://ethereum-sepolia-rpc.publicnode.com", 11155111);
const abi = [
  "function operator() view returns (address)",
  "function owner() view returns (address)"
];
const dex = new Contract("0xC21fD92e5f568a7981d16b9008E3C190842818aE", abi, p);
(async () => {
  try { console.log("operator:", await dex.operator()); } catch(e){console.log("no operator()");}
  try { console.log("owner:", await dex.owner()); } catch(e){console.log("no owner()");}
})();
