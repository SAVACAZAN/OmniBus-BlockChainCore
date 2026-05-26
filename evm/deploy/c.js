const { HDKey } = require("@scure/bip32");
const { mnemonicToSeedSync } = require("@scure/bip39");
const { JsonRpcProvider, Wallet, formatEther } = require("ethers");

const dev = "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about";
const root = HDKey.fromMasterSeed(mnemonicToSeedSync(dev));
const provider = new JsonRpcProvider("https://ethereum-sepolia-rpc.publicnode.com", 11155111);

(async () => {
  for (let i = 0; i < 4; i++) {
    const leaf = root.derive(`m/44'/60'/0'/0/${i}`);
    const w = new Wallet("0x"+Buffer.from(leaf.privateKey).toString("hex"));
    const code = await provider.send("eth_getCode", [w.address, "latest"]);
    const bal = await provider.getBalance(w.address);
    console.log(`slot ${i}: ${w.address}  bal=${formatEther(bal)} ETH  code_len=${code.length}`);
  }
})();
