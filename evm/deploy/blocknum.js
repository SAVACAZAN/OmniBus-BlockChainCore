const { JsonRpcProvider } = require("ethers");
const p = new JsonRpcProvider("https://ethereum-sepolia-rpc.publicnode.com", 11155111);
(async () => {
  const tx = await p.getTransactionReceipt("0x73f91be0f91d6c7e10881efc6144f6594379b5fb2e899f213edab9310e0b8765");
  console.log("tx block:", tx?.blockNumber, "= 0x"+tx?.blockNumber.toString(16));
  const head = await p.getBlockNumber();
  console.log("head:", head, "= 0x"+head.toString(16));
  console.log("diff:", head - (tx?.blockNumber ?? 0));
})();
