/*
 @licstart  The following is the entire license notice for the JavaScript code in this file.

 The MIT License (MIT)

 Copyright (C) 1997-2020 by Dimitri van Heesch

 Permission is hereby granted, free of charge, to any person obtaining a copy of this software
 and associated documentation files (the "Software"), to deal in the Software without restriction,
 including without limitation the rights to use, copy, modify, merge, publish, distribute,
 sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is
 furnished to do so, subject to the following conditions:

 The above copyright notice and this permission notice shall be included in all copies or
 substantial portions of the Software.

 THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING
 BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
 NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM,
 DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
 OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.

 @licend  The above is the entire license notice for the JavaScript code in this file
*/
var NAVTREE =
[
  [ "SAVACAZAN", "index.html", [
    [ "Bitcoin-style Storage Refactor — Architecture Spec", "md__a_r_c_h___b_i_t_c_o_i_n___s_t_o_r_a_g_e.html", [
      [ "What Bitcoin actually does", "md__a_r_c_h___b_i_t_c_o_i_n___s_t_o_r_a_g_e.html#autotoc_md1", null ],
      [ "What we have today (the broken design)", "md__a_r_c_h___b_i_t_c_o_i_n___s_t_o_r_a_g_e.html#autotoc_md2", null ],
      [ "What we move to (Bitcoin-style, OmniBus-tuned)", "md__a_r_c_h___b_i_t_c_o_i_n___s_t_o_r_a_g_e.html#autotoc_md3", null ],
      [ "Component sizes (estimated)", "md__a_r_c_h___b_i_t_c_o_i_n___s_t_o_r_a_g_e.html#autotoc_md4", null ],
      [ "Migration strategy", "md__a_r_c_h___b_i_t_c_o_i_n___s_t_o_r_a_g_e.html#autotoc_md5", null ],
      [ "Crash-safety contract (target)", "md__a_r_c_h___b_i_t_c_o_i_n___s_t_o_r_a_g_e.html#autotoc_md6", null ],
      [ "What stays the same", "md__a_r_c_h___b_i_t_c_o_i_n___s_t_o_r_a_g_e.html#autotoc_md7", null ],
      [ "Stretch goals (post-MVP)", "md__a_r_c_h___b_i_t_c_o_i_n___s_t_o_r_a_g_e.html#autotoc_md8", null ],
      [ "Open questions to resolve before coding", "md__a_r_c_h___b_i_t_c_o_i_n___s_t_o_r_a_g_e.html#autotoc_md9", null ],
      [ "Branch layout", "md__a_r_c_h___b_i_t_c_o_i_n___s_t_o_r_a_g_e.html#autotoc_md10", null ],
      [ "Why this matters", "md__a_r_c_h___b_i_t_c_o_i_n___s_t_o_r_a_g_e.html#autotoc_md11", null ]
    ] ],
    [ "Architectural fix: every state change MUST be a chain TX", "md__a_r_c_h___f_i_x___t_x___o_n_l_y.html", [
      [ "The bug we just hit (2026-04-28)", "md__a_r_c_h___f_i_x___t_x___o_n_l_y.html#autotoc_md13", null ],
      [ "The rule", "md__a_r_c_h___f_i_x___t_x___o_n_l_y.html#autotoc_md14", null ],
      [ "What needs to become TX-on-chain", "md__a_r_c_h___f_i_x___t_x___o_n_l_y.html#autotoc_md15", null ],
      [ "What stays in memory (legitimately)", "md__a_r_c_h___f_i_x___t_x___o_n_l_y.html#autotoc_md16", null ],
      [ "Migration plan (separate dedicated session)", "md__a_r_c_h___f_i_x___t_x___o_n_l_y.html#autotoc_md17", [
        [ "Phase 1 — Faucet TX-ification (~3–4 h)", "md__a_r_c_h___f_i_x___t_x___o_n_l_y.html#autotoc_md18", null ],
        [ "Phase 2 — Reputation TX-ification (~4–6 h)", "md__a_r_c_h___f_i_x___t_x___o_n_l_y.html#autotoc_md19", null ],
        [ "Phase 3 — Agent TX-ification (~3 h)", "md__a_r_c_h___f_i_x___t_x___o_n_l_y.html#autotoc_md20", null ],
        [ "Phase 4 — Exchange match settlement (~5–8 h)", "md__a_r_c_h___f_i_x___t_x___o_n_l_y.html#autotoc_md21", null ],
        [ "Phase 5 — Audit + tooling (~2 h)", "md__a_r_c_h___f_i_x___t_x___o_n_l_y.html#autotoc_md22", null ]
      ] ],
      [ "Acceptance criteria", "md__a_r_c_h___f_i_x___t_x___o_n_l_y.html#autotoc_md23", null ],
      [ "What we do today (interim)", "md__a_r_c_h___f_i_x___t_x___o_n_l_y.html#autotoc_md24", null ]
    ] ],
    [ "Changelog", "md__c_h_a_n_g_e_l_o_g.html", [
      [ "[v0.3.2] - 2026-04-25 (later same day)", "md__c_h_a_n_g_e_l_o_g.html#autotoc_md26", [
        [ "Fixed — DB path wiring + chain selection (was incomplete in v0.3.0)", "md__c_h_a_n_g_e_l_o_g.html#autotoc_md27", null ],
        [ "Verified live", "md__c_h_a_n_g_e_l_o_g.html#autotoc_md28", null ],
        [ "Added — 7 missing standard Bitcoin RPC methods", "md__c_h_a_n_g_e_l_o_g.html#autotoc_md29", null ],
        [ "Test infrastructure", "md__c_h_a_n_g_e_l_o_g.html#autotoc_md30", null ],
        [ "DB safety trail", "md__c_h_a_n_g_e_l_o_g.html#autotoc_md31", null ]
      ] ],
      [ "[v0.3.0] - 2026-04-25", "md__c_h_a_n_g_e_l_o_g.html#autotoc_md32", [
        [ "Added — Multi-chain Selection (Mainnet / Testnet / Regtest)", "md__c_h_a_n_g_e_l_o_g.html#autotoc_md33", null ],
        [ "Compatibility", "md__c_h_a_n_g_e_l_o_g.html#autotoc_md34", null ],
        [ "Verified", "md__c_h_a_n_g_e_l_o_g.html#autotoc_md35", null ],
        [ "Known Issues", "md__c_h_a_n_g_e_l_o_g.html#autotoc_md36", null ],
        [ "Co-Authors", "md__c_h_a_n_g_e_l_o_g.html#autotoc_md37", null ]
      ] ],
      [ "[v0.2.0] - 2026-03-31", "md__c_h_a_n_g_e_l_o_g.html#autotoc_md38", [
        [ "Added — Bech32 Addresses + Full BTC Parity (115%)", "md__c_h_a_n_g_e_l_o_g.html#autotoc_md39", null ],
        [ "Changed", "md__c_h_a_n_g_e_l_o_g.html#autotoc_md40", null ]
      ] ],
      [ "[v0.1.0] - 2026-03-30", "md__c_h_a_n_g_e_l_o_g.html#autotoc_md42", [
        [ "Added", "md__c_h_a_n_g_e_l_o_g.html#autotoc_md43", null ]
      ] ]
    ] ],
    [ "CLAUDE.md", "md__c_l_a_u_d_e.html", [
      [ "Build &amp; Run", "md__c_l_a_u_d_e.html#autotoc_md45", null ],
      [ "Testing", "md__c_l_a_u_d_e.html#autotoc_md46", null ],
      [ "Architecture", "md__c_l_a_u_d_e.html#autotoc_md47", [
        [ "Node Startup (core/main.zig)", "md__c_l_a_u_d_e.html#autotoc_md48", null ],
        [ "Core Layers", "md__c_l_a_u_d_e.html#autotoc_md49", null ],
        [ "Frontend (frontend/)", "md__c_l_a_u_d_e.html#autotoc_md50", null ],
        [ "Each core/*.zig file is self-contained", "md__c_l_a_u_d_e.html#autotoc_md51", null ]
      ] ],
      [ "Key Parameters", "md__c_l_a_u_d_e.html#autotoc_md52", null ],
      [ "Git Workflow", "md__c_l_a_u_d_e.html#autotoc_md53", null ],
      [ "Ecosystem Context", "md__c_l_a_u_d_e.html#autotoc_md54", null ]
    ] ],
    [ "Prompt for Kimi — alternative architectures for OmniBus block-rate problem", "md__k_i_m_i___p_r_o_m_p_t.html", [
      [ "CONTEXT", "md__k_i_m_i___p_r_o_m_p_t.html#autotoc_md57", [
        [ "Architecture (current, working)", "md__k_i_m_i___p_r_o_m_p_t.html#autotoc_md58", null ],
        [ "Cryptographic stack", "md__k_i_m_i___p_r_o_m_p_t.html#autotoc_md59", null ],
        [ "Performance, measured", "md__k_i_m_i___p_r_o_m_p_t.html#autotoc_md60", null ],
        [ "Recent commit history (newest first)", "md__k_i_m_i___p_r_o_m_p_t.html#autotoc_md61", null ],
        [ "Best ever observed (and lost)", "md__k_i_m_i___p_r_o_m_p_t.html#autotoc_md62", null ],
        [ "Best vs worst observed in a single run", "md__k_i_m_i___p_r_o_m_p_t.html#autotoc_md63", null ],
        [ "Persistent problem", "md__k_i_m_i___p_r_o_m_p_t.html#autotoc_md64", null ],
        [ "What I want from you", "md__k_i_m_i___p_r_o_m_p_t.html#autotoc_md65", null ]
      ] ]
    ] ],
    [ "Prompt for Kimi — Switch OmniBus L1 from RAM-cached balances to UTXO source-of-truth", "md__k_i_m_i___p_r_o_m_p_t___u_t_x_o.html", [
      [ "ROLE", "md__k_i_m_i___p_r_o_m_p_t___u_t_x_o.html#autotoc_md68", null ],
      [ "EXISTING CODE (relevant snippets)", "md__k_i_m_i___p_r_o_m_p_t___u_t_x_o.html#autotoc_md69", [
        [ "<span class=\"tt\">core/blockchain.zig</span> (excerpts)", "md__k_i_m_i___p_r_o_m_p_t___u_t_x_o.html#autotoc_md70", null ],
        [ "<span class=\"tt\">core/utxo.zig</span> (excerpts — already implemented, currently", "md__k_i_m_i___p_r_o_m_p_t___u_t_x_o.html#autotoc_md71", null ],
        [ "Where UTXO is currently populated (line numbers approximate)", "md__k_i_m_i___p_r_o_m_p_t___u_t_x_o.html#autotoc_md72", null ]
      ] ],
      [ "THE BUG WE'RE FIXING", "md__k_i_m_i___p_r_o_m_p_t___u_t_x_o.html#autotoc_md73", null ],
      [ "OMNIBUS-SPECIFIC CONSTRAINTS", "md__k_i_m_i___p_r_o_m_p_t___u_t_x_o.html#autotoc_md74", null ],
      [ "PHASE B — DELIVERABLE", "md__k_i_m_i___p_r_o_m_p_t___u_t_x_o.html#autotoc_md75", [
        [ "B.1 — Make <span class=\"tt\">applyBlock</span> spend the inputs", "md__k_i_m_i___p_r_o_m_p_t___u_t_x_o.html#autotoc_md76", null ],
        [ "B.2 — Switch <span class=\"tt\">getAddressBalance</span> to UTXO source", "md__k_i_m_i___p_r_o_m_p_t___u_t_x_o.html#autotoc_md77", null ],
        [ "B.3 — Audit assertion", "md__k_i_m_i___p_r_o_m_p_t___u_t_x_o.html#autotoc_md78", null ],
        [ "B.4 — Tests", "md__k_i_m_i___p_r_o_m_p_t___u_t_x_o.html#autotoc_md79", null ],
        [ "B.5 — RPC propagation", "md__k_i_m_i___p_r_o_m_p_t___u_t_x_o.html#autotoc_md80", null ]
      ] ],
      [ "PHASE C — DESIGN ONLY", "md__k_i_m_i___p_r_o_m_p_t___u_t_x_o.html#autotoc_md81", null ],
      [ "DELIVERABLES (what you give back)", "md__k_i_m_i___p_r_o_m_p_t___u_t_x_o.html#autotoc_md82", null ],
      [ "GROUND RULES", "md__k_i_m_i___p_r_o_m_p_t___u_t_x_o.html#autotoc_md83", null ]
    ] ],
    [ "Next Session Plan — Slot Calendar + SPARK Sub-Block Consensus", "md__n_e_x_t___s_e_s_s_i_o_n___p_l_a_n.html", [
      [ "Pentru sesiunea următoare", "md__n_e_x_t___s_e_s_s_i_o_n___p_l_a_n.html#autotoc_md86", [
        [ "1. Pre-Computed Slot Calendar (Solana PoH-style)", "md__n_e_x_t___s_e_s_s_i_o_n___p_l_a_n.html#autotoc_md87", null ],
        [ "2. SPARK Sub-Block Consensus (viziunea ta)", "md__n_e_x_t___s_e_s_s_i_o_n___p_l_a_n.html#autotoc_md88", null ],
        [ "3. Detalii tehnice per platform pentru clock", "md__n_e_x_t___s_e_s_s_i_o_n___p_l_a_n.html#autotoc_md89", null ],
        [ "4. UI spectrum visualizer", "md__n_e_x_t___s_e_s_s_i_o_n___p_l_a_n.html#autotoc_md90", null ]
      ] ],
      [ "Order of operations recomandat pentru sesiunea următoare", "md__n_e_x_t___s_e_s_s_i_o_n___p_l_a_n.html#autotoc_md92", null ]
    ] ],
    [ "OmniBus-BlockChainCore", "md__r_e_a_d_m_e.html", [
      [ "Ce este", "md__r_e_a_d_m_e.html#autotoc_md96", null ],
      [ "Build rapid", "md__r_e_a_d_m_e.html#autotoc_md98", null ],
      [ "Structura proiectului", "md__r_e_a_d_m_e.html#autotoc_md100", null ],
      [ "RPC API — port 8332", "md__r_e_a_d_m_e.html#autotoc_md102", null ],
      [ "Wallet — 5 Domenii Post-Quantum", "md__r_e_a_d_m_e.html#autotoc_md104", null ],
      [ "Parametri Blockchain", "md__r_e_a_d_m_e.html#autotoc_md106", null ],
      [ "Mining Pool (Node.js)", "md__r_e_a_d_m_e.html#autotoc_md108", null ],
      [ "Tests", "md__r_e_a_d_m_e.html#autotoc_md110", null ],
      [ "Integrare SuperVault", "md__r_e_a_d_m_e.html#autotoc_md112", null ],
      [ "Status implementare", "md__r_e_a_d_m_e.html#autotoc_md114", null ],
      [ "Legătură cu OmnibusSidebar", "md__r_e_a_d_m_e.html#autotoc_md116", null ]
    ] ],
    [ "OmniBus BlockChain Core - Setup &amp; Getting Started", "md__s_e_t_u_p.html", [
      [ "What Was Created", "md__s_e_t_u_p.html#autotoc_md119", [
        [ "✅ Core Components (Zig Backend)", "md__s_e_t_u_p.html#autotoc_md120", null ],
        [ "✅ Frontend (TypeScript/React)", "md__s_e_t_u_p.html#autotoc_md121", null ],
        [ "✅ Build &amp; Test", "md__s_e_t_u_p.html#autotoc_md122", null ],
        [ "✅ Configuration", "md__s_e_t_u_p.html#autotoc_md123", null ]
      ] ],
      [ "Quick Start (5 Minutes)", "md__s_e_t_u_p.html#autotoc_md125", [
        [ "1. Verify Prerequisites", "md__s_e_t_u_p.html#autotoc_md126", null ],
        [ "2. Navigate to Project", "md__s_e_t_u_p.html#autotoc_md127", null ],
        [ "3. View Help", "md__s_e_t_u_p.html#autotoc_md128", null ],
        [ "4. Build Everything", "md__s_e_t_u_p.html#autotoc_md129", null ]
      ] ],
      [ "Run the System", "md__s_e_t_u_p.html#autotoc_md131", [
        [ "Terminal 1: Start Blockchain (Mining)", "md__s_e_t_u_p.html#autotoc_md132", null ],
        [ "Terminal 2: Start RPC Server", "md__s_e_t_u_p.html#autotoc_md133", null ],
        [ "Terminal 3: Start Frontend", "md__s_e_t_u_p.html#autotoc_md134", null ]
      ] ],
      [ "Test the System", "md__s_e_t_u_p.html#autotoc_md136", [
        [ "Run Unit Tests", "md__s_e_t_u_p.html#autotoc_md137", null ],
        [ "Test RPC Endpoints (via curl)", "md__s_e_t_u_p.html#autotoc_md138", null ]
      ] ],
      [ "Project Structure", "md__s_e_t_u_p.html#autotoc_md140", null ],
      [ "What to Do Next", "md__s_e_t_u_p.html#autotoc_md142", [
        [ "Phase 1 Tasks (Current Week)", "md__s_e_t_u_p.html#autotoc_md143", null ],
        [ "Phase 2 Tasks (Week 2)", "md__s_e_t_u_p.html#autotoc_md144", null ],
        [ "Phase 3 Tasks (Week 3)", "md__s_e_t_u_p.html#autotoc_md145", null ],
        [ "Phase 4 Tasks (Week 4)", "md__s_e_t_u_p.html#autotoc_md146", null ],
        [ "Phase 5 Tasks (Week 5)", "md__s_e_t_u_p.html#autotoc_md147", null ]
      ] ],
      [ "Files to Focus On", "md__s_e_t_u_p.html#autotoc_md149", null ],
      [ "Blockchain Parameters (Reference)", "md__s_e_t_u_p.html#autotoc_md151", null ],
      [ "RPC Methods (Phase 1)", "md__s_e_t_u_p.html#autotoc_md153", null ],
      [ "Git Setup", "md__s_e_t_u_p.html#autotoc_md155", [
        [ "Initialize Repository", "md__s_e_t_u_p.html#autotoc_md156", null ],
        [ "Push to GitHub", "md__s_e_t_u_p.html#autotoc_md157", null ]
      ] ],
      [ "Troubleshooting", "md__s_e_t_u_p.html#autotoc_md159", [
        [ "\"Command not found: zig\"", "md__s_e_t_u_p.html#autotoc_md160", null ],
        [ "\"Build fails with linking error\"", "md__s_e_t_u_p.html#autotoc_md161", null ],
        [ "\"RPC server won't start\"", "md__s_e_t_u_p.html#autotoc_md162", null ],
        [ "\"Frontend won't load\"", "md__s_e_t_u_p.html#autotoc_md163", null ]
      ] ],
      [ "Resources", "md__s_e_t_u_p.html#autotoc_md165", null ]
    ] ],
    [ "Modules", "namespaces.html", [
      [ "Modules List", "namespaces.html", "namespaces_dup" ],
      [ "Module Members", "namespacemembers.html", [
        [ "All", "namespacemembers.html", null ],
        [ "Functions/Subroutines", "namespacemembers_func.html", null ],
        [ "Variables", "namespacemembers_vars.html", null ]
      ] ]
    ] ],
    [ "Data Types", "annotated.html", [
      [ "Data Types List", "annotated.html", "annotated_dup" ],
      [ "Data Type Index", "classes.html", null ],
      [ "Data Fields", "functions.html", [
        [ "All", "functions.html", null ],
        [ "Variables", "functions_vars.html", null ]
      ] ]
    ] ],
    [ "Files", "files.html", [
      [ "File List", "files.html", "files_dup" ]
    ] ]
  ] ]
];

var NAVTREEINDEX =
[
"_we-_are-_here-_hod_lum-_w_o_r_k_e_r_8py.html"
];

const SYNCONMSG = 'click to disable panel synchronization';
const SYNCOFFMSG = 'click to enable panel synchronization';
const LISTOFALLMEMBERS = 'List of all members';