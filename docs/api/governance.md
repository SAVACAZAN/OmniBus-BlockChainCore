# Module: `governance`

## Contents

- [Structs](#structs)
- [Constants](#constants)
- [Functions](#functions)

## Structs

### `VoteRecord`

O inregistrare de vot

*Line: 51*

### `GovernanceParams`

Parametrii guvernantei (configurabili ei insisi prin governance!)

*Line: 60*

### `Proposal`

O propunere de governance

*Line: 78*

### `GovernanceEngine`

Governance Engine

*Line: 144*

## Constants

| Name | Type | Value |
|------|------|-------|
| `ProposalType` | auto | `enum(u8) {` |
| `ProposalStatus` | auto | `enum(u8) {` |
| `Vote` | auto | `enum(u8) {` |
| `MAX_PROPOSALS` | auto | `usize = 256` |

## Functions

### `isVotingActive`

Verifica daca propunerea e in perioada de vot

```zig
pub fn isVotingActive(self: *const Proposal, current_block: u64) bool {
```

**Parameters:**

- `self`: `*const Proposal`
- `current_block`: `u64`

**Returns:** `bool`

*Line: 115*

---

### `tallyResult`

Calculeaza rezultatul final

```zig
pub fn tallyResult(self: *const Proposal, total_voting_power: u64, params: GovernanceParams) ProposalStatus {
```

**Parameters:**

- `self`: `*const Proposal`
- `total_voting_power`: `u64`
- `params`: `GovernanceParams`

**Returns:** `ProposalStatus`

*Line: 122*

---

### `init`

```zig
pub fn init(params: GovernanceParams) GovernanceEngine {
```

**Parameters:**

- `params`: `GovernanceParams`

**Returns:** `GovernanceEngine`

*Line: 150*

---

### `createProposal`

Creeaza o propunere noua

```zig
pub fn createProposal(self: *GovernanceEngine, proposer: [32]u8, ptype: ProposalType, title: []const u8, description: []const u8, deposit_sat: u64, current_block: u64) !u64 {
```

**Parameters:**

- `self`: `*GovernanceEngine`
- `proposer`: `[32]u8`
- `ptype`: `ProposalType`
- `title`: `[]const u8`
- `description`: `[]const u8`
- `deposit_sat`: `u64`
- `current_block`: `u64`

**Returns:** `!u64` (proposal ID)

**Errors:** `TooManyProposals`, `InsufficientDeposit`

*Line: 160*

---

### `vote`

Voteaza pe o propunere

```zig
pub fn vote(self: *GovernanceEngine, proposal_id: u64, voter_vote: Vote, voting_power: u64, current_block: u64) !void {
```

**Parameters:**

- `self`: `*GovernanceEngine`
- `proposal_id`: `u64`
- `voter_vote`: `Vote` (Yes, No, Abstain, NoWithVeto)
- `voting_power`: `u64`
- `current_block`: `u64`

**Returns:** `!void`

**Errors:** `ProposalNotFound`, `VotingNotActive`, `NoVotingPower`

*Line: 201*

---

### `finalize`

Finalizeaza o propunere dupa perioada de vot

```zig
pub fn finalize(self: *GovernanceEngine, proposal_id: u64, total_voting_power: u64, current_block: u64) !ProposalStatus {
```

**Parameters:**

- `self`: `*GovernanceEngine`
- `proposal_id`: `u64`
- `total_voting_power`: `u64`
- `current_block`: `u64`

**Returns:** `!ProposalStatus`

**Errors:** `ProposalNotFound`, `VotingNotEnded`

*Line: 223*

---

### `getProposal`

Get proposal by ID (const)

```zig
pub fn getProposal(self: *const GovernanceEngine, id: u64) ?*const Proposal {
```

**Parameters:**

- `self`: `*const GovernanceEngine`
- `id`: `u64`

**Returns:** `?*const Proposal`

*Line: 247*

---

