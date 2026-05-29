// net_processing — message dispatch + sync/reorg application.
//
// Extracted from core/p2p.zig. Provides free functions over `*P2PNode`:
//   - dispatchMessage              (giant switch routing peer messages)
//   - gossipAddTxToMempool         (parse JSON TX and add to mempool)
//   - chainConfigFromMagic         (4-byte magic → ChainConfig)
//   - truncateChainTo              (drop blocks + recalc state for reorg)
//   - blockHashesMatch             (compare peer block hash to local)
//   - applyBlocksFromPeer          (apply BlockHeader[] with reorg logic)
//
// Pattern matches transport.zig: file-level free functions, thin delegate
// shim stays on P2PNode for the pub entry points (dispatchMessage).

const std = @import("std");

const p2p_mod          = @import("../p2p.zig");
const wire             = @import("wire.zig");
const peer_mod         = @import("peer.zig");
const gossip_mod       = @import("gossip.zig");
const discovery_mod    = @import("discovery.zig");
const sync_coord_mod   = @import("sync_coord.zig");

const blockchain_mod      = @import("../blockchain.zig");
const block_mod           = @import("../block.zig");
const sync_mod            = @import("../sync.zig");
const light_client_mod    = @import("../light_client.zig");
const chain_config_mod    = @import("../chain_config.zig");
const validator_mod       = @import("../validator_registry.zig");
const oracle_policy_mod   = @import("../oracle_policy.zig");
const oracle_types_mod    = @import("../oracle_types.zig");
const ws_exchange_feed_mod = @import("../ws_exchange_feed.zig");
const main_mod            = @import("../main.zig");

const P2PNode        = p2p_mod.P2PNode;
const PeerConnection = p2p_mod.PeerConnection;
const Blockchain     = blockchain_mod.Blockchain;
const Block          = block_mod.Block;
const MessageType    = p2p_mod.MessageType;

const MsgHello         = p2p_mod.MsgHello;
const MsgWelcome       = p2p_mod.MsgWelcome;
const MsgStable        = p2p_mod.MsgStable;
const MsgPing          = p2p_mod.MsgPing;
const MsgBlockAnnounce = p2p_mod.MsgBlockAnnounce;
const GossipTxPayload  = p2p_mod.GossipTxPayload;

const P2P_VERSION              = p2p_mod.P2P_VERSION;
const IBD_GAP_TRIGGER          = p2p_mod.IBD_GAP_TRIGGER;
const IBD_TOLERANCE            = p2p_mod.IBD_TOLERANCE;
const SPV_HEADER_SIZE          = p2p_mod.SPV_HEADER_SIZE;
const SPV_MAX_HEADERS_PER_MSG  = p2p_mod.SPV_MAX_HEADERS_PER_MSG;

const decodePeerList     = p2p_mod.decodePeerList;
const decodeGetHeaders   = p2p_mod.decodeGetHeaders;
const serializeSpvHeader = p2p_mod.serializeSpvHeader;
const decodeHeadersBatch = p2p_mod.decodeHeadersBatch;
const decodeBloomFilter  = p2p_mod.decodeBloomFilter;

// ─── Reorg limit ────────────────────────────────────────────────────────────

/// Maximum chain reorg depth in a single sync round. If peer chain diverges
/// deeper than this, we trigger a FULL_RESYNC (truncate to genesis + apply
/// peer chain). Bitcoin uses ~100; we use 1000 because 1s blocks accumulate
/// fast on testnet. Above this, we trust the longer-chain rule fully.
pub const REORG_DEPTH_LIMIT: u64 = 1000;

// ─── Gossip TX → mempool ─────────────────────────────────────────────────────

/// Parse a JSON-encoded Transaction from gossip and add it to the blockchain mempool.
/// Uses arena allocation scoped to this call — no long-lived allocations.
pub fn gossipAddTxToMempool(bc: *Blockchain, tx_json: []const u8, allocator: std.mem.Allocator) !void {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const parsed = try std.json.parseFromSlice(std.json.Value, a, tx_json, .{});
    const obj = switch (parsed.value) {
        .object => |o| o,
        else => return error.InvalidTxJson,
    };

    const get_str = struct {
        fn f(map: std.json.ObjectMap, key: []const u8) []const u8 {
            if (map.get(key)) |v| {
                return switch (v) { .string => |s| s, else => "" };
            }
            return "";
        }
    }.f;
    const get_u64 = struct {
        fn f(map: std.json.ObjectMap, key: []const u8) u64 {
            if (map.get(key)) |v| {
                return switch (v) {
                    .integer => |i| if (i >= 0) @intCast(i) else 0,
                    .float   => |f2| @intFromFloat(@max(0, f2)),
                    else => 0,
                };
            }
            return 0;
        }
    }.f;

    const from = get_str(obj, "from_address");
    const to   = get_str(obj, "to_address");
    if (from.len == 0 or to.len == 0) return error.MissingTxFields;

    // Dupe strings into arena so they outlive the parsed value
    const tx = blockchain_mod.Transaction{
        .id           = @intCast(get_u64(obj, "id")),
        .from_address = try a.dupe(u8, from),
        .to_address   = try a.dupe(u8, to),
        .amount       = get_u64(obj, "amount"),
        .fee          = get_u64(obj, "fee"),
        .timestamp    = @intCast(get_u64(obj, "timestamp")),
        .nonce        = get_u64(obj, "nonce"),
        .signature    = try a.dupe(u8, get_str(obj, "signature")),
        .hash         = try a.dupe(u8, get_str(obj, "hash")),
        .op_return    = try a.dupe(u8, get_str(obj, "op_return")),
    };

    // addTransaction acquires bc.mutex internally
    try bc.addTransaction(tx);
}

