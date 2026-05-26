# Wallet, chei și semnare prin CLI

> **Scopul acestui document:** îți arată cum poți face TOT ce face site-ul
> (generare wallet, vizualizare balanță/stake/orders, trade real, grid,
> HTLC, etc.) **doar din terminal**, fără dependență de frontend.
>
> Frontend-ul OmniBus e doar un buton vizual peste exact aceleași
> endpoint-uri RPC. Dacă pică Vite-ul, chain-ul nu observă; tu deschizi
> terminalul și continui.

---

## 1. Cum se generează un wallet (offline)

Chain-ul **derivează** chei din mnemonic dar nu le **generează** (CLI-ul Zig
nu include wordlist-ul BIP-39 ca să rămână binary-ul mic). Ai trei opțiuni:

### Opțiunea A — Frontend pe un PC offline (recomandat pentru oameni)

1. Bootezi un laptop offline (deconectează WiFi, scoate cablul).
2. Pornești frontend-ul local (`npm run dev` în `frontend/`).
3. Mergi la pagina **Onboarding** → alege **12 sau 24 cuvinte** → opțional
   adaugă **passphrase** ("25th word").
4. Scrii cuvintele pe hârtie. Scrii passphrase pe altă hârtie, separată.
5. Re-tipezi 3 cuvinte aleatoare pentru confirmare.
6. Frontend-ul îți arată adresa OMNI principală + cele 4 PQ + cele 24
   multichain (BTC/ETH/SOL/etc).

### Opțiunea B — Python SDK (pentru scripturi)

```python
from mnemonic import Mnemonic
m = Mnemonic("english").generate(strength=256)  # 24 cuvinte (256 biți)
# sau strength=128 pentru 12 cuvinte
print(m)
```

### Opțiunea C — orice tool BIP-39 offline standard

