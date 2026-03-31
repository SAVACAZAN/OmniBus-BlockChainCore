#!/usr/bin/env node
/**
 * OmniBus Wallet Generator
 * Creates OMNI wallets with BIP-39 mnemonic + deterministic addresses
 * Generates addresses for miners to receive block rewards
 */

const crypto = require("crypto");
const fs = require("fs");
const path = require("path");

// BIP-39 word list (simplified - using 2048 common words)
const BIP39_WORDLIST = [
  "abandon", "ability", "able", "about", "above", "absent", "absorb", "abstract",
  "abuse", "access", "accident", "account", "accuse", "achieve", "acid", "acoustic",
  // In real implementation, this would be all 2048 words
  // For now, using a smaller set for demo
  ...generateDemoWords()
];

function generateDemoWords() {
  const words = [];
  for (let i = 0; i < 2000; i++) {
    words.push(`word${i}`);
  }
  return words;
}

// Generate random mnemonic (12 words = 128 bits entropy)
function generateMnemonic() {
  const entropyBytes = crypto.randomBytes(16); // 128 bits
  const words = [];

  // Convert entropy to indices in BIP39 word list
  let bitstring = "";
  for (let i = 0; i < entropyBytes.length; i++) {
    bitstring += entropyBytes[i].toString(2).padStart(8, "0");
  }

  // Calculate checksum (first 4 bits of SHA256 hash)
  const hash = crypto.createHash("sha256").update(entropyBytes).digest();
  const checksumBits = hash[0].toString(2).padStart(8, "0").substring(0, 4);
  bitstring += checksumBits;

  // Convert 11-bit chunks to word indices
  for (let i = 0; i < bitstring.length; i += 11) {
    const chunk = bitstring.substring(i, i + 11);
    const index = parseInt(chunk, 2);
    words.push(BIP39_WORDLIST[index % BIP39_WORDLIST.length]);
  }

  return words.slice(0, 12).join(" ");
}

// Derive address from seed (simplified PBKDF2-based derivation)
function deriveAddress(mnemonic, accountIndex = 0) {
  // PBKDF2: Convert mnemonic to seed
  const salt = Buffer.from("TREZOR", "utf8");
  const seed = crypto.pbkdf2Sync(mnemonic, salt, 2048, 64, "sha512");

  // Derive path: m/44'/60'/0'/0/{accountIndex}
  // (Using simplified derivation - full BIP-32 would be more complex)
  const derivedKey = crypto.createHmac("sha256", seed).update(Buffer.from(`${accountIndex}`)).digest();

  // Generate OMNI address with prefix
  const addressHash = crypto.createHash("sha256").update(derivedKey).digest();
  const addressPart = addressHash.toString("hex").substring(0, 32);

  return {
    omniAddress: `ob_omni_${addressPart}`,
    publicKey: derivedKey.toString("hex").substring(0, 64),
    derivationPath: `m/44'/60'/0'/0/${accountIndex}`,
  };
}

// Create wallet with N addresses (for multi-sig or multiple accounts)
function createWallet(walletName = "default", addressCount = 1) {
  const mnemonic = generateMnemonic();
  const wallet = {
    name: walletName,
    type: "OmniBus",
    version: "1.0",
    createdAt: new Date().toISOString(),
    mnemonic: mnemonic,
    addresses: [],
  };

  // Derive N addresses from the mnemonic
  for (let i = 0; i < addressCount; i++) {
    const derived = deriveAddress(mnemonic, i);
    wallet.addresses.push({
      index: i,
      ...derived,
      balance: 0,
      balanceOmni: 0,
      blocksMined: 0,
    });
  }

  return wallet;
}

// Save wallet to JSON
function saveWallet(wallet, filename = null) {
  if (!filename) {
    filename = `wallet_${wallet.name}_${Date.now()}.json`;
  }

  const filepath = path.join("./wallets", filename);

  // Create wallets dir if needed
  if (!fs.existsSync("./wallets")) {
    fs.mkdirSync("./wallets", { recursive: true });
  }

  fs.writeFileSync(filepath, JSON.stringify(wallet, null, 2));
  return filepath;
}