// ─── Reorg helpers ──────────────────────────────────────────────────────────

/// Pick the ChainConfig that matches a 4-byte network magic, so we can
/// look up the right checkpoint list during reorg. Returns null if the
/// magic doesn't match any known chain (defensive — caller skips
/// checkpoint enforcement and relies on work alone).
pub fn chainConfigFromMagic(magic: [4]u8) ?chain_config_mod.ChainConfig {
    const ChainConfig = chain_config_mod.ChainConfig;
    const M = chain_config_mod.NetworkMagic;
    if (std.mem.eql(u8, &magic, &M.MAINNET.bytes)) return ChainConfig.mainnet();
    if (std.mem.eql(u8, &magic, &M.TESTNET.bytes)) return ChainConfig.testnet();
    if (std.mem.eql(u8, &magic, &M.REGTEST.bytes)) return ChainConfig.regtest();
    return null;
}

pub fn truncateChainTo(bc: *Blockchain, allocator: std.mem.Allocator, keep_height: u64) void {
    const target: usize = @intCast(keep_height);
    if (target >= bc.chain.items.len) return;
    std.debug.print("[REORG] Truncating local chain {d} -> {d} (dropping {d} blocks)\n",
        .{ bc.chain.items.len, target, bc.chain.items.len - target });
    // Free heap allocations of dropped blocks first.
    var i: usize = target;
    while (i < bc.chain.items.len) : (i += 1) {
        var blk = &bc.chain.items[i];
        blk.transactions.deinit();
        if (i > 0 and blk.hash.len == 64) {
            allocator.free(blk.hash);
        }
        if (blk.miner_heap and blk.miner_address.len > 0) {
            allocator.free(blk.miner_address);
        }
    }
    bc.chain.items.len = target;

    // Rebuild balances/nonces from the remaining chain so HashMap entries
    // referring to freed address keys are gone. Without this, next mining
    // try → segfault (real bug observed 2026-04-26).
    bc.recalculateFromHeight(target) catch |err| {
        std.debug.print("[REORG] recalculateFromHeight failed: {} — node state may be inconsistent, restart recommended\n", .{err});
    };
}

/// Compare a peer-provided block hash (from header.merkle_root field which
/// the wire protocol overloads to carry the block hash bytes) against our
/// local block at `height`. Returns true if they match (same chain) or
/// false if they diverge.
pub fn blockHashesMatch(bc: *const Blockchain, height: u64, peer_block_hash: [32]u8) bool {
    const idx: usize = @intCast(height);
    if (idx >= bc.chain.items.len) return false;
    const local_hex = bc.chain.items[idx].hash;
    if (local_hex.len < 64) return false;
    // Wire format (post 2026-04-26): merkle_root is 32 RAW BYTES (full
    // SHA-256 digest). We compare against local hex by decoding 64 hex
    // chars into 32 bytes and matching all of them.
    for (0..32) |i| {
        const hi = std.fmt.charToDigit(local_hex[i * 2], 16) catch return false;
        const lo = std.fmt.charToDigit(local_hex[i * 2 + 1], 16) catch return false;
        const local_byte: u8 = (@as(u8, hi) << 4) | @as(u8, lo);
        if (local_byte != peer_block_hash[i]) return false;
    }
    return true;
}

