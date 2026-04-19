# OmniBus Blockchain - Agent Scripts

> **Toolbox Python pentru AI agents să lucreze eficient cu proiectul.**

---

## 🚀 Quick Start

```bash
# Verificare rapidă starea proiectului
python project_health.py

# Verifică sintaxă + build rapid
python quick_check.py

# Vezi ce taskuri sunt de făcut
python todo_extractor.py

# Rulează teste specifice
python test_runner.py --group crypto
```

---

## 📋 Tooluri Disponibile

### 🔴 Critice (rulează acestea primul)

| Tool | Scop | Timp |
|------|------|------|
| `project_health.py` | Stare generală proiect | <1s |
| `quick_check.py` | Sintaxă + build rapid | 2-5s |
| `todo_extractor.py` | Taskuri în backlog | <1s |
| `test_runner.py` | Teste selective | 10-60s |

### 🟡 Importante

| Tool | Scop | Timp |
|------|------|------|
| `code_metrics.py` | Metrici cod (LOC, etc.) | <1s |
| `security_scan.py` | Vulnerabilități | 2-3s |
| `prompt_generator.py` | Generează prompturi AI | <1s |
| `dependency_check.py` | Verifică dependințe | <1s |
| `config_validator.py` | Validează config | <1s |

---

## 🎯 Workflow Recomandat

### Înainte de a începe un task nou:

```bash
# 1. Verifică starea proiectului
python project_health.py
# Output: Zig OK, 79 fișiere, build OK

# 2. Vezi ce taskuri există deja
python todo_extractor.py --high
# Output: Listează TODO-uri HIGH priority

# 3. Generează prompt pentru agent
python prompt_generator.py --task "Implementează LMD GHOST" --include-todos
# Output: Prompt complet cu context
```

### După ce scrii cod:

```bash
# 1. Verifică sintaxa și build
python quick_check.py

# 2. Rulează testele relevante
python test_runner.py --group chain

# 3. Scanare securitate rapidă
python security_scan.py

# 4. Verifică metrici (nu crește prea mult fișierul)
python code_metrics.py --summary
```

### Înainte de commit:

```bash
# 1. Verifică TODO-urile
python todo_extractor.py

# 2. Validare config
python config_validator.py

# 3. Verifică dependințe
python dependency_check.py

# 4. Build + teste complete
python quick_check.py && python test_runner.py
```

---

## 📖 Documentație Tooluri

### project_health.py

```bash
python project_health.py              # Verificare standard
python project_health.py --json       # Output JSON
python project_health.py --quiet      # Doar cod de ieșire
```

**Verifică:**
- Zig instalat și versiunea
- liboqs (opțional)
- Număr fișiere, LOC, constante, enum-uri
- Structură proiect (build.zig, etc.)

**Cod ieșire:** 0 = sănătos, 1 = probleme

---

### quick_check.py

```bash
python quick_check.py                 # Verificare completă
python quick_check.py --syntax        # Doar sintaxă
python quick_check.py --build         # Doar build
python quick_check.py --test          # Doar teste
```

**Verifică:**
- Sintaxă Zig (zig fmt --check)
- Build rapid (fără liboqs)
- Teste crypto și chain

---

### todo_extractor.py

```bash
python todo_extractor.py              # Toate TODO-urile
python todo_extractor.py --high       # Doar HIGH priority
python todo_extractor.py --medium     # Doar MEDIUM
python todo_extractor.py --json       # Output JSON
```

**Detectează:** TODO, FIXME, BUG, HACK, XXX, NOTE

**Prioritizare:**
- HIGH: FIXME, BUG, cuvinte cheie (critical, security)
- MEDIUM: TODO normal
- LOW: NOTE, optional

---

### test_runner.py

```bash
python test_runner.py                 # Toate testele
python test_runner.py --group crypto  # Doar crypto
python test_runner.py --group chain   # Doar chain
python test_runner.py --file core/p2p.zig  # Fișier specific
python test_runner.py --watch         # Watch mode (TDD)
```

**Grupe disponibile:** crypto, chain, net, shard, storage, light, wallet

---

### code_metrics.py

```bash
python code_metrics.py                # Metrici complete
python code_metrics.py --summary      # Doar sumar
python code_metrics.py --json         # Output JSON
```

**Calculează:**
- Total LOC, fișiere, funcții
- Raport test/cod
- Complexitate medie
- Top fișiere ca dimensiune

---

### security_scan.py

```bash
python security_scan.py               # Scan complet
python security_scan.py --critical    # Doar critice
python security_scan.py --json        # Output JSON
```

**Detectează:**
- Secrete hardcodate
- Buffer operations unsafe
- TODO-uri de securitate
- Panic/expect în cod
- Debug prints

---

### prompt_generator.py

```bash
python prompt_generator.py --task "Implementează X" --include-todos
python prompt_generator.py --task "Fix bug" --file core/p2p.zig
python prompt_generator.py --task "Refactor" --output prompt.txt
```

**Generează:**
- Context proiect (dimensiune, build status)
- Task clar definit
- TODO-uri relevante
- Cerințe specifice
- Referințe utile

---

### dependency_check.py

```bash
python dependency_check.py            # Verificare completă
python dependency_check.py --json     # Output JSON
```

**Verifică:**
- Zig (versiune minimă 0.15.0)
- Python (3.8+)
- Git
- liboqs (opțional)
- Porturi libere (8332, 8333, 8334)

---

### config_validator.py

```bash
python config_validator.py            # Validează omnibus.toml
python config_validator.py --json     # Output JSON
```

**Validează:**
- Sintaxă TOML
- Valori în range-uri
- Referințe fișiere existente
- Secțiuni required

---

## 🔄 Integrare CI/CD

### Pre-commit hook:

```bash
#!/bin/bash
# .git/hooks/pre-commit

cd tools/agentscripts

python quick_check.py --quiet || exit 1
python security_scan.py --critical --quiet || exit 1
python config_validator.py --quiet || exit 1
```

### GitHub Actions:

```yaml
name: Quick Checks
on: [push, pull_request]

jobs:
  check:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v2
      - name: Project Health
        run: python tools/agentscripts/project_health.py
      - name: Quick Check
        run: python tools/agentscripts/quick_check.py
      - name: Security Scan
        run: python tools/agentscripts/security_scan.py
```

---

## 📝 Convenții

### Cod de ieșire:
- **0** = Succes / OK
- **1** = Warning-uri / Probleme minore
- **2** = Erori critice

### Output:
- Default: Human-readable cu culori
- `--json`: Parsabil pentru alte tooluri
- `--quiet`: Doar cod de ieșire

---

## 🔧 Dezvoltare

### Adăugarea unui tool nou:

1. Creează `nume_tool.py`
2. Adaugă la această documentație
3. Actualizează tabela de mai sus
4. Testează cu `--json` și `--quiet`

### Reguli:
- Fără dependințe externe (doar standard library)
- Timp de execuție < 60s (ideal < 5s)
- Cod de ieșire corect
- Suport pentru `--json` și `--quiet`

---

## 🐛 Troubleshooting

### "Zig not found"
```bash
# Adaugă Zig la PATH sau
export PATH="$PATH:/path/to/zig"
```

### "Permission denied"
```bash
chmod +x tools/agentscripts/*.py
```

### "Module not found"
Toate scripturile folosesc doar standard library Python.
Nu sunt necesare pachete externe.

---

*OmniBus Blockchain - AI Agent Tools v1.0*