// CLI
function main() {
  const args = process.argv.slice(2);
  const command = args[0] || "create";
  const walletName = args[1] || "omnibus";
  const addressCount = parseInt(args[2]) || 1;

  console.log("");
  console.log("╔════════════════════════════════════════════════════════════╗");
  console.log("║         OmniBus Wallet Generator - BIP-39                  ║");
  console.log("║              Deterministic Address Derivation              ║");
  console.log("╚════════════════════════════════════════════════════════════╝");
  console.log("");

  if (command === "create" || command === "gen") {
    console.log(`[WALLET] Generating ${walletName} wallet...`);
    const wallet = createWallet(walletName, addressCount);

    console.log("");
    console.log(`[WALLET] ✓ Wallet Created!`);
    console.log(`[WALLET] Wallet Name: ${wallet.name}`);
    console.log(`[WALLET] Created: ${wallet.createdAt}`);
    console.log("");
    console.log(`[WALLET] ⚠️  MNEMONIC PHRASE (KEEP SECURE):`);
    console.log(`         ${wallet.mnemonic}`);
    console.log("");
    console.log(`[WALLET] Derived Addresses:`);
    wallet.addresses.forEach((addr, idx) => {
      console.log(`         Address #${idx}: ${addr.omniAddress}`);
      console.log(`         Path: ${addr.derivationPath}`);
      console.log(`         Public Key: ${addr.publicKey.substring(0, 32)}...`);
      console.log("");
    });

    const savedPath = saveWallet(wallet, `${walletName}.json`);
    console.log(`[WALLET] ✓ Saved to: ${savedPath}`);
    console.log("");

    // Also export just the addresses for miners
    const minerAddresses = wallet.addresses.map((addr) => ({
      minerName: walletName,
      address: addr.omniAddress,
      publicKey: addr.publicKey,
      derivationPath: addr.derivationPath,
    }));

    const minerConfigPath = path.join("./wallets", `${walletName}_addresses.json`);
    fs.writeFileSync(minerConfigPath, JSON.stringify(minerAddresses, null, 2));
    console.log(`[WALLET] ✓ Miner config: ${minerConfigPath}`);
    console.log("");

  } else if (command === "batch") {
    // Batch create wallets for N miners
    const minerCount = parseInt(args[1]) || 10;
    console.log(`[WALLET] Batch creating ${minerCount} miner wallets...`);
    console.log("");

    const batchWallets = [];

    for (let i = 0; i < minerCount; i++) {
      const minerName = `miner-${i}`;
      const wallet = createWallet(minerName, 1);
      batchWallets.push({
        minerName: minerName,
        mnemonic: wallet.mnemonic,
        address: wallet.addresses[0].omniAddress,
        publicKey: wallet.addresses[0].publicKey,
      });

      if ((i + 1) % 5 === 0 || i === minerCount - 1) {
        console.log(`[WALLET] Created ${i + 1}/${minerCount} wallets...`);
      }
    }

    const batchPath = path.join("./wallets", `genesis_miners_${minerCount}.json`);
    fs.writeFileSync(batchPath, JSON.stringify(batchWallets, null, 2));

    console.log("");
    console.log(`[WALLET] ✓ Batch file saved: ${batchPath}`);
    console.log(`[WALLET] Total wallets: ${batchWallets.length}`);
    console.log("");
    console.log(`[WALLET] Sample miner wallet:`);
    const sample = batchWallets[0];
    console.log(`         Name: ${sample.minerName}`);
    console.log(`         Address: ${sample.address}`);
    console.log(`         Mnemonic: ${sample.mnemonic}`);
    console.log("");

  } else {
    console.log("Usage:");
    console.log("  node create-wallet.js [command] [args]");
    console.log("");
    console.log("Commands:");
    console.log("  create [name] [count]    - Create wallet with N addresses");
    console.log("  batch [count]            - Batch create N miner wallets");
    console.log("");
    console.log("Examples:");
    console.log("  node create-wallet.js create mypool 5");
    console.log("  node create-wallet.js batch 10");
    console.log("  node create-wallet.js batch 100");
    console.log("");
  }
}

main();
