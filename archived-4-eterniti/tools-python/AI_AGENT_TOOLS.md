# Tooluri Python pentru AI Agents - OmniBus Blockchain

> **Scop:** Toolbox complet pentru AI agents să lucreze eficient cu proiectul fără să consume mulți tokeni.

---

## 📋 INDEX RAPID

| # | Tool | Scop | Timp execuție |
|---|------|------|---------------|
| 1 | `project_health.py` | Check rapid starea proiectului | <1s |
| 2 | `quick_check.py` | Verificare sintaxă + build | 2-5s |
| 3 | `dependency_check.py` | Verifică dependințe externe | <1s |
| 4 | `code_metrics.py` | Statistici cod (LOC, complexitate) | <1s |
| 5 | `test_runner.py` | Rulează teste specifice | 10-60s |
| 6 | `config_validator.py` | Validează omnibus.toml | <1s |
| 7 | `rpc_validator.py` | Verifică endpoint-uri RPC | 2-5s |
| 8 | `security_scan.py` | Scanare vulnerabilități | 2-3s |
| 9 | `doc_sync_check.py` | Verifică sincronizare cod-doc | <1s |
| 10 | `module_graph.py` | Generează graf dependențe | <1s |
| 11 | `todo_extractor.py` | Extrage TODO/FIXME din cod | <1s |
| 12 | `gas_analyzer.py` | Analizează costuri tranzacții | <1s |
| 13 | `consensus_monitor.py` | Monitorizează consens în timp real | Continuu |
| 14 | `benchmark_quick.py` | Benchmark rapid TPS | 10-30s |
| 15 | `fuzz_tester.py` | Teste fuzz pentru input-uri | 30-60s |
| 16 | `prompt_generator.py` | Generează prompt-uri pentru alți agenți | <1s |
| 17 | `git_summary.py` | Sumar schimbări recente | <1s |
| 18 | `coverage_check.py` | Verifică acoperire teste | 5-10s |
| 19 | `memory_analyzer.py` | Analizează utilizare memorie | 2-5s |
| 20 | `api_diff.py` | Compară API între versiuni | <1s |

---

## 🔧 Toolurile în detaliu

### 1. `project_health.py` - Stare generală proiect
**Ce face:**
- Verifică dacă Zig e instalat și versiunea
- Verifică liboqs (opțional)
- Numără fișiere .zig, teste, linii de cod
- Verifică dacă build.zig există

**Output:**
```
[OK] Zig 0.15.2 detectat
[OK] 79 fișiere .zig
[OK] 3,142 constante
[OK] 38 enum-uri
[WARN] liboqs nu e detectat (opțional)
[OK] Build.zig prezent
```

**Pentru agenți:** Run this first before any coding task.

---

### 2. `quick_check.py` - Verificare rapidă
**Ce face:**
- Verifică sintaxa Zig (zig fmt --check)
- Încearcă build rapid (fără liboqs)
- Verifică testele de bază

**Output:**
```
[SINTAXA] 79/79 fișiere OK
[BUILD]   Success (fără liboqs)
[TESTE]   45/45 teste crypto trecute
[TIMP]    3.2s
```

**Pentru agenți:** Use after code changes to verify nothing broke.

---

### 3. `dependency_check.py` - Verifică sistem
**Ce verifică:**
- Zig instalat (versiune minimă 0.15.0)
- liboqs compilat (opțional)
- Python 3.8+ (pentru tooluri)
- Spațiu disk disponibil
- Porturi libere (8332, 8333, 8334)

**Output:**
```
[DEPENDINȚE]
  [OK] Zig 0.15.2
  [OK] Python 3.12
  [WARN] liboqs - nu e detectat (opțional)
  [OK] Spațiu: 45GB disponibil
  [OK] Port 8332: liber
  [OK] Port 8333: liber
```

---

