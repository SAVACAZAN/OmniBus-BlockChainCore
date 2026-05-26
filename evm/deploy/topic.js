const { keccak256, toUtf8Bytes } = require("ethers");
console.log("OrderPlaced topic:", keccak256(toUtf8Bytes("OrderPlaced(uint256,address,address,uint256,bytes32,uint64)")));
console.log("OrderSettled topic:", keccak256(toUtf8Bytes("OrderSettled(uint256,address,uint256)")));
console.log("OrderCancelled topic:", keccak256(toUtf8Bytes("OrderCancelled(uint256,address,uint256)")));
