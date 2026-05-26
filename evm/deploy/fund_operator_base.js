// Fund the slot-2 operator on Base Sepolia with 0.01 ETH so dex_settler
// can call settle() on the newly deployed OmnibusDEX (Base Sepolia chain).
const { HDKey } = require("@scure/bip32");
const { mnemonicToSeedSync } = require("@scure/bip39");
const { Wallet, JsonRpcProvider, parseEther, formatEther } = require("ethers");
const fs = require("fs");

const m = fs.readFileSync(".mnemonic", "utf8").trim();
const root = HDKey.fromMasterSeed(mnemonicToSeedSync(m));
// Slot 6 (tornetwork.omnibus) — deployer has the ETH on Base.
const leaf = root.derive("m/44'/60'/0'/0/6");
const provider = new JsonRpcProvider("https://sepolia.base.org", 84532);
const deployer = new Wallet("0x" + Buffer.from(leaf.privateKey).toString("hex"), provider);
const OPERATOR = "0xA66235662c363e9915b6353f79df309F67D146A6"; // slot 2 exchange.omnibus

(async () => {
  const bal = await provider.getBalance(deployer.address);
  console.log(`deployer ${deployer.address} balance: ${formatEther(bal)} ETH`);
  const opBal = await provider.getBalance(OPERATOR);
  console.log(`operator ${OPERATOR} balance: ${formatEther(opBal)} ETH`);
  if (opBal >= parseEther("0.005")) {
    console.log("operator already funded, skip");
    return;
  }
  const tx = await deployer.sendTransaction({ to: OPERATOR, value: parseEther("0.01") });
  console.log(`fund tx: ${tx.hash}`);
  await tx.wait();
  console.log(`done — operator now: ${formatEther(await provider.getBalance(OPERATOR))} ETH`);
})();