### 4. `code_metrics.py` - Metrici cod
**Ce calculează:**
- Total linii de cod (LOC)
- Linii de test
- Complexitate medie per fișier
- Raport test/cod
- Cele mai mari fișiere
- Duplicate detection (bazic)

**Output:**
```
[METRICI COD]
  Fișiere .zig:     79
  LOC total:        24,547
  LOC teste:        8,234 (33%)
  Medie/fișier:     310 LOC
  Cel mai mare:     core/p2p.zig (1,247 LOC)
  Complexitate:     Medie
```

---

### 5. `test_runner.py` - Rulează teste selectiv
**Ce face:**
- Rulează teste pe grupuri (crypto, chain, net, etc.)
- Generează raport HTML/opțiuni text
- Compară cu rulări anterioare

**Utilizare:**
```bash
python test_runner.py --group crypto    # Doar teste crypto
python test_runner.py --group chain     # Doar teste blockchain
python test_runner.py --failed          # Doar cele care au picat ultima dată
python test_runner.py --watch           # Watch mode pentru TDD
```

---

### 6. `config_validator.py` - Validează config
**Ce verifică:**
- omnibus.toml sintaxă corectă
- Valori în range-uri valide
- Referințe la fișiere existente
- Port-uri unice

**Output:**
```
[CONFIG] omnibus.toml
  [OK] Sintaxă TOML validă
  [OK] network.port = 8333 (în range 1024-65535)
  [OK] database.path = "omnibus-chain.dat" (există)
  [WARN] mining.threads = 0 (va folosi toate core-urile)
```

---

### 7. `rpc_validator.py` - Verifică RPC
**Ce face:**
- Pornește nod temporar
- Testează toate endpoint-urile RPC
- Verifică răspunsurile JSON
- Măsoară latență

**Output:**
```
[RPC TEST]
  [OK] getblockcount        12ms
  [OK] getbestblockhash     8ms
  [OK] getmempoolinfo       15ms
  [WARN] getpeerinfo        timeout (nod single)
  [STATS] Medie: 11ms, Max: 15ms
```

---

### 8. `security_scan.py` - Scanare securitate
**Ce caută:**
- Hardcoded keys/secrets
- Buffer sizes nevalidate
- unwrap/expect în cod (panic spots)
- TODO-uri legate de securitate
- Debug prints care ar putea expune date

**Output:**
```
[SECURITY SCAN]
  [INFO] 23x "expect" găsit (normal în Zig)
  [WARN] 3x TODO security în core/p2p.zig
  [OK]   Niciun secret hardcoded detectat
  [OK]   Toate buffer-ele au verificări de dimensiune
```

---

### 9. `doc_sync_check.py` - Verifică documentație
**Ce compară:**
- Constante din cod vs OPCODES.md
- RPC methods din cod vs documentație
- Comentarii TODO vs lista de taskuri
- CHANGELOG.md actualizat?

**Output:**
```
[SYNC CHECK]
  [OK]   OPCODES.md la zi (ultima actualizare: 2026-03-31)
  [WARN] 3 constante noi în core/p2p.zig nu sunt în OPCODES.md
  [OK]   CHANGELOG.md actualizat în ultima săptămână
```

---

### 10. `module_graph.py` - Graf dependențe
**Ce generează:**
- DAG (directed acyclic graph) al importurilor
- Detectează cicluri
- Arată modulele cele mai dependente
- Exportă în format Mermaid/DOT

**Output:**
```
[DEPENDENȚE]
  Core modules: 69
  Importuri totale: 234
  Cel mai utilizat: core/crypto.zig (importat de 12 module)
  Ciclu detectat: Niciunul

  Graf generat: module_graph.mmd
```

---

### 11. `todo_extractor.py` - Extrage taskuri
**Ce extrage:**
- TODO comentarii
- FIXME comentarii
- BUG comentarii
- HACK comentarii
- Le grupează după fișier și prioritate

