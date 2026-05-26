#!/usr/bin/env node
// Cancel all 30 active orders placed during Phase 5
import { secp256k1 } from '../frontend/node_modules/@noble/curves/secp256k1.js';
import { sha256 } from '../frontend/node_modules/@noble/hashes/sha2.js';
import { mnemonicToSeedSync } from '../frontend/node_modules/@scure/bip39/index.js';
import { HDKey } from '../frontend/node_modules/@scure/bip32/index.js';

const RPC = 'https://omnibusblockchain.cc:8443/api-testnet';
const TOKEN = '31926ece83bb8c9317ead56d60de99ed38c5d1e345055aedb0acf5db6512b8c4';
const MNEMONIC = 'abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about';
const ADDR = 'ob1qw6zhsqg29aht23fksk5w54lkgavatpgltqxlvl';

const seed = mnemonicToSeedSync(MNEMONIC);
const root = HDKey.fromMasterSeed(seed);
const node = root.derive("m/44'/777'/0'/0/0");
const priv = node.privateKey;
const pub = secp256k1.getPublicKey(priv, true);
const pubHex = Buffer.from(pub).toString('hex');

async function rpc(method, params) {
  const r = await fetch(RPC, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${TOKEN}` },
    body: JSON.stringify({ jsonrpc: '2.0', method, params, id: Date.now() }),
  });
  return r.json();
}

const userOrders = await rpc('exchange_getUserOrders', { trader: ADDR });
const orders = userOrders.result || [];
console.log(`Found ${orders.length} active orders to cancel`);

let baseNonce = Date.now() * 1000;
let ok = 0, fail = 0;
for (const o of orders) {
  const nonce = ++baseNonce;
  const msg = `EXCHANGE_CANCEL_V1\n${o.orderId}\n${nonce}\n${ADDR}`;
  const hash = sha256(Buffer.from(msg, 'utf8'));
  const sig = secp256k1.sign(hash, priv, { lowS: true });
  const sigHex = sig instanceof Uint8Array
    ? Buffer.from(sig).toString('hex')
    : Buffer.from(sig.toCompactRawBytes()).toString('hex');
  const r = await rpc('exchange_cancelOrder', {
    trader: ADDR, orderId: o.orderId, nonce,
    signature: sigHex, publicKey: pubHex,
  });
  if (r.error) { console.log(`  ${o.orderId} FAIL: ${r.error.message}`); fail++; }
  else { console.log(`  ${o.orderId} OK`); ok++; }
  await new Promise(r => setTimeout(r, 80));
}
console.log(`cleanup: ok=${ok} fail=${fail}`);
