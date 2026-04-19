# 🔧 OmniBus Blockchain Tools

Tool-uri Python pentru dezvoltarea, testarea și monitorizarea OmniBus BlockChain Core.

## 📁 Structura Tool-urilor

```
tools/
├── ANALYSIS/              # Analiză cod și calitate
│   ├── blockchain_analyzer.py
│   ├── blockchain_deep_audit.py
│   └── blockchain_dependency_graph.py
│
├── SECURITY/              # Securitate și audit
│   └── vulnerability_scanner.py
│
├── MONITORING/            # Observabilitate și metrici
│   └── metrics_exporter.py
│
├── PERFORMANCE/           # Benchmarking și optimizare
│   └── benchmark.py
│
├── TESTING/               # Testare și validare
│   └── test_runner.py
│
├── COMPARISON/            # Analiză competitivă
│   └── blockchain_vs_comparison.py
│
├── DOCUMENTATION/         # Generare documentație ⭐ NOU
│   ├── doc_generator.py
│   └── changelog_manager.py
│
├── BRIDGE/                # Cross-chain tools ⭐ NOU
│   ├── bridge_validator.py
│   └── oracle_verifier.py
│
├── blockchain_master_audit.py
└── README.md

TOTAL: 15 tool-uri funcționale
```

## 🚀 Quick Start

```bash
# 1. Analiză completă
python tools/ANALYSIS/blockchain_analyzer.py

# 2. Scanare securitate
python tools/SECURITY/vulnerability_scanner.py --critical

# 3. Metrici live
python tools/MONITORING/metrics_exporter.py

# 4. Comparativ blockchain-uri
python tools/COMPARISON/blockchain_vs_comparison.py

# 5. Generează documentație API ⭐ NOU
python tools/DOCUMENTATION/doc_generator.py --format html

# 6. Validează tranzacție cross-chain ⭐ NOU
python tools/BRIDGE/bridge_validator.py --proof tx_proof.json
```

## 📊 Tool-uri Disponibile

### ANALYSIS - Analiză Cod

| Tool | Descriere | Usage |
|------|-----------|-------|
| `blockchain_analyzer.py` | Analiză module Zig, status REAL/PARTIAL/STUB | `python ANALYSIS/blockchain_analyzer.py` |
| `blockchain_deep_audit.py` | Securitate, CWE, complexitate ciclomatică | `python ANALYSIS/blockchain_deep_audit.py` |
| `blockchain_dependency_graph.py` | Graf dependențe între module | `python ANALYSIS/blockchain_dependency_graph.py --dot graph.dot` |

### SECURITY - Securitate

| Tool | Descriere | Usage |
|------|-----------|-------|
| `vulnerability_scanner.py` | Scanare CWE, hardcoded secrets, unsafe patterns | `python SECURITY/vulnerability_scanner.py --critical` |

### MONITORING - Monitorizare

| Tool | Descriere | Usage |
|------|-----------|-------|
| `metrics_exporter.py` | Exportă metrici Prometheus | `python MONITORING/metrics_exporter.py --http --port 9090` |

### PERFORMANCE - Performanță

| Tool | Descriere | Usage |
|------|-----------|-------|
| `benchmark.py` | Benchmark TPS, hashrate, memory | `python PERFORMANCE/benchmark.py` |

### TESTING - Testare

| Tool | Descriere | Usage |
|------|-----------|-------|
| `test_runner.py` | Rulează testele Zig | `python TESTING/test_runner.py` |

### COMPARISON - Analiză Competitivă

| Tool | Descriere | Usage |
|------|-----------|-------|
| `blockchain_vs_comparison.py` | Compară cu Bitcoin, Ethereum, Solana, EGLD | `python COMPARISON/blockchain_vs_comparison.py` |

### DOCUMENTATION - Documentație ⭐ NOU

| Tool | Descriere | Usage |
|------|-----------|-------|
| `doc_generator.py` | Generează API docs din cod Zig | `python DOCUMENTATION/doc_generator.py --format html` |
| `changelog_manager.py` | Gestionează CHANGELOG.md și release notes | `python DOCUMENTATION/changelog_manager.py --release` |

#### doc_generator.py
Generează documentație API din comentarii Zig:
- Extrage `///` doc comments
- Parsează funcții publice și structuri
- Generează Markdown sau HTML
- Creează index navigabil

```bash
# Generează toată documentația în HTML
python tools/DOCUMENTATION/doc_generator.py --format html --output ./docs/api

# Doar pentru un modul specific
python tools/DOCUMENTATION/doc_generator.py --module wallet --format md
```

#### changelog_manager.py
Gestionează changelog și versiuni:
- Parsează commit-uri git
- Categorizează: Added, Changed, Fixed, Security
- Sugerează version bumping (semver)
- Generează release notes

