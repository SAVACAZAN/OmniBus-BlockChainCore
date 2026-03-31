# Module: `governance`

> On-chain governance — proposal creation, voting (for/against/abstain), quorum (33%), approval threshold (50%), veto threshold (33%), parameter updates.

**Source:** `core/governance.zig` | **Lines:** 393 | **Functions:** 4 | **Structs:** 4 | **Tests:** 10

---

## Contents

### Structs
- [`VoteRecord`](#voterecord) — O inregistrare de vot
- [`GovernanceParams`](#governanceparams) — Parametrii guvernantei (configurabili ei insisi prin governance!)
- [`Proposal`](#proposal) — O propunere de governance
- [`GovernanceEngine`](#governanceengine) — Governance Engine

### Constants
- [4 constants defined](#constants)

### Functions
- [`isVotingActive()`](#isvotingactive) — Verifica daca propunerea e in perioada de vot
- [`tallyResult()`](#tallyresult) — Calculeaza rezultatul final
- [`init()`](#init) — Initialize a new instance. Allocates required memory and sets default ...
- [`getProposal()`](#getproposal) — Get proposal by ID (const)

---

## Structs

### `VoteRecord`

O inregistrare de vot

| Field | Type | Description |
|-------|------|-------------|
| `voter_address` | `[32]u8` | Voter_address |
| `vote` | `Vote` | Vote |
| `voting_power` | `u64` | Voting_power |
| `block_height` | `u64` | Block_height |

*Defined at line 51*

---

### `GovernanceParams`

Parametrii guvernantei (configurabili ei insisi prin governance!)

| Field | Type | Description |
|-------|------|-------------|
| `deposit_period_blocks` | `u64` | Deposit_period_blocks |
| `voting_period_blocks` | `u64` | Voting_period_blocks |
| `min_deposit_sat` | `u64` | Min_deposit_sat |
| `quorum_pct` | `u8` | Quorum_pct |
| `threshold_pct` | `u8` | Threshold_pct |
| `veto_pct` | `u8` | Veto_pct |
| `fee_burn_pct` | `u8` | Fee_burn_pct |

*Defined at line 60*

---

### `Proposal`

O propunere de governance

| Field | Type | Description |
|-------|------|-------------|
| `id` | `u64` | Id |
| `proposer` | `[32]u8` | Proposer |
| `proposal_type` | `ProposalType` | Proposal_type |
| `title` | `[64]u8` | Title |
| `title_len` | `u8` | Title_len |
| `description` | `[256]u8` | Description |
| `desc_len` | `u16` | Desc_len |
| `param_name` | `[32]u8` | Param_name |
| `param_name_len` | `u8` | Param_name_len |
| `param_new_value` | `u64` | Param_new_value |
| `deposit_sat` | `u64` | Deposit_sat |
| `created_block` | `u64` | Created_block |
| `voting_start_block` | `u64` | Voting_start_block |
| `voting_end_block` | `u64` | Voting_end_block |
| `status` | `ProposalStatus` | Status |
| `votes_yes` | `u64` | Votes_yes |
| `votes_no` | `u64` | Votes_no |
| `votes_abstain` | `u64` | Votes_abstain |
| `votes_veto` | `u64` | Votes_veto |
| `total_voted_power` | `u64` | Total_voted_power |

*Defined at line 78*

---

### `GovernanceEngine`

Governance Engine

| Field | Type | Description |
|-------|------|-------------|
| `params` | `GovernanceParams` | Params |
| `next_proposal_id` | `u64` | Next_proposal_id |
| `proposals` | `[MAX_PROPOSALS]Proposal` | Proposals |
| `proposal_count` | `usize` | Proposal_count |
| `self` | `*GovernanceEngine` | Self |
| `proposer` | `[32]u8` | Proposer |
| `ptype` | `ProposalType` | Ptype |
| `title` | `[]const u8` | Title |
| `description` | `[]const u8` | Description |
| `deposit_sat` | `u64` | Deposit_sat |
| `current_block` | `u64` | Current_block |

*Defined at line 144*

---

## Constants

| Name | Value | Description |
|------|-------|-------------|
| `ProposalType` | `enum(u8) {` | Proposal type |
| `ProposalStatus` | `enum(u8) {` | Proposal status |
| `Vote` | `enum(u8) {` | Vote |
| `MAX_PROPOSALS` | `usize = 256` | M a x_ p r o p o s a l s |

---

## Functions

### `isVotingActive()`

Verifica daca propunerea e in perioada de vot

```zig
pub fn isVotingActive(self: *const Proposal, current_block: u64) bool {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*const Proposal` | The instance |
| `current_block` | `u64` | Current_block |

**Returns:** `bool`

*Defined at line 115*

---

### `tallyResult()`

Calculeaza rezultatul final

```zig
pub fn tallyResult(self: *const Proposal, total_voting_power: u64, params: GovernanceParams) ProposalStatus {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*const Proposal` | The instance |
| `total_voting_power` | `u64` | Total_voting_power |
| `params` | `GovernanceParams` | Params |

**Returns:** `ProposalStatus`

*Defined at line 122*

---

### `init()`

Initialize a new instance. Allocates required memory and sets default values.

```zig
pub fn init(params: GovernanceParams) GovernanceEngine {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `params` | `GovernanceParams` | Params |

**Returns:** `GovernanceEngine`

*Defined at line 150*

---

### `getProposal()`

Get proposal by ID (const)

```zig
pub fn getProposal(self: *const GovernanceEngine, id: u64) ?*const Proposal {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*const GovernanceEngine` | The instance |
| `id` | `u64` | Id |

**Returns:** `?*const Proposal`

*Defined at line 247*

---


---

*Generated by OmniBus Doc Generator v2.0 — 2026-03-31 11:17*
