const { HDKey } = require("@scure/bip32");
const { mnemonicToSeedSync } = require("@scure/bip39");
const { Wallet, JsonRpcProvider, parseEther, formatEther } = require("ethers");
const fs = require("fs");

const m = fs.readFileSync(".mnemonic", "utf8").trim();
const root = HDKey.fromMasterSeed(mnemonicToSeedSync(m));
const slot6 = root.derive("m/44'/60'/0'/0/6");
const provider = new JsonRpcProvider("https://sepolia.base.org", 84532);
const deployer = new Wallet("0x" + Buffer.from(slot6.privateKey).toString("hex"), provider);
const FOUNDER = "0x58096A6921774938760a4b00062B92983c1Ca8C7"; // slot 0

(async () => {
  const tx = await deployer.sendTransaction({ to: FOUNDER, value: parseEther("0.01") });
  console.log(`fund tx: ${tx.hash}`);
  await tx.wait();
  console.log(`founder Base ETH: ${formatEther(await provider.getBalance(FOUNDER))} ETH`);
})();
