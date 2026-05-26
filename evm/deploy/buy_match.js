const { HDKey } = require("@scure/bip32");
const { mnemonicToSeedSync } = require("@scure/bip39");
const { secp256k1 } = require("@noble/curves/secp256k1");
const { sha256 } = require("@noble/hashes/sha256");
const fs = require("fs");

const founder = fs.readFileSync(".mnemonic", "utf8").trim();
const root = HDKey.fromMasterSeed(mnemonicToSeedSync(founder));
const leaf = root.derive("m/44'/777'/0'/0/0");
const addr = "ob1qzhrauq0xe9hg033ccup7vlgsdmj6kcxyza9zp0";

const side="buy", pairId=0, price=1000000, amount=5000000000;
const nonce=Date.now();
const msg=`EXCHANGE_ORDER_V1\n${side}\n${pairId}\n${price}\n${amount}\n${nonce}\n${addr}`;
const h=sha256(sha256(new TextEncoder().encode(msg)));
const sig=secp256k1.sign(h, leaf.privateKey, { lowS: true });
// Use the live escrow orderId
const payload = `{"trader":"${addr}","side":"${side}","pairId":${pairId},"price":${price},"amount":${amount},"nonce":${nonce},"signature":"${Buffer.from(sig.toCompactRawBytes()).toString("hex")}","publicKey":"${Buffer.from(leaf.publicKey).toString("hex")}","evmOrderId":1778885411222615}`;
console.log(payload);
