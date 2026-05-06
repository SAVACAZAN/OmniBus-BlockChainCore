# BlockChainCore — STATUS folder

**Read this folder first.** It is the single source of truth for *current state*
of the project, regenerated from the codebase by Python scripts in `tools/`.

Hand-edits will be overwritten — to update content, run the scripts.

## Files in this folder

| File | Purpose | Generator |
|---|---|---|
| `INFRASTRUCTURE.md` | VPS, SSH, ports, branches, build commands | `tools/bootstrap-context.py` |
| `STATUS.md` | Live TODO / DONE / BLOCKED extracted from all `.md` files | `tools/consolidate-status.py` |
| `INVENTORY.md` | Every `.md` in the repo classified KEEP/ARCHIVE/REVIEW | `tools/inventory-md.py` |
| `MASTER_RULES_PQ_OMNI.md` | **Hand-edited** canonical PQ-OMNI rules (NIST FIPS, prefixes, BIP-44 paths, derivation) | manual |
| `archiveREADME/` | Old `.md` files moved here (not deleted) + `INDEX.md` | `inventory-md.py --apply-archive` |

## Reading order for a new agent / session

1. `INFRASTRUCTURE.md` — where things live, how to deploy, SSH aliases, ports
2. `MASTER_RULES_PQ_OMNI.md` — PQ scheme/prefix/derivation canon (single source of truth)
3. `STATUS.md` — what's open, what's blocked, what's done
4. `INVENTORY.md` — if you need to dive into a specific older doc
5. Project root `CLAUDE.md` — coding conventions

## Refresh commands

Run from repo root (`1_CORE/BlockChainCore/`):

```bash
# Fast: local only (git, ssh config)
python tools/bootstrap-context.py

# Slower: also SSH to VPS for live state
python tools/bootstrap-context.py --query-vps omnibus-vps

# Status
python tools/consolidate-status.py

# Markdown inventory (preview only)
python tools/inventory-md.py

# Inventory + actually move ARCHIVE_* files into archiveREADME/
python tools/inventory-md.py --apply-archive

# All four in one go
python tools/bootstrap-context.py --query-vps omnibus-vps && \
python tools/consolidate-status.py && \
python tools/inventory-md.py
```

## Other audit tools (in `tools/`)

- `audit-pq-conventions.py` — checks PQ-OMNI prefix/scheme drift across the
  codebase. Run after multi-agent sessions touching PQ code.
  Output: `PQ_AUDIT_<date>.md` in repo root.

## Conventions

- All four scripts are stdlib-only (no pip install needed).
- Output files in this folder are **machine-generated** — diff before commit
  to spot real changes vs cosmetic regeneration noise.
- Archive operations are **non-destructive**: files move into `archiveREADME/`
  with a flat name (`subdir__file.md` → preserves origin in name) and an
  `INDEX.md` log records what moved and why. Restore by moving back and
  deleting the line in INDEX.md.