[Ian Coleman BIP-39 Tool](https://iancoleman.io/bip39/) descărcat ca HTML
și rulat offline. Hardware wallets (Ledger, Trezor, ColdCard). Toate
produc mnemonic compatibil.

> ⚠️ **Nu genera mnemonic-uri pe site-uri online** dacă vrei să-ți păstrezi
> banii. Tot ce intră în browserul tău poate fi citit de extensii.

---

## 2. BIP-39 passphrase ("25th word") — protecție în plus

Passphrase-ul este o parolă opțională care se amestecă în derivarea
seed-ului. **Același mnemonic + passphrase diferit = wallet complet
diferit.**

### De ce e util:

- **Plausible deniability** — dacă cineva te forțează să dai cele 12
  cuvinte, le dai pe cele fără passphrase. Ei văd un wallet decoy (gol sau
  cu puțin OMNI). Wallet-ul real e ascuns sub passphrase.
- **Două puncte de eșec independente** — hârtia cu mnemonic într-un seif,
  hârtia cu passphrase în alt seif (sau în cap). Nicio hârtie singură nu
  deblochează nimic.
- **Compatibilitate hardware wallet** — Ledger/Trezor folosesc același
  mecanism BIP-39 §8.

### Important:

- Passphrase **NU se poate recupera** dacă o uiți — wallet-ul de sub ea
  e pierdut definitiv. Tratează-l ca pe mnemonic.
- Empty passphrase (`""`) = comportament standard, identic cu mnemonic
  fără passphrase.

---

## 3. CLI — patru surse de cheie pentru semnare

Orice comandă de scriere (`exchange-place`, `htlc-init`, `send`, etc.)
acceptă cheia din una din 4 surse, în ordinea de prioritate:

### Sursă 1: `--privkey <hex>` (cea mai izolată)

```bash
omnibus-cli exchange-place ob1q...xlvl OMNI/USDC sell 520000 10000000000 \
  --privkey c7c012d575c6c7ce0c71dc1e15744b23b7cd39d588e96b6da9b714b10df0370a \
  --yes
```

Cheia raw 32-byte hex. Nu se derivează nimic. Pierderea acestei chei
afectează **doar acea adresă**, NU întregul seed.

### Sursă 2: `OMNIBUS_PRIVKEY` env var

```bash
export OMNIBUS_PRIVKEY="c7c012d575c6c7ce0c71dc1e15744b23b7cd39d588e96b6da9b714b10df0370a"
omnibus-cli exchange-place ob1q...xlvl OMNI/USDC sell 520000 10000000000 --yes
```

Util pentru systemd/Docker — cheia nu apare în `ps`/shell history.

### Sursă 3: `--keyfile <path>`

```bash
echo "c7c012d575c6c7ce0c71dc1e15744b23b7cd39d588e96b6da9b714b10df0370a" > /etc/omnibus/key-0.hex
chmod 600 /etc/omnibus/key-0.hex

omnibus-cli exchange-place ob1q...xlvl OMNI/USDC sell 520000 10000000000 \
  --keyfile /etc/omnibus/key-0.hex --yes
```

Cheia stă pe disk cu permisiuni `0600` (doar tu o citești). Recomandat
pentru bot-uri lung-running.

### Sursă 4: `--mnemonic` + opțional `--key-index N` și `--passphrase`

```bash
# Wallet principal (index 0):
omnibus-cli exchange-place ob1qabc... OMNI/USDC sell 520000 10000000000 \
  --mnemonic "abandon abandon ... about" --yes

# Child #17 din același seed:
omnibus-cli exchange-place ob1qdef... OMNI/USDC buy 510000 5000000000 \
  --mnemonic "abandon abandon ... about" --key-index 17 --yes

# Cu passphrase ("25th word"):
omnibus-cli exchange-place ob1qghi... OMNI/USDC sell 520000 10000000000 \
  --mnemonic "abandon abandon ... about" --passphrase "TigrulNeagra2026!" --yes
```

Sau prin env:

```bash
export OMNIBUS_MNEMONIC="abandon abandon ... about"
export OMNIBUS_PASSPHRASE="TigrulNeagra2026!"
omnibus-cli exchange-place ... --key-index 17 --yes
```

---

## 4. Workflow "1 mnemonic → 1000 chei"

Setup recomandat pentru cineva care vrea separare maximă:

### Pasul 1: Generează seed-ul OFFLINE

Pe un laptop fără internet, alegi 24 cuvinte + passphrase. Scrii pe hârtie.

### Pasul 2: Derivă cât de multe chei vrei (tot OFFLINE)

```bash
# Vezi adresele primelor 100 chei (offline, fără RPC):
omnibus-cli wallet-list 100 \
  --mnemonic "abandon abandon ... about" \
  --passphrase "TigrulNeagra2026!"

# Outpută:
#   #   0  m/44'/777'/0'/0/0     ob1qw6zh...xlvl
#   #   1  m/44'/777'/0'/0/1     ob1qew57...855m
#   ...

# Derivă privkey-ul pentru o cheie specifică:
omnibus-cli derive-key 17 \
  --mnemonic "abandon abandon ... about" \
  --passphrase "TigrulNeagra2026!"
```

### Pasul 3: Salvează DOAR privkey-urile pe servere online

Pe fiecare server / bot pui DOAR cheia copilă de care are nevoie:

```bash
# Server bot-trading-A:
echo "<privkey #17>" > /etc/omnibus/key-17.hex && chmod 600 /etc/omnibus/key-17.hex

# Server bot-trading-B:
echo "<privkey #42>" > /etc/omnibus/key-42.hex && chmod 600 /etc/omnibus/key-42.hex

# Server faucet:
echo "<privkey #7>" > /etc/omnibus/key-7.hex && chmod 600 /etc/omnibus/key-7.hex
```

### Pasul 4: Mnemonicul rămâne în seif

Niciun server online nu vede mnemonicul după ce ai derivat cheile copil.

### Avantaje de securitate:

| Scenariu | Fără separare | Cu setup-ul de mai sus |
|----------|---------------|------------------------|
| Hack server bot-A | toți banii pierduți | doar cheia #17 compromisă |
| Hack server bot-B | toți banii pierduți | doar cheia #42 compromisă |
| Furt mnemonic | toate adresele pierdute | doar wallet decoy (passphrase rămâne secret) |
| Uiti passphrase | wallet pierdut | wallet pierdut (= aceeași durere ca pierderea mnemonic) |

> 💡 **BIP-32 e one-way:** din `privkey #17` NU se poate deriva înapoi
> seed-ul. Compromiterea cheii copil NU compromite niciodată master-ul.

---

## 5. Operațiuni reale prin CLI

Toate funcționează fără frontend, atâta timp cât nodul OmniBus rulează:

### 5.1 Vizualizare (read-only, fără semnătură)

```bash
# Balanță atomică (wallet + staked + in_orders + available + locks):
omnibus-cli wallet-summary ob1qw6zh...xlvl

# Toate perechile exchange:
omnibus-cli exchange-pairs

# Orderbook OMNI/USDC:
omnibus-cli exchange-orderbook 0

# Trade-urile recente:
omnibus-cli exchange-trades 0 50

# Ordere active ale tale:
omnibus-cli exchange-orders ob1qw6zh...xlvl

# Oracle prețuri (3 surse externe):
omnibus-cli oracle-prices

# Block height + chain health:
omnibus-cli health
```

### 5.2 Trade real (semnat automat)

```bash
# Plasezi un sell — nodul lockuiește automat OMNI din wallet:
omnibus-cli exchange-place ob1qw6zh...xlvl OMNI/USDC sell 520000 10000000000 \
  --keyfile /etc/omnibus/key-0.hex --yes

# Verifici că lock-ul s-a aplicat:
omnibus-cli wallet-summary ob1qw6zh...xlvl
# →  In orders : 10.00 OMNI    (lockat automat)
# →  Available : ↓ cu 10 OMNI

# Anulezi → lock-ul se eliberează automat:
omnibus-cli exchange-cancel ob1qw6zh...xlvl <order_id> \
  --keyfile /etc/omnibus/key-0.hex --yes
```

### 5.3 Grid trading (market making automat)

```bash
omnibus-cli grid-create ob1q...xlvl OMNI/USDC \
  500000 600000 10 100 50000 \
  --keyfile key-0.hex --yes
# Argumente: price_low price_high levels total_base total_quote
```

### 5.4 HTLC cross-chain swap

```bash
omnibus-cli htlc-init ob1q...xlvl <recipient> <amount> <secret_hash> <lock_blocks> \
  --keyfile key-0.hex --yes

omnibus-cli htlc-claim ob1q...xlvl <swap_id> <preimage> \
  --keyfile key-0.hex --yes
```

---

## 6. Ce face NODUL automat (NU CLI)

Pentru fiecare ordin trimis, nodul (Zig binary):

1. Verifică **semnătura ECDSA** pe mesajul canonical `EXCHANGE_ORDER_V1\n...`
2. Verifică că **pubkey-ul derivă exact adresa** din ordin (anti-spoofing)
3. Verifică **nonce-ul** > ultimul nonce folosit (anti-replay)
4. Pentru sell pe OMNI: calculează `available = balance - staked -
   reserved_in_other_orders` și **respinge** dacă nu ajunge
5. Verifică **oracle price-band** (~5% deviere maximă)
6. Verifică **KYC tier cap** (doar mainnet)
7. Inserează ordinul în engine + auto-fill cu matching, dacă există match
8. La fill: generează **preimage** + **HTLC** + execută settlement
9. La cancel/fill: **eliberează lock-ul** automat

Tu nu faci nimic din toate astea — CLI doar trimite ordinul semnat, nodul
face restul.

---

## 7. Cazuri de eșec uzuale + cum le repari

| Eroare | Cauză | Fix |
|--------|-------|-----|
| `NoMnemonic` | nu ai dat nici `--mnemonic`, nici `--privkey`, nici `--keyfile`, nici env vars | adaugă una din ele |
| `BadMnemonic` | cuvinte tipiate greșit / checksum invalid | verifică ortografia |
| `BadPrivkey` | hex-ul are alt număr de bytes decât 32 sau caractere non-hex | verifică să ai exact 64 caractere hex |
| `BadKeyfile` | fișierul nu există / chmod greșit / conținut malformat | verifică `ls -la` + conținut |
| `Insufficient available balance for sell` | încerci să vinzi mai mult decât `available` (după ce scazi stake + alte orders) | rulează `wallet-summary` să vezi available real |
| `Signature verify failed` | mnemonic / passphrase / key-index NU corespund cu adresa pasată ca trader | derivă cheia corectă cu `derive-key` |
| `Nonce already used (replay rejected)` | nonce-ul a fost folosit deja (CLI folosește `time.milliTimestamp` ca nonce) | așteaptă 1ms și retrimite |
| `oracle_band_exceeded` | preț prea departe de oracle (>5%) | folosește un preț în band, sau așteaptă oracle update |

---

## 8. Variabile de mediu — lista completă

```bash
# Cheia de semnare (alege UNA):
OMNIBUS_PRIVKEY=<hex>           # cheie raw 32-byte hex
OMNIBUS_MNEMONIC=<words>        # mnemonic 12 sau 24 cuvinte
OMNIBUS_PASSPHRASE=<text>       # BIP-39 §8 (opțional)

# Conectare la nod:
# Comandă: --endpoint http://host:port  sau:
OMNIBUS_RPC_URL=http://omnibusblockchain.cc:8443/api-mainnet
OMNIBUS_RPC_TOKEN=<bearer-token>  # doar pentru noduri protejate
```

---

## 9. Rezumat: chain ≠ frontend

```
┌──────────────────────────────────────────┐
│   NOD OMNIBUS (Zig binary)               │   ← state real, persistent
│   - block-uri, mempool, mining           │     în omnibus-chain.dat
│   - stake_amounts, balanțe               │
│   - exchange matching engine             │
└──────────┬───────────────────────────────┘
           │  JSON-RPC port 8332
   ┌───────┴────────┬──────────┬─────────┐
   ▼                ▼          ▼         ▼
Frontend Vite   CLI Zig    Python SDK  curl
(pică = nimic   (mereu     (bots)      (orice
afectat)        merge)                  client HTTP)
```

**Frontend** = doar interfață vizuală.
**Nod** = sursa adevărului. Logica completă, persistent state.
**CLI / SDK / curl** = clienti egali ca putere cu site-ul.

Dacă vezi datele într-un loc, le poți vedea din toate celelalte.
Dacă faci o tranzacție dintr-un loc, e vizibilă din toate celelalte.