/// Aplica o lista de BlockHeader primite de la peer in blockchain-ul local.
/// Blocurile sunt adaugate in ordine, fara PoW (peer le-a minat deja).
/// Returneaza numarul de blocuri aplicate cu succes.
pub fn applyBlocksFromPeer(
    node:    *P2PNode,
    bc:      *Blockchain,
    headers: []const sync_mod.BlockHeader,
) u32 {
    var applied: u32 = 0;

    // ── REORG DETECTION ──────────────────────────────────────────────────
    if (headers.len > 0) {
        const first = headers[0];
        const local_len_initial = bc.chain.items.len;
        if (first.height < @as(u64, local_len_initial)) {
            if (!blockHashesMatch(bc, first.height, first.merkle_root)) {
                const reorg_depth = @as(u64, local_len_initial) - first.height;
                if (reorg_depth > REORG_DEPTH_LIMIT) {
                    std.debug.print(
                        "[REORG] Peer chain diverges {d} blocks deep (local={d}, peer first={d}). " ++
                        "Beyond REORG_DEPTH_LIMIT={d} — REJECTING. Restart with empty data dir " ++
                        "if you need to adopt peer chain from genesis.\n",
                        .{ reorg_depth, local_len_initial, first.height, REORG_DEPTH_LIMIT },
                    );
                    return 0;
                }

                if (chainConfigFromMagic(node.chain_magic)) |cfg| {
                    for (cfg.checkpoints) |cp| {
                        if (first.height <= cp.height) {
                            std.debug.print(
                                "[CHECKPOINT] Peer chain diverges at h={d} but checkpoint at h={d} " ++
                                "is in the way. Rejecting reorg — peer is on a forked history.\n",
                                .{ first.height, cp.height },
                            );
                            return 0;
                        }
                    }
                }

                const peer_tip = headers[headers.len - 1].height + 1;
                if (peer_tip <= local_len_initial) {
                    std.debug.print(
                        "[REORG] Peer chain not heavier (peer tip={d} <= local tip={d}). " ++
                        "Keeping our chain.\n",
                        .{ peer_tip, local_len_initial },
                    );
                    return 0;
                }

                std.debug.print(
                    "[REORG] Chain divergence at height {d} ({d} blocks deep), peer tip={d} > local={d} — " ++
                    "adopting peer chain (heavier).\n",
                    .{ first.height, reorg_depth, peer_tip, local_len_initial },
                );
                truncateChainTo(bc, node.allocator, first.height);
            }
        }
    }

    for (headers) |hdr| {
        const local_len = bc.chain.items.len;

        if (hdr.height < @as(u64, local_len)) {
            continue;
        }

        if (hdr.height != @as(u64, local_len)) {
            std.debug.print("[SYNC] Gap in blocuri: avem {d}, primit {d} — abandon\n",
                .{ local_len, hdr.height });
            break;
        }

        if (chainConfigFromMagic(node.chain_magic)) |cfg| {
            for (cfg.checkpoints) |cp| {
                if (cp.height == hdr.height) {
                    var match = true;
                    for (0..32) |bi| {
                        const hi = std.fmt.charToDigit(cp.hash[bi * 2], 16) catch { match = false; break; };
                        const lo = std.fmt.charToDigit(cp.hash[bi * 2 + 1], 16) catch { match = false; break; };
                        const expected_byte: u8 = (@as(u8, hi) << 4) | @as(u8, lo);
                        if (expected_byte != hdr.merkle_root[bi]) { match = false; break; }
                    }
                    if (!match) {
                        std.debug.print(
                            "[CHECKPOINT] Incoming block at h={d} hash mismatch (expected {s}) — REJECTED\n",
                            .{ hdr.height, cp.hash[0..16] },
                        );
                        return applied;
                    }
                }
            }
        }

        const prev_block = bc.chain.items[local_len - 1];

        const hash_hex = node.allocator.alloc(u8, 64) catch break;
        for (0..32) |bi| {
            _ = std.fmt.bufPrint(hash_hex[bi * 2 .. (bi + 1) * 2], "{x:0>2}", .{hdr.merkle_root[bi]}) catch {};
        }

        const peer_miner = hdr.minerIdSlice();
        const miner_addr = node.allocator.dupe(u8, peer_miner) catch {
            node.allocator.free(hash_hex);
            break;
        };
        const peer_reward: u64 = if (peer_miner.len > 0)
            blockchain_mod.blockRewardAt(hdr.height)
        else
            0;

        var new_block = Block{
            .index         = @intCast(hdr.height),
            .timestamp     = hdr.timestamp,
            .transactions  = std.array_list.Managed(block_mod.Transaction).init(node.allocator),
            .previous_hash = prev_block.hash,
            .nonce         = hdr.nonce,
            .hash          = hash_hex,
            .miner_address = miner_addr,
            .reward_sat    = peer_reward,
            .miner_heap    = true,
        };

        // ── Oracle price-deviation policy ────────────────────────────────
        {
            main_mod.g_oracle_policy_mutex.lock();
            const policy_snapshot = main_mod.g_oracle_policy;
            main_mod.g_oracle_policy_mutex.unlock();

            if (policy_snapshot.enabled) {
                const local_snap: [oracle_types_mod.BLOCK_PRICE_SLOTS]ws_exchange_feed_mod.PriceFetch =
                    if (main_mod.g_ws_feed) |*f| f.getImportantSnapshot()
                    else [_]ws_exchange_feed_mod.PriceFetch{.{
                        .exchange = "",
                        .pair = "",
                        .bid_micro_usd = 0,
                        .ask_micro_usd = 0,
                        .timestamp_ms = 0,
                        .success = false,
                    }} ** oracle_types_mod.BLOCK_PRICE_SLOTS;

                const r = oracle_policy_mod.validateBlockPrices(
                    policy_snapshot,
                    new_block.prices,
                    local_snap,
                    if (main_mod.g_ws_feed) |*f| f else null,
                );
                if (!r.accept) {
                    std.debug.print("[ORACLE-POLICY] REJECT block {d} slot {d}\n",
                        .{ new_block.index, r.rejected_slot.? });
                    node.allocator.free(hash_hex);
                    node.allocator.free(miner_addr);
                    new_block.transactions.deinit();
                    break;
                }
                if (r.warned > 0)
                    std.debug.print("[ORACLE-POLICY] block {d} warned slots: {d}\n",
                        .{ new_block.index, r.warned });
                if (r.gap_filled > 0)
                    std.debug.print("[ORACLE-POLICY] block {d} gap-filled {d} slots from peer\n",
                        .{ new_block.index, r.gap_filled });
            }
        }

        bc.chain.append(new_block) catch {
            node.allocator.free(hash_hex);
            node.allocator.free(miner_addr);
            break;
        };

        if (peer_miner.len > 0 and peer_reward > 0) {
            bc.in_apply_block = true;
            defer bc.in_apply_block = false;

            bc.creditBalance(miner_addr, peer_reward) catch |err| {
                std.debug.print("[SYNC] creditBalance failed for {s}: {}\n",
                    .{ miner_addr[0..@min(miner_addr.len, 12)], err });
            };
            bc.utxo_set.addUTXO(new_block.hash, 0, miner_addr, peer_reward, @intCast(new_block.index), "", true) catch |err| {
                std.debug.print("[SYNC] addUTXO failed for peer miner {s}: {}\n",
                    .{ miner_addr[0..@min(miner_addr.len, 12)], err });
            };
        }

        applied += 1;
        std.debug.print("[SYNC] Bloc #{d} aplicat (miner={s} reward={d} nonce={d})\n",
            .{ hdr.height, miner_addr[0..@min(miner_addr.len, 12)], peer_reward, hdr.nonce });
    }

    if (applied > 0) {
        bc.rebuildValidatorSetFromChain() catch |err| {
            std.debug.print("[VALIDATOR-SET] rebuild after peer apply failed: {}\n", .{err});
        };
    }

    return applied;
}

