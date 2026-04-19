# OmniBus Blockchain - Opcode Registry

> **Director centralizat pentru toate opcodurile, constantele și protocolul OmniBus Blockchain.**

---

## 📚 Fișiere în acest director

| Fișier | Descriere |
|--------|-----------|
| `OPCODES.md` | **Referința completă** - Toate opcodurile, constantele, enum-urile și protocoalele |
| `scan_opcodes.py` | **Scanner automat** - Script Python care scanează codebase-ul și actualizează OPCODES.md |
| `README.md` | Acest fișier - Documentație despre cum se folosește directorul |

---

## 🚀 Utilizare rapidă

### 1. Consultarea referinței

Pur și simplu deschide `OPCODES.md` și caută ce ai nevoie folosind indexul rapid:

- [Message Types (P2P)](#message-types-p2p)
- [Consensus Types](#consensus-types)
- [Validator Status](#validator-status)
- [RPC Methods](#rpc-methods)
- etc.

### 2. Actualizarea automată

Când adaugi noi constante, enum-uri sau opcoduri în codebase, rulează:

```bash
cd claude-kimi-deep-gemini-opcodes
python scan_opcodes.py --update
```

Acesta va:
1. Scană toate fișierele `.zig` din proiect
2. Detectează automat constantele publice (`pub const`)
3. Extrage toate enum-urile și variantele lor
4. Identifică message types și magic numbers
5. Actualizează `OPCODES.md` cu informațiile noi

### 3. Verificarea diferențelor

Înainte de a actualiza, poți vedea ce s-a schimbat:

```bash
python scan_opcodes.py --diff
```

### 4. Generare în alt fișier

Dacă vrei să generezi o versiune nouă fără a suprascrie OPCODES.md:

```bash
python scan_opcodes.py --output opcodes_v2.md
```

---

## 📝 Convenții pentru adăugare manuală

Când adaugi opcoduri noi manual în `OPCODES.md`, urmează formatul:

### Pentru constante:
```markdown
| `NUME_CONSTANTA` | valoare | Descriere scurtă |
```

### Pentru enum-uri:
```markdown
| Cod | Nume | Descriere |
|-----|------|-----------|
| 0 | `varianta_1` | Descriere |
| 1 | `varianta_2` | Descriere |
```

### Pentru RPC methods:
```markdown
| Metodă | Parametri | Returnează |
|--------|-----------|------------|
| `nume_metoda` | `param1, param2` | Descriere return |
```

---

## 🔄 Workflow recomandat

### Când modifici codul Zig:

1. **Adaugi/modifici constante** în fișierele `.zig`
2. **Rulează scanner-ul:**
   ```bash
   python scan_opcodes.py --update
   ```
3. **Verifică modificările** în `OPCODES.md`
4. **Adaugă context manual** dacă e necesar (descrieri, exemple)
5. **Comite ambele fișiere** (cod + opcodes actualizate)

### Când ai nevoie de o constantă:

1. **Caută în `OPCODES.md`** înainte să definești una nouă
2. **Verifică dacă există deja** sub alt nume
3. **Folosește constanta existentă** sau definește una nouă cu nume clar

---

## 🎯 Scopul acestui director

### Problema

În proiecte blockchain mari, constantele și opcodurile sunt împrăștiate în zeci de fișiere:
- `core/p2p.zig` - Message types
- `core/consensus.zig` - Consensus constants
- `core/staking.zig` - Staking parameters
- `core/finality.zig` - Finality constants
- etc.

### Soluția

Acest director oferă:
1. **Referință unică** - Toate opcodurile într-un singur loc
2. **Scanare automată** - Nu mai trebuie să actualizezi manual
3. **Documentație vie** - Se sincronizează cu codul automat
4. **Onboarding rapid** - Noii dezvoltatori pot înțelege protocolul rapid

---

## 🤝 Colaborare

### Reguli pentru actualizări manuale:

1. **Nu șterge secțiunile generate automat** - Vor fi regenerate
2. **Adaugă secțiuni noi pentru context** - Explicații, exemple, note
3. **Comite separat** - Un commit pentru cod, unul pentru opcodes
4. **Verifică înainte de PR** - Rulează `--diff` să vezi ce s-a schimbat

### Când să rulezi scanner-ul:

- ✅ După ce adaugi noi constante/enum-uri
- ✅ Înainte de un release major
- ✅ Când refactorezi cod cu multe constante
- ✅ Periodic (săptămânal) pentru sincronizare

---

## 📊 Exemple de utilizare

### Exemplu 1: Găsirea rapidă a unui port

```bash
# În loc să cauți în cod...
grep -r "8333" core/

# Deschizi OPCODES.md și cauți în tabela "Port Reference"
# Găsești instant: Port 8333 = P2P Network
```

### Exemplu 2: Adăugarea unui Message Type nou

```zig
// În core/network.zig, adaugi:
pub const MessageType = enum(u8) {
    // ... existente
    new_feature = 21,  // ← Nou
};
```

```bash
# Rulezi scanner-ul
python scan_opcodes.py --update

# OPCODES.md este actualizat automat cu noul message type
```

### Exemplu 3: Documentarea manuală a unui opcode complex

```markdown
## 🔐 Cryptographic Opcodes

### BLS12-381 Operations

| Opcode | Input | Output | Descriere |
|--------|-------|--------|-----------|
| `OP_BLS_SIGN` | msg, sk | sig | Semnează mesaj cu BLS |
| `OP_BLS_VERIFY` | msg, pk, sig | bool | Verifică semnătură BLS |
| `OP_BLS_AGGREGATE` | sigs[] | agg_sig | Agreghează semnături |

**Note:**
- Toate operațiile folosesc curba BLS12-381
- Semnăturile agregate sunt 96 bytes
- Cheile publice sunt 48 bytes
```

---

## 🛠️ Troubleshooting

### Scanner-ul nu găsește constantele mele

Verifică că:
1. Constantele sunt `pub const` (nu doar `const`)
2. Nu sunt în fișiere excluse (`.zig-cache`, `zig-out`, etc.)
3. Sintaxa este corectă Zig

### Vreau să exclud anumite fișiere

Editează `scan_opcodes.py` și modifică:
```python
self.excluded_dirs = {'.git', '.zig-cache', 'zig-out', 'nume_director_nou'}
```

### Output-ul nu arată bine în Markdown

Verifică că:
1. Valorile constantelor nu conțin `|` (pipe)
2. Comentariile nu sunt pe multiple linii (scanner-ul ia doar prima linie)
3. Enum-urile au sintaxa standard Zig

---

## 📝 Formatul fișierelor

### OPCODES.md

```markdown
# Titlu secțiune

| Coloană 1 | Coloană 2 | Coloană 3 |
|-----------|-----------|-----------|
| Valoare 1 | Valoare 2 | Valoare 3 |

Descriere adițională...
```

### scan_opcodes.py

Script Python 3.8+ cu dependențe:
- `pathlib` (built-in)
- `re` (built-in)
- `argparse` (built-in)
- `dataclasses` (built-in)

**Nu necesită instalare de pachete externe!**

---

## 🎓 Învățare prin exemple

### Cum să citești un Message Type din cod:

**Cod Zig:**
```zig
pub const MessageType = enum(u8) {
    ping = 1,           // Heartbeat
    pong = 2,           // Răspuns ping
    block = 7,          // Propagare bloc
    tx = 8,             // Propagare TX
};
```

**În OPCODES.md:**
```markdown
| Cod (u8) | Nume | Descriere | Direcție |
|----------|------|-----------|----------|
| 1 | `ping` | Heartbeat + height exchange | Bidirecțional |
| 2 | `pong` | Răspuns ping | Bidirecțional |
| 7 | `block` | Propagare bloc complet | Bidirecțional |
| 8 | `tx` | Propagare tranzacție | Bidirecțional |
```

---

## 🔗 Link-uri utile

- [Codul sursă principal](../core/) - Toate fișierele Zig
- [Documentația tehnică](../docs/) - Documentație suplimentară
- [Teste](../test/) - Teste pentru verificarea constantelor

---

## 👥 Autori

- **OmniBus AI Collective** - Claude + Kimi + DeepSeek + Gemini
- **Maintainer:** Echipa OmniBus Core

---

## 📜 Licență

Acest document și scripturile asociate sunt licențiate sub MIT License.
Vezi [LICENSE](../LICENSE) pentru detalii.

---

> **Ultima actualizare:** 2026-03-31
> 
> **Versiune document:** 1.0.0
> 
> **Versiune scanner:** 1.0.0