**Output:**
```
[TODO EXTRACT]
  Total: 47 taskuri
  
  PRIORITATE ÎNALTĂ (FIXME/BUG): 5
    - core/p2p.zig:42 FIXME: Buffer overflow posibil
    - core/consensus.zig:156 BUG: Edge case la timeout
  
  TODO normal: 38
  HACK: 4
```

---

### 12. `gas_analyzer.py` - Analiză costuri
**Ce calculează:**
- Cost per tranzacție (SAT)
- Estimare cost pentru operații comune
- Comparare cu alte blockchain-uri
- Fee market analysis

**Output:**
```
[GAS ANALYSIS]
  TX standard:     1 SAT (minim)
  TX complexă:     5-10 SAT
  Contract deploy: N/A (smart contracts nu sunt încă)
  
  Comparativ cu ETH:
    - 1M x mai ieftin
  
  Burn rate: 50% din fees
```

---

### 13. `consensus_monitor.py` - Monitorizare consens
**Ce monitorizează:**
- Înălțimea blocului curent
- Timp de finalizare (Casper FFG)
- Număr validatori activi
- Checkpoint-uri

**Utilizare:**
```bash
python consensus_monitor.py --watch     # Monitorizare continuă
python consensus_monitor.py --snapshot  # Status instant
```

---

### 14. `benchmark_quick.py` - Benchmark rapid
**Ce măsoară:**
- TPS (transactions per second)
- Timp de block
- Latență rețea P2P
- Timp de validare

**Output:**
```
[BENCHMARK]
  TPS:        4,523 (target: 5,000)
  Block time: 1.02s (target: 1s)
  Latență:    23ms medie
  
  [OK] Performanță în parametri
```

---

### 15. `fuzz_tester.py` - Teste fuzz
**Ce testează:**
- Input-uri random pentru parser-e
- TX malformed
- Block headers corupte
- Network messages malformed

**Output:**
```
[FUZZ TEST]
  TX parser:    10,000 iterări, 0 crash-uri
  Block parser: 10,000 iterări, 0 crash-uri
  P2P messages: 10,000 iterări, 0 crash-uri
  
  [OK] Toate testele fuzz trecute
```

---

### 16. `prompt_generator.py` - Generează prompt-uri
**Ce generează:**
- Prompturi context-aware pentru alți agenți
- Include starea curentă a proiectului
- Include erori recente
- Include TODO-uri relevante

**Utilizare:**
```bash
python prompt_generator.py --task "Implement LMD GHOST"
# Generează prompt complet cu context
```

**Output:**
```
[PROMPT GENERAT]

Tu ești un dezvoltator Zig experto specializat în blockchain.

CONTEXT PROIECT:
- 79 fișiere .zig, 24,547 LOC
- Build: OK
- Teste: 45/45 trecute
- TODO relevante: 3 în consens

TASK: Implement LMD GHOST fork choice rule

COD EXISTENT RELEVANT:
- core/finality.zig - Casper FFG implementat
- core/consensus.zig - Consens engine

REFERINȚE:
- OPCODES.md secțiunea Consensus
- Ethereum spec: LMD GHOST

CERINȚE:
1. Adaugă struct LMDGhost în core/consensus.zig
2. Implementează funcția getHead()
3. Adaugă teste
4. Actualizează OPCODES.md
```

---

### 17. `git_summary.py` - Sumar Git
**Ce arată:**
- Commit-uri recente
- Fișiere modificate recent
- Autori activi
- Branch-uri
- Statistici (adăugat/șters)

**Output:**
```
[git SUMMARY]
  Branch: main
  Commits: 127 total
  
  Ultimele 3 commit-uri:
    - a1b2c3d: Fix memory leak în p2p.zig
    - e4f5g6h: Add BLS threshold signatures
    - i7j8k9l: Update consensus constants
  
  Fișiere modificate recent:
    - core/p2p.zig
    - core/bls_signatures.zig
    - OPCODES.md
```

---

### 18. `coverage_check.py` - Acoperire teste
**Ce verifică:**
- Ce funcții au teste
- Ce module lipsesc teste
- Procent acoperire (estimat)
- Teste care nu rulează

