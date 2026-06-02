# VPS Testnet Diagnostic — 2026-05-13

## Stare actuală

**Server**: vm2111 (38.143.19.97), Ubuntu 22.04, uptime 27 zile.
**RAM**: 957MB total, 86MB free (TIGHT — 89% folosit).
**Disk**: /dev/sda1 20GB, 78% folosit (4.3GB free).

### Servicii systemd
| Serviciu | Status | RPC | Note |
|----------|--------|-----|------|
| omnibus-mainnet | running | ✅ block 21241 | seed, OK |
| omnibus-mainnet-miner | running | — | OK |
| omnibus-testnet | running | ❌ Connection reset | **BLOCAT** |
| omnibus-oracle | running | ❌ port 8335 no reply | mort silent |
| omnibus-vite | running | — | frontend OK |

## Cauza root — testnet RPC blocat

### Simptome
1. TCP socket 18332 acceptă conexiunea, apoi **"Connection reset by peer"** imediat
2. **9 conexiuni RPC ESTAB de la 127.0.0.1** stuck — handle-uri nu se eliberează
3. **MAX_CONCURRENT=8** în `rpc_server.zig:602` → orice conexiune nouă peste 8 e dropped (linia 612)
4. **Main thread blocat** în `wait_on_page_bit_common` (I/O pe disk/mmap)
5. Process activ (321 MB RSS, 20 threads), nu crashed — dar **hung**

### Pattern de crash istoric
SIGABRT / SEGV recurrent **fix la ~3h interval**:
- 10 mai: 17:37, 19:41, 19:49, 20:02, 23:06
- 11 mai: 04:56 (după 3h25m)
- 12 mai: 15:17 (timeout SIGKILL), 16:32
- 13 mai: 03:47 (după 2h43m)

### Ipoteză cauză root (foarte probabilă)
**Agent runtime fragmentation**: testnet rulează cu `--agent-config /root/omnibus-blockchain/examples/agent.json` (2+ agenți tick la 5s/10s). Fiecare tick:
- Alocă pe GPA (decision, oracle snapshot, log strings)
- Auto-claim-faucet generează TX-uri
- TX-urile încarcă mempool, mempool încarcă chain.dat persistence

După ~2-3h × ~720-2160 tick-uri × 16+ allocări/tick → fragmentare GPA → SEGV/ABRT silent (stderr nu e capturat în journalctl).

### Evidență suplimentară
- `chain.dat` (40MB) modificat acum 1 min → mining OK, doar RPC blocat
- `chain.dat.bak` (30MB) de la 03:47 → ultimul crash a forțat backup
- Agent config: `tick_ms: 5000` (alpha) + `tick_ms: 10000` (beta) + auto_claim_faucet
- Memorie globală RAM doar 86MB free → fragmentarea GPA agravată

## Probleme conexe descoperite

1. **Oracle daemon mort silent** (port 8335 nu răspunde). Service "active running" dar nu acceptă conexiuni.
2. **stderr nu capturat** — `journalctl -u omnibus-testnet` arată doar systemd events, nu Zig panic-uri / stack traces. Configurația systemd lipsește `StandardError=journal+console` proper.
3. **Core dumps disabled** — `/var/lib/systemd/coredump/` gol (Mar 2025). `ulimit -c` probabil 0.
4. **Backup nu mai există** — `chain.dat.bak` se rescrie la fiecare crash, pierdem istoricul.

## Recomandări (în ordine de impact)

### 🔴 IMMEDIATE (prevenire crash + recovery)

1. **Disable agent runtime pe testnet temporar** (5 min)
   ```bash
   ssh omnibus-vps "systemctl edit omnibus-testnet"  # remove --agent-config
   systemctl restart omnibus-testnet
   ```
   Asta verifică ipoteza root cause. Dacă testnet rulează stabil 24h fără agenți → confirmat.

2. **Enable core dumps + stderr capture** (10 min)
   - În systemd unit: `LimitCORE=infinity`, `StandardError=journal`
   - `coredumpctl install` pentru capture automat
   - Vom avea stack traces real pentru următorul crash

3. **Stop oracle daemon dacă nu e folosit** (1 min) sau **restart-l** ca să recapete portul

### 🟡 SHORT-TERM (1-2h muncă)

4. **Aplică fix-urile DEX din audit-ul de azi** (grid tick + auto-HTLC + treasury) — ele simplifică logica și reduc allocările
5. **Adaugă RPC `getMemStats`** care raportează GPA usage → monitorizare proactivă
6. **Per-request arena allocator pe RPC hot path** (P4-2 amânat) — direct elimină fragmentarea principală
7. **Configurează LimitSTACK=infinity** (alread aplicat conform memorie `project_omnibus_stack_limit_fix`)

### 🟢 MEDIUM-TERM (build mai stabil)

8. **Build ReleaseSafe pe VPS** (nu Debug) — confirmat în memorie că Debug crashează pe Linux
9. **Promovează zig 0.15.2 panic info la systemd journal** prin `--panic-handler` custom în Zig
10. **Adaugă healthcheck systemd cu `ExecStartPost`** care testează RPC după 30s startup; dacă pică, log explicit

## Concluzie

**Testnet-ul NU e crashed acum, e HUNG pe RPC din cauză că:**
- 8 conexiuni stuck în MAX_CONCURRENT (limit hard-coded)
- Main thread blocat în I/O (disk swap probabil — RAM tight)
- Agent runtime încărca constant GPA → fragmentare → crash periodic (la ~3h)

**Quick win**: restart testnet **FĂRĂ** agent.json → confirmă cauza root în 24h.

**Confirmare audit DEX**: cele 3 blocaje DEX descoperite (grid tick, auto-HTLC, treasury) **nu sunt** cauza directă a blocajului VPS. Cauza e **agent runtime** care produce traffic intens pe un nod cu RAM tight.

**Audit-ul DEX rămâne valid** ca lucrarea următoare, dar **înainte** trebuie să stabilizăm VPS-ul (etapa următoare = aplicarea recomandărilor IMMEDIATE 1-3 + verificare 24h).
