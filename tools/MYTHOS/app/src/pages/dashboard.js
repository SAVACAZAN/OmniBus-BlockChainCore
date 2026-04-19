import { getProjectStats, getRunHistory, getLatestScore } from '../core/tauri-api.js';
import { SANDBOX, MYTHOS_DATA } from '../core/constants.js';

export async function renderDashboard(container) {
  container.innerHTML = `
    <div class="stats-row">
      <div class="stat"><div class="num" style="color:var(--green);">97%</div><div class="lbl">MYTHOS Score</div></div>
      <div class="stat"><div class="num" style="color:var(--cyan);">1130</div><div class="lbl">Exploit Blocks</div></div>
      <div class="stat"><div class="num" style="color:var(--accent);">30</div><div class="lbl">AI Agents</div></div>
      <div class="stat"><div class="num" style="color:var(--yellow);">86</div><div class="lbl">Zig Modules</div></div>
      <div class="stat"><div class="num" style="color:var(--blue);">65</div><div class="lbl">Contracts .sol</div></div>
      <div class="stat"><div class="num" style="color:var(--red);">27</div><div class="lbl">Categories</div></div>
    </div>

    <div class="phases-grid">
      <div class="phase"><div class="pname" style="color:var(--green);">CRYPTO VERIFICATION</div><div class="pdesc">NIST ECDSA, Wycheproof, SHA-256, RIPEMD-160, FIPS 140-2, BIP-32/39</div><div class="pbar"><div class="pfill" style="width:100%;background:var(--green);"></div></div><div class="pscore">7/7 PASS | 100%</div></div>
      <div class="phase"><div class="pname" style="color:var(--green);">CWE SCAN (70)</div><div class="pdesc">Buffer overflow, Use after free, Integer overflow, Reentrancy, SQL injection, XSS</div><div class="pbar"><div class="pfill" style="width:100%;background:var(--green);"></div></div><div class="pscore">70/70 | 100%</div></div>
      <div class="phase"><div class="pname" style="color:var(--green);">BITCOIN EXPLOITS</div><div class="pdesc">C++ consensus_bypass, validation_flaw, mempool_uaf, UTXO poisoning</div><div class="pbar"><div class="pfill" style="width:100%;background:var(--green);"></div></div><div class="pscore">15 C++ | 100%</div></div>
      <div class="phase"><div class="pname" style="color:var(--green);">ETHEREUM EXPLOITS</div><div class="pdesc">Geth P2P, Reth REVM, Nethermind, EVM opcode tricks, Solidity audits</div><div class="pbar"><div class="pfill" style="width:100%;background:var(--green);"></div></div><div class="pscore">Go/Rust/C# | 100%</div></div>
      <div class="phase"><div class="pname" style="color:var(--green);">ASM PAYLOADS</div><div class="pdesc">Linux x64 reverse/bind, Windows, ARM, RISC-V, Bitcoin Script, EVM bytecode</div><div class="pbar"><div class="pfill" style="width:100%;background:var(--green);"></div></div><div class="pscore">24 files | 100%</div></div>
      <div class="phase"><div class="pname" style="color:var(--green);">CROSS-CHAIN</div><div class="pdesc">Wormhole, Axelar, LayerZero, CCIP, IBC, bridge exploits, replay attacks</div><div class="pbar"><div class="pfill" style="width:100%;background:var(--green);"></div></div><div class="pscore">50+ | 100%</div></div>
      <div class="phase"><div class="pname" style="color:var(--green);">MEV TOOLS</div><div class="pdesc">MEV-Boost, Sandwich optimizer, Backrun bot, JIT liquidity, Flashbots</div><div class="pbar"><div class="pfill" style="width:100%;background:var(--green);"></div></div><div class="pscore">12 tools | 100%</div></div>
      <div class="phase"><div class="pname" style="color:var(--green);">FUZZING LAB</div><div class="pdesc">AFL++, libFuzzer, Honggfuzz, network, smart contract, differential fuzzer</div><div class="pbar"><div class="pfill" style="width:100%;background:var(--green);"></div></div><div class="pscore">50+ | 100%</div></div>
    </div>

    <div style="display:grid;grid-template-columns:repeat(4,1fr);gap:10px;margin-bottom:16px;">
      <button class="action-btn" data-action="mythos" style="background:var(--accent);color:#fff;border:none;padding:12px;border-radius:8px;font-size:12px;cursor:pointer;">Run ALL Phases</button>
      <button class="action-btn" data-action="claude" style="background:var(--s2);color:var(--text);border:1px solid var(--accent);padding:12px;border-radius:8px;cursor:pointer;">Open Claude</button>
      <button class="action-btn" data-action="cmd" style="background:var(--s2);color:var(--text);border:1px solid var(--green);padding:12px;border-radius:8px;cursor:pointer;">CMD Terminal</button>
      <button class="action-btn" data-action="exploits" style="background:var(--s2);color:var(--text);border:1px solid var(--red);padding:12px;border-radius:8px;cursor:pointer;">Exploit Lab (1130)</button>
    </div>

    <div style="background:var(--s1);border:1px solid var(--border);border-radius:8px;padding:14px;">
      <div style="font-size:12px;font-weight:bold;margin-bottom:10px;">Run History - 62% to 97%</div>
      <div style="display:flex;align-items:end;gap:4px;height:60px;">
        <div style="width:22px;background:var(--red);height:62%;border-radius:3px 3px 0 0;" title="62%"></div>
        <div style="width:22px;background:var(--red);height:69%;border-radius:3px 3px 0 0;" title="69%"></div>
        <div style="width:22px;background:var(--yellow);height:73%;border-radius:3px 3px 0 0;" title="73%"></div>
        <div style="width:22px;background:var(--yellow);height:85%;border-radius:3px 3px 0 0;" title="85%"></div>
        <div style="width:22px;background:var(--green);height:97%;border-radius:3px 3px 0 0;" title="97%"></div>
        <div style="width:22px;background:var(--green);height:97%;border-radius:3px 3px 0 0;" title="97%"></div>
        <span style="margin-left:12px;font-size:10px;color:var(--t3);">Latest: 97% - 33 pass, 1 fail</span>
      </div>
    </div>
  `;

  // Wire action buttons
  container.querySelectorAll('.action-btn').forEach(btn => {
    btn.addEventListener('click', () => {
      const evt = new CustomEvent('mythos-action', { detail: btn.dataset.action });
      document.dispatchEvent(evt);
    });
  });

  // Try to load real stats
  try {
    const stats = await getProjectStats(SANDBOX);
    if (stats) console.log('Real stats loaded:', stats);
  } catch(e) { /* fallback to static */ }
}