**Output:**
```
[COVERAGE]
  Module cu teste:     45/69 (65%)
  Funcții testate:     234/567 (41%)
  
  Module fără teste:
    - core/bridge_relay.zig
    - core/oracle.zig
    
  [WARN] Acoperire sub 50%
```

---

### 19. `memory_analyzer.py` - Analiză memorie
**Ce analizează:**
- Alocări în cod (arena, allocator patterns)
- Potențial memory leaks
- Buffer sizes
- Stack vs heap usage

**Output:**
```
[MEMORY ANALYSIS]
  Alocări detectate: 156
  - Arena: 89 (recomandat)
  - General: 45
  - Potențial leak: 2 (în core/p2p.zig:234, core/sync.zig:89)
  
  Buffer sizes ok: 45/45 verificate
```

---

### 20. `api_diff.py` - Diferențe API
**Ce compară:**
- Export-uri publice între versiuni
- Semnături funcții schimbate
- Constante modificate
- Breaking changes

**Utilizare:**
```bash
python api_diff.py --from v1.0.0 --to HEAD
```

**Output:**
```
[API DIFF v1.0.0 → HEAD]
  Adăugat:
    + blsAggregateKeys() în core/bls_signatures.zig
    + CommitteeSelector struct
  
  Modificat:
    ~ FinalityEngine.init() - parametru nou
  
  Șters:
    - Nimic (compatibilitate păstrată)
  
  [INFO] 1 breaking change detectat
```

---

## 🚀 Workflow pentru AI Agents

### Task nou - Check rapid (înainte de a citi codul):
```bash
python tools/project_health.py     # Stare generală
python tools/quick_check.py        # Build OK?
python tools/todo_extractor.py     # Ce TODO-uri există?
```

### În timpul dezvoltării:
```bash
python tools/test_runner.py --watch    # TDD mode
python tools/code_metrics.py           # Nu crește prea mult fișierul
python tools/security_scan.py          # Verifică ce scrii
```

### Înainte de commit:
```bash
python tools/doc_sync_check.py         # Doc actualizat?
python tools/api_diff.py               # Breaking changes?
python tools/quick_check.py            # Totul compilează?
```

### Post-commit:
```bash
python tools/benchmark_quick.py        # Regresii de performanță?
python tools/coverage_check.py         # Acoperire teste?
```

---

## 📦 Instalare Tooluri

Toate toolurile sunt în directorul `tools/` și nu necesită instalare.

Dependințe Python (standard library doar):
- `toml` (pentru parsare config)
- `pathlib` (built-in)
- `subprocess` (built-in)
- `json` (built-in)

Instalare dependințe opționale:
```bash
pip install toml colorama  # colorama pentru Windows colors
```

---

## 🎯 Prioritate Implementare

### 🔴 CRITICE (implementează primul):
1. `project_health.py` - Stare generală
2. `quick_check.py` - Build check
3. `todo_extractor.py` - Task tracking
4. `test_runner.py` - Teste selective

### 🟡 IMPORTANTE:
5. `code_metrics.py` - Monitorizare dimensiune
6. `security_scan.py` - Securitate
7. `doc_sync_check.py` - Documentație
8. `prompt_generator.py` - Context pentru agenți

### 🟢 NICE TO HAVE:
9-20. Restul toolurilor

---

## 💡 Tips pentru AI Agents

1. **Rulează `project_health.py` întâi** - Dă context instant fără să citești fișiere
2. **Folosește `prompt_generator.py`** - Generează prompturi pentru alți agenți
3. **Verifică `todo_extractor.py`** - Vezi ce taskuri sunt deja în backlog
4. **Rulează `quick_check.py`** - Validare rapidă înainte de codat
5. **Folosește `test_runner.py --group X`** - Testează doar ce ai modificat

---

*Document generat automat pentru OmniBus Blockchain AI Collective*