// ─── Message dispatch ───────────────────────────────────────────────────────

/// Proceseaza un mesaj primit de la un peer (inbound sau outbound)
pub fn dispatchMessage(node: *P2PNode, peer: *PeerConnection, msg_type: u8, payload: []const u8) void {
    const mt: MessageType = @enumFromInt(msg_type);
    const pid = peer.node_id[0..@min(peer.node_id.len, 16)];
    std.debug.print("[DEBUG-P2P-RECV] type={d} ({s}) size={d} from={s} peer.height={d} my.height={d}\n",
        .{ msg_type, @tagName(mt), payload.len, pid, peer.height, node.chain_height });
    switch (mt) {
        .hello => {
            const hi = MsgHello.decode(payload) orelse {
                std.debug.print("[P2P] HELLO decode failed from {s}\n", .{pid});
                return;
            };
            var nid_len: usize = 0;
            while (nid_len < hi.node_id.len and hi.node_id[nid_len] != 0) : (nid_len += 1) {}
            const peer_real_id = hi.node_id[0..nid_len];

            if (!std.mem.eql(u8, &hi.chain_magic, &node.chain_magic)) {
                std.debug.print(
                    "[P2P] HELLO from {s}: WRONG CHAIN — got '{s}' want '{s}' — REJECTED\n",
                    .{ peer_real_id, &hi.chain_magic, &node.chain_magic },
                );
                peer.sendWelcome(node.local_id, node.chain_magic, node.chain_height,
                    false, MsgWelcome.REASON_WRONG_CHAIN) catch {};
                peer.connected = false;
                return;
            }

            const peer_genesis_zero = std.mem.allEqual(u8, &hi.genesis_hash, 0);
            if (!peer_genesis_zero) {
                const my_genesis = node.getLocalGenesisHash();
                if (!std.mem.allEqual(u8, &my_genesis, 0) and !std.mem.eql(u8, &hi.genesis_hash, &my_genesis)) {
                    std.debug.print(
                        "[P2P] HELLO from {s}: GENESIS MISMATCH — different chain instance, REJECTED\n",
                        .{peer_real_id},
                    );
                    peer.sendWelcome(node.local_id, node.chain_magic, node.chain_height,
                        false, MsgWelcome.REASON_WRONG_CHAIN) catch {};
                    peer.connected = false;
                    return;
                }
            }

            if (node.allocator.dupe(u8, peer_real_id)) |owned_id| {
                peer.node_id = owned_id;
            } else |_| {}
            peer.height = hi.height;
            peer.port = hi.listen_port;

            std.debug.print(
                "[P2P] HELLO from '{s}' chain='{s}' listen_port={d} height={d} — WELCOME\n",
                .{ peer_real_id, &hi.chain_magic, hi.listen_port, hi.height },
            );

            peer.sendWelcome(node.local_id, node.chain_magic, node.chain_height,
                true, MsgWelcome.REASON_OK) catch {};

            if (hi.height > node.chain_height) node.chain_height = hi.height;
            if (node.sync_mgr) |sm| {
                if (sm.onPeerHeight(hi.height)) |_| {
                    if (node.blockchain) |bc| node.requestSync(bc.chain.items.len);
                }
            }
        },
        .welcome => {
            const wm = MsgWelcome.decode(payload) orelse {
                std.debug.print("[P2P] WELCOME decode failed from {s}\n", .{pid});
                return;
            };
            if (wm.accepted == 0) {
                const reason_s: []const u8 = switch (wm.reason) {
                    MsgWelcome.REASON_WRONG_CHAIN => "wrong chain",
                    MsgWelcome.REASON_TOO_MANY_PEERS => "too many peers",
                    MsgWelcome.REASON_BANNED => "banned",
                    MsgWelcome.REASON_DUPLICATE_ID => "duplicate node_id",
                    else => "unknown",
                };
                std.debug.print("[P2P] WELCOME REJECTED by {s}: {s}\n", .{ pid, reason_s });
                peer.connected = false;
                return;
            }
            var nid_len: usize = 0;
            while (nid_len < wm.node_id.len and wm.node_id[nid_len] != 0) : (nid_len += 1) {}
            const real_id = wm.node_id[0..nid_len];
            if (node.allocator.dupe(u8, real_id)) |owned_id| {
                peer.node_id = owned_id;
            } else |_| {}
            peer.height = wm.height;
            std.debug.print(
                "[P2P] WELCOME from '{s}' height={d} — STABLE\n",
                .{ real_id, wm.height },
            );
            if (wm.height > node.chain_height) node.chain_height = wm.height;

            const local_h: u64 = if (node.blockchain) |bc| bc.chain.items.len else 0;
            if (wm.height > local_h + IBD_GAP_TRIGGER) {
                node.is_syncing.store(true, .release);
                node.best_peer_height.store(wm.height, .release);
                std.debug.print(
                    "[IBD] Entered sync mode: local={d} peer={d} behind={d} blocks\n",
                    .{ local_h, wm.height, wm.height - local_h },
                );
            }

            peer.sendStable(node.chain_height, @intCast(node.peers.items.len)) catch {};
        },
        .stable => {
            if (MsgStable.decode(payload)) |s| {
                std.debug.print(
                    "[P2P] STABLE from {s}: height={d} peers={d}\n",
                    .{ pid, s.confirmed_height, s.peer_count },
                );
            }
        },
        .ping => {
            if (MsgPing.decode(payload)) |ping| {
                peer.height = ping.height;
                std.debug.print("[P2P] PING de la {s} height={d}\n", .{ pid, ping.height });
                var pong_id_buf: [32]u8 = @splat(0);
                const id_copy = @min(node.local_id.len, 32);
                @memcpy(pong_id_buf[0..id_copy], node.local_id[0..id_copy]);
                const pong_msg = MsgPing{
                    .node_id = pong_id_buf,
                    .height  = node.chain_height,
                    .version = P2P_VERSION,
                };
                if (pong_msg.encode(node.allocator)) |pong_payload| {
                    defer node.allocator.free(pong_payload);
                    peer.send(@intFromEnum(MessageType.pong), pong_payload) catch {};
                } else |_| {}
                if (ping.height > node.chain_height) node.chain_height = ping.height;
                if (node.sync_mgr) |sm| {
                    if (sm.onPeerHeight(ping.height)) |_| {
                        node.requestSync(node.blockchain.?.chain.items.len);
                    }
                }
            }
        },
        .pong => {
            if (MsgPing.decode(payload)) |pong| {
                peer.height = pong.height;
                std.debug.print("[P2P] PONG de la {s} height={d}\n", .{ pid, pong.height });
                if (pong.height > node.chain_height) node.chain_height = pong.height;
            }
        },
        .block => {
            if (MsgBlockAnnounce.decode(payload)) |ann| {
                std.debug.print("[P2P] BLOC #{d} anuntat de {s} reward={d} SAT\n",
                    .{ ann.block_height, pid, ann.reward_sat });
                if (ann.block_height > node.chain_height) {
                    node.chain_height = ann.block_height;
                }
                if (ann.block_height > peer.height) {
                    peer.height = ann.block_height;
                }
                if (node.blockchain) |bc| {
                    if (ann.block_height > 0 and ann.block_height == @as(u64, bc.chain.items.len)) {
                        var real_len: usize = ann.miner_id.len;
                        while (real_len > 0 and (ann.miner_id[real_len - 1] == 0 or ann.miner_id[real_len - 1] == ' ')) real_len -= 1;
                        const claimed_miner = ann.miner_id[0..real_len];

                        _ = chainConfigFromMagic;
                        {
                            const tip = bc.chain.items[bc.chain.items.len - 1];
                            const slot_id = ann.block_height;
                            const expected_leader = validator_mod.leaderForSlot(
                                slot_id, tip.hash, bc.validator_set.items);
                            if (expected_leader) |el| {
                                if (claimed_miner.len > 0 and !std.mem.eql(u8, el.address, claimed_miner)) {
                                    const SLOT_TIMEOUT_S: i64 = 3;
                                    const tip_age_s: i64 = std.time.timestamp() - tip.timestamp;
                                    const claimed_is_validator = blk: {
                                        for (bc.validator_set.items) |v| {
                                            if (std.mem.eql(u8, v.address, claimed_miner)) break :blk true;
                                        }
                                        break :blk false;
                                    };
                                    if (tip_age_s >= SLOT_TIMEOUT_S and claimed_is_validator) {
                                        std.debug.print(
                                            "[SLOT-SKIP] Accepting block #{d} from {s} (tip aged {d}s, leader missed)\n",
                                            .{ ann.block_height,
                                               claimed_miner[0..@min(12, claimed_miner.len)],
                                               tip_age_s },
                                        );
                                    } else {
                                        std.debug.print(
                                            "[SLOT] Rejecting block #{d} from peer — miner '{s}' is NOT slot {d} leader '{s}' (tip age {d}s)\n",
                                            .{ ann.block_height,
                                               claimed_miner[0..@min(12, claimed_miner.len)],
                                               slot_id,
                                               el.address[0..@min(12, el.address.len)],
                                               tip_age_s },
                                        );
                                        return;
                                    }
                                }
                            }
                        }
                    }
                    if (ann.block_height >= @as(u64, bc.chain.items.len)) {
                        node.requestSync(bc.chain.items.len);
                    } else {
                        const FORK_LOOKBACK: u64 = 16;
                        const my_blk = &bc.chain.items[@intCast(ann.block_height)];
                        var ann_hex: [64]u8 = undefined;
                        for (0..32) |bi| {
                            _ = std.fmt.bufPrint(ann_hex[bi * 2 .. (bi + 1) * 2],
                                "{x:0>2}", .{ann.block_hash[bi]}) catch {};
                        }
                        const same_hash = my_blk.hash.len >= 64 and
                            std.mem.eql(u8, my_blk.hash[0..64], &ann_hex);
                        if (!same_hash) {
                            const fork_from = if (ann.block_height > FORK_LOOKBACK)
                                ann.block_height - FORK_LOOKBACK
                            else
                                0;
                            std.debug.print(
                                "[FORK] Peer announces #{d} hash={s}.. but ours is {s}.. — requesting headers from height {d}\n",
                                .{ ann.block_height, ann_hex[0..12],
                                   my_blk.hash[0..@min(12, my_blk.hash.len)],
                                   fork_from },
                            );
                            node.requestSyncForced(fork_from);
                        }
                    }
                }
            }
        },
        .sync_request => {
            std.debug.print("[DEBUG-SYNC-REQ] entered handler, payload.len={d}\n", .{payload.len});
            if (payload.len < 10) {
                std.debug.print("[DEBUG-SYNC-REQ] payload too short ({d}<10), abort\n", .{payload.len});
                return;
            }
            const req = sync_mod.MsgGetHeaders.decode(payload) orelse {
                std.debug.print("[DEBUG-SYNC-REQ] decode failed\n", .{});
                return;
            };
            std.debug.print("[P2P] SYNC_REQUEST de la {s} from={d} max={d}\n",
                .{ pid, req.from_height, req.max_count });

            if (node.blockchain) |bc| {
                std.debug.print("[DEBUG-SYNC-REQ] bc attached, chain_len={d}\n", .{bc.chain.items.len});
                if (node.sync_mgr) |sm| {
                    std.debug.print("[DEBUG-SYNC-REQ] sm attached, calling buildHeadersResponse\n", .{});
                    const resp_buf = sm.buildHeadersResponse(bc, req) catch |err| {
                        std.debug.print("[P2P] buildHeadersResponse ERROR: {}\n", .{err});
                        return;
                    };
                    defer node.allocator.free(resp_buf);
                    std.debug.print("[DEBUG-SYNC-REQ] buildHeadersResponse OK, resp_buf.len={d}\n", .{resp_buf.len});
                    peer.send(@intFromEnum(MessageType.sync_response), resp_buf) catch |err| {
                        std.debug.print("[P2P] SYNC_RESPONSE send ERROR: {}\n", .{err});
                        return;
                    };
                    std.debug.print("[P2P] SYNC_RESPONSE trimis la {s} ({d} bytes)\n",
                        .{ pid, resp_buf.len });
                } else {
                    std.debug.print("[DEBUG-SYNC-REQ] sync_mgr is null!\n", .{});
                }
            } else {
                std.debug.print("[DEBUG-SYNC-REQ] blockchain is null, sending empty response\n", .{});
                peer.send(@intFromEnum(MessageType.sync_response), &.{}) catch {};
            }
        },
        .sync_response => {
            std.debug.print("[P2P] SYNC_RESPONSE de la {s} ({d} bytes)\n",
                .{ pid, payload.len });
            if (payload.len < 2) return;

            const blocks_msg = sync_mod.MsgBlocks.decode(payload, node.allocator) catch |err| {
                std.debug.print("[P2P] MsgBlocks decode error: {}\n", .{err});
                return;
            };
            defer node.allocator.free(blocks_msg.headers);

            if (blocks_msg.count == 0) {
                std.debug.print("[P2P] SYNC_RESPONSE gol de la {s} — suntem la zi\n", .{pid});
                return;
            }

            if (node.blockchain) |bc| {
                const applied = applyBlocksFromPeer(node, bc, blocks_msg.headers[0..blocks_msg.count]);
                if (node.sync_mgr) |sm| sm.onBlocksReceived(applied);
                std.debug.print("[P2P] Aplicat {d}/{d} blocuri de la {s}\n",
                    .{ applied, blocks_msg.count, pid });

                if (blocks_msg.count > 0) {
                    const last_hdr_h = blocks_msg.headers[blocks_msg.count - 1].height;
                    if (last_hdr_h > peer.height) peer.height = last_hdr_h;
                }

                const local_h: u64 = bc.chain.items.len;
                const peer_h: u64 = peer.height;
                if (node.is_syncing.load(.acquire) and peer_h > 0 and
                    local_h + IBD_TOLERANCE >= peer_h) {
                    node.is_syncing.store(false, .release);
                    std.debug.print(
                        "[IBD] Exited sync mode: local={d} peer={d} — mining resumed\n",
                        .{ local_h, peer_h },
                    );
                } else if (node.is_syncing.load(.acquire) and peer_h > 0) {
                    const behind = peer_h - local_h;
                    const pct_u64: u64 = (local_h * 100) / peer_h;
                    std.debug.print(
                        "[IBD] Sync progress: local={d} peer={d} behind={d} blocks ({d}%)\n",
                        .{ local_h, peer_h, behind, pct_u64 },
                    );
                }
            }
        },
        .peer_list => {
            std.debug.print("[PEX] PEER_LIST de la {s} ({d} bytes)\n", .{ pid, payload.len });
            if (payload.len >= 2) {
                const peers = decodePeerList(payload, node.allocator) catch |err| {
                    std.debug.print("[PEX] decode error: {}\n", .{err});
                    return;
                };
                defer node.allocator.free(peers);
                std.debug.print("[PEX] Received {d} peers from {s}\n", .{ peers.len, pid });
                for (peers) |pa| {
                    std.debug.print("[PEX]   peer {d}.{d}.{d}.{d}:{d}\n",
                        .{ pa.ip[0], pa.ip[1], pa.ip[2], pa.ip[3], pa.port });
                }
                var dialed: usize = 0;
                for (peers) |pa| {
                    if (dialed >= 3) break;
                    var host_buf: [16]u8 = undefined;
                    const host_str = std.fmt.bufPrint(&host_buf,
                        "{d}.{d}.{d}.{d}",
                        .{ pa.ip[0], pa.ip[1], pa.ip[2], pa.ip[3] }) catch continue;
                    var already: bool = false;
                    {
                        node.peers_mutex.lock();
                        defer node.peers_mutex.unlock();
                        for (node.peers.items) |p| {
                            if (p.port == pa.port and std.mem.eql(u8, p.host, host_str)) {
                                already = true; break;
                            }
                        }
                    }
                    if (already) continue;
                    node.connectToPeer(host_str, pa.port, "pex") catch |err| {
                        std.debug.print("[PEX] auto-dial {s}:{d} failed: {}\n",
                            .{ host_str, pa.port, err });
                        continue;
                    };
                    dialed += 1;
                    std.debug.print("[PEX] auto-dialed {s}:{d}\n",
                        .{ host_str, pa.port });
                }
            }
        },
        .get_peers => {
            std.debug.print("[PEX] GET_PEERS de la {s}\n", .{pid});
            const resp = discovery_mod.buildPeerListPayload(node) catch |err| {
                std.debug.print("[PEX] buildPeerListPayload error: {}\n", .{err});
                return;
            };
            defer node.allocator.free(resp);
            peer.send(@intFromEnum(MessageType.peer_list), resp) catch |err| {
                std.debug.print("[PEX] peer_list send failed: {}\n", .{err});
            };
        },
        .tx_gossip => {
            if (GossipTxPayload.decode(payload)) |gtx| {
                if (!node.seen_tx_hashes.insert(gtx.tx_hash)) {
                    return;
                }
                node.gossip_tx_count += 1;

                std.debug.print("[GOSSIP] TX received from {s}: {s}..\n",
                    .{ pid, gtx.tx_hash[0..@min(gtx.tx_hash.len, 12)] });

                if (node.blockchain) |bc| {
                    gossipAddTxToMempool(bc, gtx.tx_json, node.allocator) catch |err| {
                        std.debug.print("[GOSSIP] TX add to mempool failed ({s}): {s}\n",
                            .{ @errorName(err), gtx.tx_hash[0..@min(gtx.tx_hash.len, 12)] });
                    };
                }

                gossip_mod.relayTxExcept(node, peer.node_id, payload);
            } else {
                std.debug.print("[GOSSIP] TX decode failed from {s}\n", .{pid});
            }
        },
        .block_gossip => {
            if (MsgBlockAnnounce.decode(payload)) |ann| {
                var hash_hex_buf: [64]u8 = @splat(0);
                const copy_len = @min(ann.block_hash.len, 32);
                var actual_len: usize = 32;
                while (actual_len > 0 and ann.block_hash[actual_len - 1] == 0) actual_len -= 1;
                @memcpy(hash_hex_buf[0..actual_len], ann.block_hash[0..actual_len]);
                _ = copy_len;

                if (!node.seen_block_hashes.insert(hash_hex_buf[0..actual_len])) {
                    return;
                }
                node.gossip_block_count += 1;

                std.debug.print("[GOSSIP] Block #{d} from {s} reward={d} SAT\n",
                    .{ ann.block_height, pid, ann.reward_sat });

                if (ann.block_height > node.chain_height) {
                    node.chain_height = ann.block_height;
                }
                if (ann.block_height > peer.height) {
                    peer.height = ann.block_height;
                }

                if (node.blockchain) |bc| {
                    if (ann.block_height >= @as(u64, bc.chain.items.len)) {
                        node.requestSync(bc.chain.items.len);
                    }
                }

                gossip_mod.relayBlockExcept(node, peer.node_id, payload);
            } else {
                std.debug.print("[GOSSIP] Block decode failed from {s}\n", .{pid});
            }
        },
        .inv => {
            std.debug.print("[GOSSIP] INV from {s} ({d} bytes)\n", .{ pid, payload.len });
        },
        .getdata => {
            std.debug.print("[GOSSIP] GETDATA from {s} ({d} bytes)\n", .{ pid, payload.len });
        },
        .getblocks => {
            std.debug.print("[GOSSIP] GETBLOCKS from {s} ({d} bytes)\n", .{ pid, payload.len });
            if (payload.len >= 8) {
                const from_height = std.mem.readInt(u64, payload[0..8], .little);
                if (node.blockchain) |bc| {
                    if (node.sync_mgr) |sm| {
                        const req = sync_mod.MsgGetHeaders{
                            .from_height = from_height,
                            .max_count   = 50,
                        };
                        const resp_buf = sm.buildHeadersResponse(bc, req) catch return;
                        defer node.allocator.free(resp_buf);
                        peer.send(@intFromEnum(MessageType.sync_response), resp_buf) catch {};
                    }
                }
            }
        },
        .getheaders_p2p => {
            const req = decodeGetHeaders(payload) orelse return;
            std.debug.print("[SPV] GETHEADERS from {s} start={d} count={d}\n",
                .{ pid, req.start_height, req.count });

            if (node.blockchain) |bc| {
                const chain_len = bc.chain.items.len;
                const start: usize = @intCast(@min(req.start_height, chain_len));
                const max_count: usize = @intCast(@min(req.count, SPV_MAX_HEADERS_PER_MSG));
                const end = @min(start + max_count, chain_len);
                const actual_count = end - start;

                if (actual_count == 0) {
                    var empty: [4]u8 = undefined;
                    std.mem.writeInt(u32, &empty, 0, .little);
                    peer.send(@intFromEnum(MessageType.headers_p2p), &empty) catch {};
                    return;
                }

                const resp_size = 4 + actual_count * SPV_HEADER_SIZE;
                const resp_buf = node.allocator.alloc(u8, resp_size) catch return;
                defer node.allocator.free(resp_buf);

                std.mem.writeInt(u32, resp_buf[0..4], @intCast(actual_count), .little);

                for (start..end) |i| {
                    const blk = &bc.chain.items[i];
                    var hdr_buf: [SPV_HEADER_SIZE]u8 = undefined;
                    var lc_header = light_client_mod.BlockHeader.init(@intCast(i));
                    lc_header.timestamp = blk.timestamp;
                    lc_header.nonce = blk.nonce;
                    lc_header.difficulty = 4;
                    if (blk.hash.len >= 32) {
                        @memcpy(&lc_header.hash, blk.hash[0..32]);
                    }
                    if (blk.previous_hash.len >= 32) {
                        @memcpy(&lc_header.previous_hash, blk.previous_hash[0..32]);
                    }

                    serializeSpvHeader(&lc_header, &hdr_buf);
                    const off = 4 + (i - start) * SPV_HEADER_SIZE;
                    @memcpy(resp_buf[off .. off + SPV_HEADER_SIZE], &hdr_buf);
                }

                peer.send(@intFromEnum(MessageType.headers_p2p), resp_buf) catch |err| {
                    std.debug.print("[SPV] headers_p2p send failed: {}\n", .{err});
                };
                std.debug.print("[SPV] Sent {d} headers to {s}\n", .{ actual_count, pid });
            }
        },
        .headers_p2p => {
            std.debug.print("[SPV] HEADERS from {s} ({d} bytes)\n", .{ pid, payload.len });

            if (node.light_client) |lc| {
                const headers = decodeHeadersBatch(payload, node.allocator) catch |err| {
                    std.debug.print("[SPV] headers decode error: {}\n", .{err});
                    return;
                };
                defer node.allocator.free(headers);

                var added: u32 = 0;
                for (headers) |header| {
                    lc.addValidatedHeader(header) catch {
                        continue;
                    };
                    added += 1;
                }
                std.debug.print("[SPV] Added {d}/{d} validated headers (height now {d})\n",
                    .{ added, headers.len, lc.getHeight() });
            }
        },
        .getmerkleproof_p2p => {
            if (payload.len < 36) return;
            const block_idx = std.mem.readInt(u32, payload[32..36], .little);
            std.debug.print("[SPV] GETMERKLEPROOF from {s} block={d}\n", .{ pid, block_idx });
        },
        .merkleproof_p2p => {
            std.debug.print("[SPV] MERKLEPROOF from {s} ({d} bytes)\n", .{ pid, payload.len });
        },
        .filterload => {
            if (decodeBloomFilter(payload)) |filter| {
                std.debug.print("[SPV] FILTERLOAD from {s} ({d} hash funcs)\n",
                    .{ pid, filter.num_hash_funcs });
            } else {
                std.debug.print("[SPV] FILTERLOAD decode failed from {s}\n", .{pid});
            }
        },
        else => {
            std.debug.print("[P2P] Mesaj necunoscut tip={d} de la {s}\n", .{ msg_type, pid });
        },
    }
}
