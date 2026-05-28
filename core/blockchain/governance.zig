// On-chain governance + validator-set bootstrap helpers for the Blockchain
// struct.
//
// Extracted from blockchain.zig as part of the file-size cleanup.
// Pattern: free functions taking `*Blockchain`. Thin delegating method shims
// stay on the struct in blockchain.zig so external callers keep working
// unchanged.

const std = @import("std");
const blockchain_mod = @import("../blockchain.zig");
const validator_mod = @import("../validator_registry.zig");
const main_mod = @import("../main.zig");
const consensus_params = @import("consensus_params.zig");

const Blockchain = blockchain_mod.Blockchain;
const Validator  = blockchain_mod.Validator;

const MAX_DIFFICULTY = consensus_params.MAX_DIFFICULTY;

const array_list = std.array_list;

/// Rebuild `self.validator_set` from the persisted chain. Used at startup so
/// the validator slot-leader rotation survives restarts even though the set
/// itself isn't serialised (it's a deterministic projection of the chain).
pub fn rebuildValidatorSetFromChain(self: *Blockchain) !void {
    var seen = std.StringHashMap(u64).init(self.allocator);
    defer seen.deinit();

    // Walk chain, find unique miner per first-seen height. Skip empty
    // miner_address (genesis, plus pre-V3 peer-blocks that lost the
    // address through the old wire format).
    for (self.chain.items, 0..) |blk, height| {
        if (blk.miner_address.len == 0) continue;
        if (seen.contains(blk.miner_address)) continue;
        try seen.put(blk.miner_address, height);
    }

    // Build new set, filtering by balance ≥ MIN_VALIDATOR_BALANCE.
    var new_set = array_list.Managed(Validator).init(self.allocator);
    errdefer new_set.deinit();

    var it = seen.iterator();
    while (it.next()) |entry| {
        const balance = self.getAddressBalance(entry.key_ptr.*);
        if (balance < validator_mod.MIN_VALIDATOR_BALANCE) continue;
        try new_set.append(.{
            .address = entry.key_ptr.*,
            .weight = 1,
            .since_height = entry.value_ptr.*,
        });
    }

    // Sort by since_height ascending (then address as tiebreaker) for
    // identical ordering on every node. Without this, HashMap iteration
    // order would vary and `leaderForSlot` could diverge.
    std.mem.sort(Validator, new_set.items, {}, struct {
        fn lt(_: void, a: Validator, b: Validator) bool {
            if (a.since_height != b.since_height) return a.since_height < b.since_height;
            return std.mem.lessThan(u8, a.address, b.address);
        }
    }.lt);

    // Swap atomically — drop old, install new.
    self.validator_set.deinit();
    self.validator_set = new_set;
}

/// Apply a passed governance proposal: mutate the consensus parameters,
/// mark the proposal executed in the registry, and broadcast a WS event.
pub fn executeProposal(self: *Blockchain, proposal_id: u64, current_block: u64) !void {
    const proposal = self.gov_registry.getProposal(proposal_id) orelse
        return error.ProposalNotFound;
    if (proposal.status != .passed) return error.ProposalNotPassed;
    if (proposal.executed) return error.AlreadyExecuted;

    // Apply the action. Unknown action kinds (forward-compat from a future
    // node version) are treated as no-op so the chain doesn't fork on the
    // execution itself — the proposal is still marked executed.
    switch (proposal.action.kind) {
        .none => {},
        .set_block_reward => self.consensus_params.block_reward_sat = proposal.action.u64_value,
        .set_min_difficulty => self.consensus_params.min_difficulty =
            @intCast(@min(proposal.action.u64_value, @as(u64, MAX_DIFFICULTY))),
        .set_block_size_limit => self.consensus_params.block_size_limit = proposal.action.u64_value,
        .set_pq_signature_max => self.consensus_params.pq_signature_max = proposal.action.u64_value,
        .set_dns_signed_required => self.consensus_params.dns_signed_required = proposal.action.bool_value,
        .set_validator_quorum_min => self.consensus_params.validator_quorum_min =
            @intCast(@min(proposal.action.u64_value, @as(u64, std.math.maxInt(u32)))),
        .set_route_fees_to_miner => self.consensus_params.route_fees_to_miner = proposal.action.bool_value,
        _ => {
            // Forward-compat: unknown action kind. Mark executed anyway so
            // proposals aren't re-tried every block in a stuck loop.
        },
    }

    try self.gov_registry.markExecuted(proposal_id, current_block);

    // Push WS event so dashboards / explorers see the protocol parameter
    // change in real time. Best-effort: failure to format / broadcast must
    // not roll back the executed mutation (it's already on chain via the
    // governance registry).
    if (main_mod.g_ws_srv) |ws| {
        var buf: [512]u8 = undefined;
        const json = std.fmt.bufPrint(&buf,
            "{{\"type\":\"gov_executed\",\"proposal_id\":{d}," ++
            "\"action_kind\":{d},\"u64_value\":{d},\"bool_value\":{}," ++
            "\"executed_block\":{d}}}",
            .{
                proposal_id,
                @intFromEnum(proposal.action.kind),
                proposal.action.u64_value,
                proposal.action.bool_value,
                current_block,
            }) catch null;
        if (json) |j| ws.broadcast(j);
    }
}

/// Auto-execute every passed-but-unexecuted proposal at the current block
/// height. Called from applyBlock once per block. Safe under self.mutex
/// because executeProposal only mutates consensus_params + the gov registry
/// (both already serialised by applyBlock's caller).
pub fn autoExecutePassedProposals(self: *Blockchain, current_block: u64) void {
    var ids: [16]u64 = undefined;
    const n = self.gov_registry.collectPassedUnexecuted(&ids);
    for (ids[0..n]) |pid| {
        executeProposal(self, pid, current_block) catch |err| {
            std.debug.print("[GOV-EXEC] proposal {d} failed: {}\n", .{ pid, err });
        };
    }
}