```bash
# Generează changelog
python tools/DOCUMENTATION/changelog_manager.py

# Crează release notes
python tools/DOCUMENTATION/changelog_manager.py --release --bump minor

# De la o versiune specifică
python tools/DOCUMENTATION/changelog_manager.py --since v1.0.0
```

### BRIDGE - Cross-Chain ⭐ NOU

| Tool | Descriere | Usage |
|------|-----------|-------|
| `bridge_validator.py` | Validează tranzacții cross-chain | `python BRIDGE/bridge_validator.py --proof tx.json` |
| `oracle_verifier.py` | Verifică datele de la oracles | `python BRIDGE/oracle_verifier.py --consensus BTC` |

#### bridge_validator.py
Validează tranzacții cross-chain:
- Verifică SPV proofs (Bitcoin)
- Verifică Merkle Patricia proofs (Ethereum)
- Detectează double-spend
- Estimează timp finalizare

```bash
# Validează cu proof file
python tools/BRIDGE/bridge_validator.py --proof btc_lock_proof.json

# Verifică status
python tools/BRIDGE/bridge_validator.py --tx <hash> --source bitcoin
```

#### oracle_verifier.py
Verifică integritatea datelor de la oracles:
- Price feed validation
- Outlier detection
- Multi-oracle consensus
- Manipulation detection
- Stale data detection

```bash
# Verifică consens pentru BTC
python tools/BRIDGE/oracle_verifier.py --consensus BTC

# Raport complet
python tools/BRIDGE/oracle_verifier.py --report --json

# Verifică specific
python tools/BRIDGE/oracle_verifier.py --price BTC --value 45000
```

## 🎯 Workflow Recomandat

### 1. Înainte de commit
```bash
# 1. Verifică calitatea codului
python tools/ANALYSIS/blockchain_analyzer.py --json report.json

# 2. Scanare securitate
python tools/SECURITY/vulnerability_scanner.py --critical

# 3. Rulează testele
python tools/TESTING/test_runner.py
```

### 2. Pentru release
```bash
# 1. Audit complet
python tools/ANALYSIS/blockchain_deep_audit.py --json audit.json

# 2. Generează documentație
python tools/DOCUMENTATION/doc_generator.py --format html

# 3. Update changelog
python tools/DOCUMENTATION/changelog_manager.py --release --bump minor

# 4. Comparativ cu altele
python tools/COMPARISON/blockchain_vs_comparison.py --html comparison.html
```

### 3. Monitorizare în producție
```bash
# Pornește metrics server
python tools/MONITORING/metrics_exporter.py --http --port 9090

# Monitorizează oracles
python tools/BRIDGE/oracle_verifier.py --report

# În Prometheus, adaugă:
# - targets: ['localhost:9090']
```

### 4. Pentru cross-chain operations
```bash
# Validează o tranzacție bridge
python tools/BRIDGE/bridge_validator.py --proof tx_proof.json

# Verifică consens prețuri
python tools/BRIDGE/oracle_verifier.py --consensus BTC
```

## 📈 Interpretare Rezultate

### Scor Module (din blockchain_analyzer.py)
- **90-100%**: Excellent - Production ready
- **70-89%**: Good - Minor improvements needed
- **50-69%**: Fair - Needs work
- **<50%**: Poor - Major refactoring needed

### Severity Vulnerabilități (din vulnerability_scanner.py)
- **CRITICAL**: Exploitable vulnerability - Fix immediately
- **HIGH**: Serious security issue - Fix before release
- **MEDIUM**: Potential issue - Fix in next sprint
- **LOW**: Minor issue - Fix when convenient

### Consens Oracle (din oracle_verifier.py)
- **VALID**: Date verificate, pot fi folosite on-chain
- **STALE**: Date vechi, nu folosi
- **OUTLIER**: Prea multă variație între surse
- **MANIPULATED**: Posibilă manipulare, investighează

## 🔧 Cerințe

- Python 3.8+
- Zig 0.15.2+ (pentru teste și syntax check)
- Node.js (pentru mining pool tests)
- Git (pentru changelog_manager.py)

## 📝 Adăugare Tool Nou

1. Creează fișier în directorul corespunzător
2. Adaugă docstring cu descriere și usage
3. Adaugă în acest README
4. Testează cu: `python tools/CATEGORY/new_tool.py`

## 🐛 Debugging

Dacă un tool nu funcționează:
```bash
# Verifică path-ul
python -c "import sys; print(sys.path)"

# Rulează cu verbose
python tools/ANALYSIS/blockchain_analyzer.py --verbose

# Verifică dacă Zig e în PATH
zig version

# Verifică git (pentru changelog_manager)
git --version
```

## 📚 Referințe

- [OmniBus Blockchain Core](../README.md)
- [Arhitectura Dual OS](../ARCHITECTURE_DUAL_OS.md)
- [Viziune Proiect](../VISION_OMNIBUS_BLOCKCHAIN.md)
