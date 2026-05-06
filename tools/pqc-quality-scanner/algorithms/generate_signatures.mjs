#!/usr/bin/env node
/**
 * generate_signatures.mjs — produce N PQ signatures per algorithm,
 * write to <algo>_signatures.bin (concatenated raw bytes) and
 * <algo>_avalanche.bin (sig_a || sig_b pairs where input differs by 1 bit).
 *
 * Run from frontend/ folder so it can resolve @noble/post-quantum:
 *   node ../tools/pqc-quality-scanner/algorithms/generate_signatures.mjs \
 *        --out ../tools/pqc-quality-scanner/reports \
 *        --count 200
 */
import { ml_dsa87 }      from "@noble/post-quantum/ml-dsa.js";
import { falcon512 }     from "@noble/post-quantum/falcon.js";
import { slh_dsa_sha2_256s } from "@noble/post-quantum/slh-dsa.js";
import { sha256, sha512 } from "@noble/hashes/sha2.js";
import { writeFileSync, mkdirSync } from "fs";
import { resolve, join } from "path";

const argv = process.argv.slice(2);
let outDir = "./reports";
let count  = 200;
for (let i = 0; i < argv.length; i++) {
  if (argv[i] === "--out")   outDir = argv[++i];
  if (argv[i] === "--count") count  = parseInt(argv[++i], 10);
}
mkdirSync(resolve(outDir), { recursive: true });

const SCHEMES = [
  { id: "ml_dsa_87",    lib: ml_dsa87,           seedLen: 32, expand: "sha256" },
  { id: "falcon_512",   lib: falcon512,          seedLen: 48, expand: "sha512" },
  { id: "dilithium_5",  lib: ml_dsa87,           seedLen: 32, expand: "sha256" },  // alias
  { id: "slh_dsa_256s", lib: slh_dsa_sha2_256s,  seedLen: 96, expand: "counter" },
];

function expandSeed(input, len, mode) {
  if (mode === "sha256") return sha256(input);
  if (mode === "sha512") return sha512(input).slice(0, len);
  // counter mode (sha512)
  const out = new Uint8Array(len);
  let off = 0, counter = 0;
  while (off < len) {
    const cb = new Uint8Array(input.length + 1);
    cb.set(input); cb[input.length] = counter++;
    const block = sha512(cb);
    const take = Math.min(block.length, len - off);
    out.set(block.slice(0, take), off);
    off += take;
  }
  return out;
}

function flipBit(bytes, bitIdx) {
  const out = new Uint8Array(bytes);
  const byteIdx = (bitIdx / 8) | 0;
  const inByte  = bitIdx % 8;
  out[byteIdx] ^= (1 << inByte);
  return out;
}

console.log(`PQC scanner — generating ${count} sigs per algorithm`);
console.log(`Output dir: ${resolve(outDir)}`);
console.log("");

for (const s of SCHEMES) {
  console.log(`─── ${s.id} ───`);

  // 1. fixed keypair (deterministic from a seed)
  const baseSeed = expandSeed(new TextEncoder().encode(`pqc-scan-${s.id}`), s.seedLen, s.expand);
  const kp = s.lib.keygen(baseSeed);
  console.log(`  keypair: pk=${kp.publicKey.length}B sk=${kp.secretKey.length}B`);

  // 2. N signatures over distinct messages → bulk entropy stream
  const sigs = [];
  for (let i = 0; i < count; i++) {
    const msg = new TextEncoder().encode(`scanner-msg-${i}`);
    sigs.push(s.lib.sign(msg, kp.secretKey));
  }
  const sigLen = sigs[0].length;
  const bulk = new Uint8Array(sigLen * count);
  sigs.forEach((sig, i) => bulk.set(sig, i * sigLen));
  writeFileSync(join(resolve(outDir), `${s.id}_signatures.bin`), Buffer.from(bulk));
  console.log(`  sigs:     ${count} × ${sigLen}B = ${bulk.length}B → ${s.id}_signatures.bin`);

  // 3. Avalanche pairs — flip 1 bit per pair, sign both, store side-by-side
  const pairs = Math.min(count, 64);  // avalanche needs fewer samples
  const baseMsg = new Uint8Array(64); for (let i = 0; i < 64; i++) baseMsg[i] = i;
  const avalanche = new Uint8Array(2 * sigLen * pairs);
  for (let i = 0; i < pairs; i++) {
    const msg_a = baseMsg;
    const msg_b = flipBit(baseMsg, i % (baseMsg.length * 8));
    const sig_a = s.lib.sign(msg_a, kp.secretKey);
    const sig_b = s.lib.sign(msg_b, kp.secretKey);
    avalanche.set(sig_a, 2 * i * sigLen);
    avalanche.set(sig_b, (2 * i + 1) * sigLen);
  }
  writeFileSync(join(resolve(outDir), `${s.id}_avalanche.bin`), Buffer.from(avalanche));
  writeFileSync(join(resolve(outDir), `${s.id}_meta.json`), JSON.stringify({
    id: s.id, count, sig_len: sigLen, pk_len: kp.publicKey.length,
    sk_len: kp.secretKey.length, avalanche_pairs: pairs,
  }, null, 2));
  console.log(`  avalanche:${pairs} pairs × 2 × ${sigLen}B → ${s.id}_avalanche.bin`);
  console.log("");
}

// Reference baselines for context
console.log("─── reference: AES-256-CTR (good baseline) ───");
import { createCipheriv, randomBytes } from "crypto";
const aesKey = randomBytes(32), aesIv = randomBytes(16);
const aesCipher = createCipheriv("aes-256-ctr", aesKey, aesIv);
const aesBytes = aesCipher.update(Buffer.alloc(64 * 1024));  // 64 KB
writeFileSync(join(resolve(outDir), "aes256ctr_signatures.bin"), aesBytes);
writeFileSync(join(resolve(outDir), "aes256ctr_meta.json"), JSON.stringify({
  id: "aes256ctr", count: 1, sig_len: aesBytes.length, note: "reference baseline",
}, null, 2));
console.log(`  ${aesBytes.length}B AES-256-CTR keystream`);
console.log("");

console.log("─── reference: XOR-weak (bad baseline) ───");
// Repeating XOR with short key — should fail entropy + periodicity
const weakKey = Buffer.from("OmniBus-Test-Weak-XOR-Key-32B!!!", "utf-8");
const weakInput = Buffer.alloc(64 * 1024, 0x55);
const weakOut = Buffer.alloc(weakInput.length);
for (let i = 0; i < weakInput.length; i++) weakOut[i] = weakInput[i] ^ weakKey[i % weakKey.length];
writeFileSync(join(resolve(outDir), "xor_weak_signatures.bin"), weakOut);
writeFileSync(join(resolve(outDir), "xor_weak_meta.json"), JSON.stringify({
  id: "xor_weak", count: 1, sig_len: weakOut.length, note: "reference (weak) baseline",
}, null, 2));
console.log(`  ${weakOut.length}B repeating XOR (intentionally weak)`);
console.log("");

console.log("✓ Generation done.");
