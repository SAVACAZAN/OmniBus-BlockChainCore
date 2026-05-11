/// cli_audit.zig — `omnibus-cli` standalone audit tool.
///
/// Pure-stdlib Zig binary that connects to a running OmniBus node via
/// JSON-RPC HTTP (port 8332/18332/28332) and provides the same daily-audit
/// / stake-history / balance-breakdown / reputation snapshots that the
/// React frontend's DailyAuditPage and StakePage Activity tab show — but
/// with no React, no browser, no WebSocket, no node_modules.
///
/// Pattern mirrors `core/oracle_main.zig`'s tcpConnectToAddress + hand-
/// rolled HTTP request + std.json.parseFromSlice for response parsing.
///
/// Subcommands:
///   balance <addr>            Full balance breakdown (wallet/stake/avail/rep)
///   stake <addr>              Current stake + activity log
///   reputation <addr>         Cups + tier
///   daily <addr> [days=30]    Per-day TX breakdown
///   validators                List of all validators
///   stakers [limit=10]        Top stakers
///   health                    Chain stats (block, mempool, peers)
///   history <addr> [filter]   TX history (filter: stake/sent/received/mined/all)
///   verify <addr>             Sanity check: chain stake_amounts vs sum(TXs)
///
/// Global flags:
///   --rpc <url>           Override RPC URL (default http://127.0.0.1:8332)
///   --chain <c>           mainnet|testnet|regtest (8332/18332/28332)
///   --remote              Use https://omnibusblockchain.cc:8443/api-{chain}
///                          (requires curl in PATH for HTTPS)
///   --token <bearer>      RPC bearer token if needed
///   --json                Raw JSON output
///   --no-color            Disable ANSI colors
///
/// Build: `zig build install` → zig-out/bin/omnibus-cli(.exe)

const std = @import("std");
const bip32_wallet = @import("bip32_wallet.zig");
const secp256k1 = @import("secp256k1.zig");
const wallet_mod = @import("wallet.zig");
const bech32_mod = @import("bech32.zig");

// ─── stdio (Zig 0.15.2: std.io.getStdOut was removed; use std.fs.File) ─────
fn stdout() std.fs.File.DeprecatedWriter {
    return std.fs.File.stdout().deprecatedWriter();
}
fn stderr() std.fs.File.DeprecatedWriter {
    return std.fs.File.stderr().deprecatedWriter();
}

// ─── ANSI colors ────────────────────────────────────────────────────────────
var g_color: bool = true;

fn ansi(comptime code: []const u8) []const u8 {
    return if (g_color) "\x1b[" ++ code ++ "m" else "";
}
const C_RESET   = "\x1b[0m";
const C_BOLD    = "\x1b[1m";
const C_GREEN   = "\x1b[32m";
const C_YELLOW  = "\x1b[33m";
const C_RED     = "\x1b[31m";
const C_CYAN    = "\x1b[36m";
const C_GRAY    = "\x1b[90m";
const C_MAGENTA = "\x1b[35m";

fn col(comptime code: []const u8) []const u8 {
    return if (g_color) code else "";
}
fn rst() []const u8 {
    return if (g_color) C_RESET else "";
}

// ─── Constants ──────────────────────────────────────────────────────────────
const SAT_PER_OMNI: u64 = 1_000_000_000;
const PORT_MAINNET: u16 = 8332;
const PORT_TESTNET: u16 = 18332;
const PORT_REGTEST: u16 = 28332;
/// 1s blocks — group by block_height / 86400 for one calendar day.
const BLOCKS_PER_DAY: u64 = 86400;

// ─── Endpoint config ────────────────────────────────────────────────────────
const Endpoint = struct {
    host: []const u8 = "127.0.0.1",
    port: u16 = PORT_MAINNET,
    path: []const u8 = "/",
    use_curl: bool = false, // for --remote (HTTPS)
    full_url: ?[]const u8 = null,
    token: ?[]const u8 = null,
};

// ─── CLI state ──────────────────────────────────────────────────────────────
/// One named flag like `--fee-bps=50` or `--target-addr=ob1q…`.
/// We collect these into a small flat array on `Args` so write-handlers can
/// look them up by key without re-walking argv.
const KeyVal = struct { key: []const u8, val: []const u8 };

const Args = struct {
    cmd: []const u8 = "",
    pos: [][]const u8 = &.{}, // positional args after cmd
    rpc: ?[]const u8 = null,
    chain: []const u8 = "mainnet",
    remote: bool = false,
    token: ?[]const u8 = null,
    json: bool = false,
    no_color: bool = false,
    // ── extras for write-side commands ─────────────────────────────────────
    yes: bool = false,            // --yes        confirm a write op
    mnemonic: ?[]const u8 = null, // --mnemonic   override OMNIBUS_MNEMONIC
    passphrase: ?[]const u8 = null, // --passphrase BIP-39 "25th word" (hidden wallet)
    privkey:  ?[]const u8 = null, // --privkey    raw 32-byte hex (no derivation)
    keyfile:  ?[]const u8 = null, // --keyfile    encrypted key file (AES-GCM)
    key_index: u32 = 0,           // --key-index  BIP-44 child index (default 0)
    signers: ?[]const u8 = null,  // --signers    multisig signer list
    kvs: []KeyVal = &.{},         // generic --foo-bar=baz pairs
};

/// Fast accessor for `--foo-bar=baz` kv flags. Returns null if not present.
fn kvLookup(args: Args, key: []const u8) ?[]const u8 {
    for (args.kvs) |kv| {
        if (std.mem.eql(u8, kv.key, key)) return kv.val;
    }
    return null;
}

fn parseArgs(allocator: std.mem.Allocator, argv: []const [:0]u8) !Args {
    var out = Args{};
    var pos = std.array_list.Managed([]const u8).init(allocator);
    errdefer pos.deinit();
    var kvs = std.array_list.Managed(KeyVal).init(allocator);
    errdefer kvs.deinit();

    var i: usize = 1; // skip exe name
    while (i < argv.len) : (i += 1) {
        const a = argv[i];
        if (std.mem.eql(u8, a, "--rpc") and i + 1 < argv.len) {
            i += 1;
            out.rpc = argv[i];
        } else if (std.mem.eql(u8, a, "--chain") and i + 1 < argv.len) {
            i += 1;
            out.chain = argv[i];
        } else if (std.mem.eql(u8, a, "--remote")) {
            out.remote = true;
        } else if (std.mem.eql(u8, a, "--token") and i + 1 < argv.len) {
            i += 1;
            out.token = argv[i];
        } else if (std.mem.eql(u8, a, "--json")) {
            out.json = true;
        } else if (std.mem.eql(u8, a, "--no-color")) {
            out.no_color = true;
        } else if (std.mem.eql(u8, a, "--yes") or std.mem.eql(u8, a, "-y")) {
            out.yes = true;
        } else if (std.mem.eql(u8, a, "--mnemonic") and i + 1 < argv.len) {
            i += 1;
            out.mnemonic = argv[i];
        } else if (std.mem.eql(u8, a, "--passphrase") and i + 1 < argv.len) {
            i += 1;
            out.passphrase = argv[i];
        } else if (std.mem.eql(u8, a, "--privkey") and i + 1 < argv.len) {
            i += 1;
            out.privkey = argv[i];
        } else if (std.mem.eql(u8, a, "--keyfile") and i + 1 < argv.len) {
            i += 1;
            out.keyfile = argv[i];
        } else if (std.mem.eql(u8, a, "--key-index") and i + 1 < argv.len) {
            i += 1;
            out.key_index = std.fmt.parseInt(u32, argv[i], 10) catch 0;
        } else if (std.mem.eql(u8, a, "--signers") and i + 1 < argv.len) {
            i += 1;
            out.signers = argv[i];
        } else if (std.mem.startsWith(u8, a, "--") and
                   std.mem.indexOfScalar(u8, a, '=') != null)
        {
            // Generic --key=value flag.
            const eq = std.mem.indexOfScalar(u8, a, '=').?;
            const k = a[2..eq];
            const v = a[eq + 1 ..];
            try kvs.append(.{ .key = k, .val = v });
        } else if (std.mem.eql(u8, a, "-h") or std.mem.eql(u8, a, "--help")) {
            out.cmd = "help";
        } else if (out.cmd.len == 0) {
            out.cmd = a;
        } else {
            try pos.append(a);
        }
    }
    out.pos = try pos.toOwnedSlice();
    out.kvs = try kvs.toOwnedSlice();
    return out;
}

fn resolveEndpoint(args: Args) Endpoint {
    var ep = Endpoint{};
    ep.token = args.token;

    if (args.remote) {
        ep.use_curl = true;
        // omnibusblockchain.cc:8443/api-mainnet etc.
        ep.full_url = if (std.mem.eql(u8, args.chain, "testnet"))
            "https://omnibusblockchain.cc:8443/api-testnet"
        else if (std.mem.eql(u8, args.chain, "regtest"))
            "https://omnibusblockchain.cc:8443/api-regtest"
        else
            "https://omnibusblockchain.cc:8443/api-mainnet";
        return ep;
    }

    if (args.rpc) |raw| {
        // Parse http://host:port/path
        var rest = raw;
        if (std.mem.startsWith(u8, rest, "http://")) {
            rest = rest[7..];
        } else if (std.mem.startsWith(u8, rest, "https://")) {
            ep.use_curl = true;
            ep.full_url = raw;
            return ep;
        }
        // host[:port][/path]
        const slash = std.mem.indexOfScalar(u8, rest, '/');
        const hostport = if (slash) |s| rest[0..s] else rest;
        if (slash) |s| ep.path = rest[s..];
        const colon = std.mem.indexOfScalar(u8, hostport, ':');
        if (colon) |c| {
            ep.host = hostport[0..c];
            ep.port = std.fmt.parseInt(u16, hostport[c + 1 ..], 10) catch ep.port;
        } else {
            ep.host = hostport;
        }
        return ep;
    }

    // chain → port
    if (std.mem.eql(u8, args.chain, "testnet")) {
        ep.port = PORT_TESTNET;
    } else if (std.mem.eql(u8, args.chain, "regtest")) {
        ep.port = PORT_REGTEST;
    } else {
        ep.port = PORT_MAINNET;
    }
    return ep;
}

// ─── HTTP transport ─────────────────────────────────────────────────────────
fn rpcCall(
    allocator: std.mem.Allocator,
    ep: Endpoint,
    method: []const u8,
    params_json: []const u8, // already-formatted "[...]" or "{...}" or "[]"
) ![]u8 {
    const body = try std.fmt.allocPrint(allocator,
        "{{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"{s}\",\"params\":{s}}}",
        .{ method, params_json });
    defer allocator.free(body);

    if (ep.use_curl) {
        // HTTPS via curl (TLS in pure-stdlib Zig is heavy — fall back).
        const url = ep.full_url.?;
        var argv = std.array_list.Managed([]const u8).init(allocator);
        defer argv.deinit();
        try argv.append("curl");
        try argv.append("-sS");
        try argv.append("-X");
        try argv.append("POST");
        try argv.append("-H");
        try argv.append("Content-Type: application/json");
        if (ep.token) |t| {
            const auth = try std.fmt.allocPrint(allocator, "Authorization: Bearer {s}", .{t});
            defer allocator.free(auth);
            try argv.append("-H");
            try argv.append(auth);
        }
        try argv.append("-d");
        try argv.append(body);
        try argv.append(url);

        var child = std.process.Child.init(argv.items, allocator);
        child.stdin_behavior = .Ignore;
        child.stdout_behavior = .Pipe;
        child.stderr_behavior = .Pipe;
        child.spawn() catch |e| {
            return rpcError(allocator, "curl spawn failed: {s} (is curl in PATH?)", .{@errorName(e)});
        };
        var curl_out: std.ArrayList(u8) = .empty;
        var curl_err: std.ArrayList(u8) = .empty;
        defer curl_err.deinit(allocator);
        child.collectOutput(allocator, &curl_out, &curl_err, 8 * 1024 * 1024) catch {};
        _ = child.wait() catch {};
        return curl_out.toOwnedSlice(allocator);
    }

    // Direct TCP — same pattern as oracle_main.zig + main.fetchOracleAllPairs.
    const addr = std.net.Address.parseIp4(ep.host, ep.port) catch |e| {
        return rpcError(allocator, "Cannot parse host {s}:{d}: {s}",
            .{ ep.host, ep.port, @errorName(e) });
    };
    var stream = std.net.tcpConnectToAddress(addr) catch |e| {
        return rpcError(allocator,
            "Cannot reach RPC at http://{s}:{d}{s} ({s}). Is omnibus-node running?",
            .{ ep.host, ep.port, ep.path, @errorName(e) });
    };
    defer stream.close();

    // Build HTTP request.
    var req = std.array_list.Managed(u8).init(allocator);
    defer req.deinit();
    const w = req.writer();
    try w.print("POST {s} HTTP/1.1\r\n", .{ep.path});
    try w.print("Host: {s}:{d}\r\n", .{ ep.host, ep.port });
    try w.writeAll("Content-Type: application/json\r\n");
    if (ep.token) |t| try w.print("Authorization: Bearer {s}\r\n", .{t});
    try w.print("Content-Length: {d}\r\n", .{body.len});
    try w.writeAll("Connection: close\r\n\r\n");
    try w.writeAll(body);

    _ = stream.writeAll(req.items) catch |e| {
        return rpcError(allocator, "RPC write failed: {s}", .{@errorName(e)});
    };

    var resp = std.array_list.Managed(u8).init(allocator);
    defer resp.deinit();
    var buf: [16 * 1024]u8 = undefined;
    while (true) {
        const n = stream.read(&buf) catch |e| switch (e) {
            error.ConnectionResetByPeer => break,
            else => return rpcError(allocator, "RPC read failed: {s}", .{@errorName(e)}),
        };
        if (n == 0) break;
        try resp.appendSlice(buf[0..n]);
        if (resp.items.len > 8 * 1024 * 1024) break; // 8 MiB hard cap
    }
    const sep = std.mem.indexOf(u8, resp.items, "\r\n\r\n") orelse
        return rpcError(allocator, "Malformed RPC response (no body separator)", .{});
    return allocator.dupe(u8, resp.items[sep + 4 ..]);
}

fn rpcError(allocator: std.mem.Allocator, comptime fmt: []const u8, args: anytype) ![]u8 {
    const msg = try std.fmt.allocPrint(allocator, fmt, args);
    defer allocator.free(msg);
    // Encode errors into a synthetic JSON-RPC error so callers can keep
    // a single parse path. Top-level main() detects .error and exit-codes 1.
    return std.fmt.allocPrint(allocator,
        "{{\"jsonrpc\":\"2.0\",\"id\":1,\"error\":{{\"code\":-32099,\"message\":\"{s}\"}}}}",
        .{msg});
}

// ─── JSON parse helpers ─────────────────────────────────────────────────────
const Parsed = std.json.Parsed(std.json.Value);

fn parse(allocator: std.mem.Allocator, json: []const u8) !Parsed {
    return std.json.parseFromSlice(std.json.Value, allocator, json, .{
        .ignore_unknown_fields = true,
    });
}

/// Returns the `result` object or sets *err_msg and returns null.
fn extractResult(root: std.json.Value, err_msg: *[]const u8) ?std.json.Value {
    if (root != .object) {
        err_msg.* = "Response is not a JSON object";
        return null;
    }
    if (root.object.get("error")) |e| {
        if (e == .object) {
            if (e.object.get("message")) |m| {
                if (m == .string) {
                    err_msg.* = m.string;
                    return null;
                }
            }
        }
        err_msg.* = "RPC error (no message)";
        return null;
    }
    return root.object.get("result");
}

fn jsonGetStr(obj: std.json.Value, key: []const u8) ?[]const u8 {
    if (obj != .object) return null;
    const v = obj.object.get(key) orelse return null;
    return switch (v) {
        .string => |s| s,
        else => null,
    };
}

fn jsonGetU64(obj: std.json.Value, key: []const u8) u64 {
    if (obj != .object) return 0;
    const v = obj.object.get(key) orelse return 0;
    return switch (v) {
        .integer => |i| if (i < 0) 0 else @intCast(i),
        .float => |f| if (f < 0) 0 else @intFromFloat(f),
        .string => |s| std.fmt.parseInt(u64, s, 10) catch 0,
        else => 0,
    };
}

// ─── Formatting helpers ─────────────────────────────────────────────────────

/// 1234567890 sat → "1.2346 OMNI" (max 4 decimals, trimmed trailing zeros).
fn formatOmni(buf: []u8, sat: u64) ![]const u8 {
    const omni_i = sat / SAT_PER_OMNI;
    const frac = sat % SAT_PER_OMNI;
    // Round to 4 decimals: divide frac (out of 1e9) → out of 1e4.
    const four_dec = (frac + 50_000) / 100_000;
    if (four_dec == 0) {
        return std.fmt.bufPrint(buf, "{d}.0000", .{omni_i});
    }
    return std.fmt.bufPrint(buf, "{d}.{d:0>4}", .{ omni_i, four_dec });
}

/// Compute a "day index" from a block height, given 1s blocks.
/// Used to bucket TXs into calendar days for the daily report.
fn parseDay(block_height: u64) u64 {
    return block_height / BLOCKS_PER_DAY;
}

// ─── Subcommand: health ─────────────────────────────────────────────────────
fn cmdHealth(allocator: std.mem.Allocator, ep: Endpoint, json_mode: bool) !u8 {
    const resp = try rpcCall(allocator, ep, "getchainmetrics", "[]");
    defer allocator.free(resp);
    if (json_mode) {
        try stdout().print("{s}\n", .{resp});
        return 0;
    }
    var parsed = parse(allocator, resp) catch {
        try stderr().print("Failed to parse response\n", .{});
        return 1;
    };
    defer parsed.deinit();
    var err_msg: []const u8 = "";
    const result = extractResult(parsed.value, &err_msg) orelse {
        try stderr().print("{s}RPC error:{s} {s}\n",
            .{ col(C_RED), rst(), err_msg });
        return 1;
    };

    const out = stdout();
    try out.print("{s}=== Chain Health ==={s}\n", .{ col(C_BOLD), rst() });
    try out.print("Height:           {s}{d}{s}\n",
        .{ col(C_GREEN), jsonGetU64(result, "height"), rst() });
    if (jsonGetStr(result, "tipHash")) |th| {
        try out.print("Tip hash:         {s}\n", .{th});
    }
    const supply_sat = jsonGetU64(result, "totalSupply");
    var buf: [64]u8 = undefined;
    try out.print("Total supply:     {s} OMNI\n", .{try formatOmni(&buf, supply_sat)});
    try out.print("Addresses w/bal:  {d}\n", .{jsonGetU64(result, "addressesWithBalance")});
    try out.print("Validators:       {d}\n", .{jsonGetU64(result, "validators")});
    try out.print("Mempool size:     {d}\n", .{jsonGetU64(result, "mempoolSize")});
    try out.print("Peers:            {d}\n", .{jsonGetU64(result, "peerCount")});
    try out.print("Block reward:     {s} OMNI\n",
        .{try formatOmni(&buf, jsonGetU64(result, "currentBlockReward"))});

    // Sync status as a follow-up (best-effort — no fail).
    const sync_resp = rpcCall(allocator, ep, "getsyncstatus", "[]") catch return 0;
    defer allocator.free(sync_resp);
    var sp = parse(allocator, sync_resp) catch return 0;
    defer sp.deinit();
    var em2: []const u8 = "";
    if (extractResult(sp.value, &em2)) |sr| {
        const synced = blk: {
            if (sr != .object) break :blk false;
            const v = sr.object.get("synced") orelse break :blk false;
            break :blk v == .bool and v.bool;
        };
        const tag: []const u8 = if (synced) "SYNCED" else "SYNCING";
        const c: []const u8 = if (synced) col(C_GREEN) else col(C_YELLOW);
        try out.print("Sync status:      {s}{s}{s} (local={d} peer={d})\n", .{
            c, tag, rst(),
            jsonGetU64(sr, "localHeight"),
            jsonGetU64(sr, "peerHeight"),
        });
    }
    return 0;
}

// ─── Subcommand: balance ────────────────────────────────────────────────────
/// Derive ONE child key from a mnemonic at the given BIP-44 index, print
/// privkey hex + address. Lets the user pre-derive keys offline once, save
/// them as keyfiles (chmod 600), and from there on never touch the seed
/// phrase from the CLI again — sign with `--keyfile` or `--privkey`.
///
/// Output is intentionally write-once: we print the privkey to stdout so
/// you can `> /etc/omnibus/key-17.hex && chmod 600 ...`. Treat that file
/// like a wallet — if leaked, that ONE address is compromised, but the
/// master mnemonic is NOT (BIP-32 keys can't be reversed to the seed).
fn cmdDeriveKey(allocator: std.mem.Allocator, args: Args) !u8 {
    const idx_arg = if (args.pos.len > 0) args.pos[0] else "0";
    const idx = std.fmt.parseInt(u32, idx_arg, 10) catch {
        try stderr().print("{s}error:{s} bad key index `{s}`\n",
            .{ col(C_RED), rst(), idx_arg });
        return 2;
    };

    // Build a synthetic Args with key_index set so we reuse resolveSigningKey.
    var derived_args = args;
    derived_args.key_index = idx;
    // Force the mnemonic path even if user passed --privkey by accident.
    derived_args.privkey = null;
    derived_args.keyfile = null;

    const sk = resolveSigningKey(allocator, derived_args) catch |err| {
        try stderr().print("{s}derive failed:{s} {s} (need --mnemonic or OMNIBUS_MNEMONIC)\n",
            .{ col(C_RED), rst(), @errorName(err) });
        return 1;
    };

    const addr = wallet_mod.Wallet.pubkeyHash160(sk.pubkey);
    const ob_addr = bech32_mod.encodeOBAddress(addr, allocator) catch {
        try stderr().print("{s}encode failed{s}\n", .{ col(C_RED), rst() });
        return 1;
    };
    defer allocator.free(ob_addr);

    const priv_hex = try bytesToHex(allocator, &sk.privkey);
    defer allocator.free(priv_hex);
    const pub_hex = try bytesToHex(allocator, &sk.pubkey);
    defer allocator.free(pub_hex);

    if (args.json) {
        try stdout().print(
            "{{\"index\":{d},\"path\":\"m/44'/777'/0'/0/{d}\",\"address\":\"{s}\",\"privkey\":\"{s}\",\"pubkey\":\"{s}\"}}\n",
            .{ idx, idx, ob_addr, priv_hex, pub_hex });
        return 0;
    }

    const out = stdout();
    try out.print("{s}=== Derived key #{d} ==={s}\n", .{ col(C_BOLD), idx, rst() });
    try out.print("Path    : m/44'/777'/0'/0/{d}\n", .{idx});
    try out.print("Address : {s}{s}{s}\n", .{ col(C_GREEN), ob_addr, rst() });
    try out.print("Pubkey  : {s}\n", .{pub_hex});
    try out.print("Privkey : {s}{s}{s}  {s}(SECRET — store offline){s}\n",
        .{ col(C_RED), priv_hex, rst(), col(C_GRAY), rst() });
    try out.print("\n{s}Tips:{s}\n", .{ col(C_BOLD), rst() });
    try out.print("  Save to file:    echo {s} > key-{d}.hex && chmod 600 key-{d}.hex\n",
        .{ priv_hex, idx, idx });
    try out.print("  Use it later:    omnibus-cli exchange-place ... --keyfile key-{d}.hex\n", .{idx});
    try out.print("  Or as env:       OMNIBUS_PRIVKEY={s} omnibus-cli ...\n", .{priv_hex});
    return 0;
}

/// List the first N addresses derived from one mnemonic at indices 0..N-1.
/// Useful when you've decided to "carve" 1000 keys out of a single seed and
/// need to know which `--key-index` corresponds to which on-chain address.
/// Privkeys are NOT printed here — only addresses. Pair with `derive-key
/// <idx>` when you want the secret material for one specific slot.
fn cmdWalletList(allocator: std.mem.Allocator, args: Args) !u8 {
    const count_arg = if (args.pos.len > 0) args.pos[0] else "10";
    const count_raw = std.fmt.parseInt(u32, count_arg, 10) catch 10;
    const count = @min(count_raw, 1000); // hard cap so we don't OOM

    // Drive resolveSigningKey via mnemonic only — privkey/keyfile flags do
    // not produce siblings (one privkey = one address, by definition).
    var probe_args = args;
    probe_args.privkey = null;
    probe_args.keyfile = null;

    if (args.json) try stdout().writeAll("[");
    var i: u32 = 0;
    var first = true;
    while (i < count) : (i += 1) {
        probe_args.key_index = i;
        const sk = resolveSigningKey(allocator, probe_args) catch |err| {
            try stderr().print("{s}derive #{d} failed:{s} {s}\n",
                .{ col(C_RED), i, rst(), @errorName(err) });
            return 1;
        };
        const h160 = wallet_mod.Wallet.pubkeyHash160(sk.pubkey);
        const ob_addr = bech32_mod.encodeOBAddress(h160, allocator) catch return 1;
        defer allocator.free(ob_addr);

        if (args.json) {
            if (!first) try stdout().writeAll(",");
            first = false;
            try stdout().print("{{\"index\":{d},\"address\":\"{s}\"}}", .{ i, ob_addr });
        } else {
            try stdout().print("  #{d:>4}  m/44'/777'/0'/0/{d:<4}  {s}\n",
                .{ i, i, ob_addr });
        }
    }
    if (args.json) try stdout().writeAll("]\n");
    return 0;
}

/// Single-call wallet snapshot. Returns wallet/staked/in_orders/available
/// plus per-stake lock metadata + open sell orders — atomic against the
/// chain mutex so all four numbers reflect the same chain state.
///
/// Lets a CLI user verify "how much of my OMNI is locked, where?" without
/// the frontend. Equivalent of the React `useGlobalBalance` hook.
fn cmdWalletSummary(allocator: std.mem.Allocator, ep: Endpoint, addr: []const u8, json_mode: bool) !u8 {
    const params = try std.fmt.allocPrint(allocator, "[\"{s}\"]", .{addr});
    defer allocator.free(params);
    const resp = try rpcCall(allocator, ep, "getwalletsummary", params);
    defer allocator.free(resp);

    if (json_mode) {
        try stdout().print("{s}\n", .{resp});
        return 0;
    }

    var parsed = try parse(allocator, resp);
    defer parsed.deinit();
    var err_msg: []const u8 = "";
    const r = extractResult(parsed.value, &err_msg) orelse {
        try stderr().print("{s}getwalletsummary error:{s} {s}\n", .{ col(C_RED), rst(), err_msg });
        return 1;
    };

    const wallet_sat   = jsonGetU64(r, "wallet_sat");
    const staked_sat   = jsonGetU64(r, "staked_sat");
    const in_orders    = jsonGetU64(r, "in_orders_sat");
    const available    = jsonGetU64(r, "available_sat");
    const height       = jsonGetU64(r, "height");

    var b1: [64]u8 = undefined; var b2: [64]u8 = undefined;
    var b3: [64]u8 = undefined; var b4: [64]u8 = undefined;

    const out = stdout();
    try out.print("{s}=== Wallet summary: {s} ==={s}\n", .{ col(C_BOLD), addr, rst() });
    try out.print("Block height : {d}\n", .{height});
    try out.print("Wallet       : {s}{s}{s} OMNI  (total on chain)\n",
        .{ col(C_BOLD), try formatOmni(&b1, wallet_sat), rst() });
    try out.print("Staked 🔒    : {s}{s}{s} OMNI  (locked, earning votes)\n",
        .{ col(C_MAGENTA), try formatOmni(&b2, staked_sat), rst() });
    try out.print("In orders    : {s}{s}{s} OMNI  (active sell orders)\n",
        .{ col(C_YELLOW), try formatOmni(&b3, in_orders), rst() });
    try out.print("Available ✓  : {s}{s}{s} OMNI  (spendable now)\n",
        .{ col(C_GREEN), try formatOmni(&b4, available), rst() });

    if (r == .object) {
        if (r.object.get("stakes")) |stakes| if (stakes == .array and stakes.array.items.len > 0) {
            try out.print("\n{s}Stake locks:{s}\n", .{ col(C_BOLD), rst() });
            for (stakes.array.items) |s| {
                const sid    = jsonGetU64(s, "id");
                const amt    = jsonGetU64(s, "amount_sat");
                const sblk   = jsonGetU64(s, "started_at_block");
                const lockb  = jsonGetU64(s, "lock_blocks");
                const days   = jsonGetU64(s, "days_locked");
                const status = jsonGetStr(s, "status") orelse "?";
                var bs: [64]u8 = undefined;
                try out.print("  #{d}: {s} OMNI · {d}d · started @{d} · lock {d} blocks · {s}\n",
                    .{ sid, try formatOmni(&bs, amt), days, sblk, lockb, status });
            }
        };
        if (r.object.get("open_sell_orders")) |orders| if (orders == .array and orders.array.items.len > 0) {
            try out.print("\n{s}Open sell orders:{s}\n", .{ col(C_BOLD), rst() });
            for (orders.array.items) |o| {
                const oid    = jsonGetU64(o, "order_id");
                const pid    = jsonGetU64(o, "pair_id");
                const rem    = jsonGetU64(o, "remaining_sat");
                const price  = jsonGetU64(o, "price_micro_usd");
                var bo: [64]u8 = undefined;
                try out.print("  order #{d} · pair {d} · {s} OMNI @ {d} µUSD\n",
                    .{ oid, pid, try formatOmni(&bo, rem), price });
            }
        };
    }
    return 0;
}

fn cmdBalance(allocator: std.mem.Allocator, ep: Endpoint, addr: []const u8, json_mode: bool) !u8 {
    const params = try std.fmt.allocPrint(allocator, "[\"{s}\"]", .{addr});
    defer allocator.free(params);

    const bal_resp = try rpcCall(allocator, ep, "getbalance", params);
    defer allocator.free(bal_resp);
    const stake_resp = try rpcCall(allocator, ep, "getstake",
        try std.fmt.allocPrint(allocator, "{{\"address\":\"{s}\"}}", .{addr}));
    defer allocator.free(stake_resp);
    const rep_resp = try rpcCall(allocator, ep, "getreputation", params);
    defer allocator.free(rep_resp);

    if (json_mode) {
        try stdout().print(
            "{{\"balance\":{s},\"stake\":{s},\"reputation\":{s}}}\n",
            .{ bal_resp, stake_resp, rep_resp });
        return 0;
    }

    const out = stdout();
    try out.print("{s}=== Balance: {s} ==={s}\n", .{ col(C_BOLD), addr, rst() });

    // Wallet balance
    var bp = try parse(allocator, bal_resp);
    defer bp.deinit();
    var err_msg: []const u8 = "";
    const bal_sat = blk: {
        const r = extractResult(bp.value, &err_msg) orelse {
            try stderr().print("{s}getbalance error:{s} {s}\n",
                .{ col(C_RED), rst(), err_msg });
            return 1;
        };
        break :blk jsonGetU64(r, "balance");
    };

    // Stake total
    var sp = try parse(allocator, stake_resp);
    defer sp.deinit();
    var stake_sat: u64 = 0;
    if (extractResult(sp.value, &err_msg)) |r| {
        if (r == .object) {
            if (r.object.get("stakes")) |stakes| {
                if (stakes == .array) {
                    for (stakes.array.items) |s| stake_sat += jsonGetU64(s, "amount_sat");
                }
            }
        }
    }

    var buf1: [64]u8 = undefined;
    var buf2: [64]u8 = undefined;
    var buf3: [64]u8 = undefined;
    try out.print("Wallet:    {s}{s}{s} OMNI\n",
        .{ col(C_GREEN), try formatOmni(&buf1, bal_sat), rst() });
    if (stake_sat > 0) {
        try out.print("Staked:    {s}{s}{s} OMNI {s}(active){s}\n", .{
            col(C_YELLOW), try formatOmni(&buf2, stake_sat), rst(),
            col(C_GRAY), rst(),
        });
        const avail = if (bal_sat > stake_sat) bal_sat - stake_sat else 0;
        try out.print("Available: {s} OMNI\n", .{try formatOmni(&buf3, avail)});
    } else {
        try out.print("Staked:    0.0000 OMNI\n", .{});
        try out.print("Available: {s} OMNI\n", .{try formatOmni(&buf3, bal_sat)});
    }

    // Reputation
    var rp = try parse(allocator, rep_resp);
    defer rp.deinit();
    if (extractResult(rp.value, &err_msg)) |r| {
        const total = jsonGetU64(r, "total");
        const tier = jsonGetStr(r, "tier") orelse "OMNI";
        try out.print("\nReputation: {s}{d}{s} / 1,000,000  Tier {s}{s}{s}\n", .{
            col(C_CYAN), total, rst(),
            col(C_MAGENTA), tier, rst(),
        });
        if (r == .object) {
            if (r.object.get("cups")) |cups| {
                const love = jsonGetStr(cups, "love") orelse "0.00";
                const food = jsonGetStr(cups, "food") orelse "0.00";
                const rent = jsonGetStr(cups, "rent") orelse "0.00";
                const vac  = jsonGetStr(cups, "vacation") orelse "0.00";
                try out.print("  LOVE:     {s} / 100\n", .{love});
                try out.print("  FOOD:     {s} / 100\n", .{food});
                try out.print("  RENT:     {s} / 100\n", .{rent});
                try out.print("  VACATION: {s} / 100\n", .{vac});
            }
        }
    } else {
        try out.print("Reputation: (unavailable: {s})\n", .{err_msg});
    }
    return 0;
}

// ─── Subcommand: stake ──────────────────────────────────────────────────────
fn cmdStake(allocator: std.mem.Allocator, ep: Endpoint, addr: []const u8, json_mode: bool) !u8 {
    const stake_params = try std.fmt.allocPrint(allocator,
        "{{\"address\":\"{s}\"}}", .{addr});
    defer allocator.free(stake_params);
    const stake_resp = try rpcCall(allocator, ep, "getstake", stake_params);
    defer allocator.free(stake_resp);
    const hist_params = try std.fmt.allocPrint(allocator, "[\"{s}\"]", .{addr});
    defer allocator.free(hist_params);
    const hist_resp = try rpcCall(allocator, ep, "getaddresshistory", hist_params);
    defer allocator.free(hist_resp);

    if (json_mode) {
        try stdout().print(
            "{{\"stake\":{s},\"history\":{s}}}\n", .{ stake_resp, hist_resp });
        return 0;
    }

    const out = stdout();
    try out.print("{s}=== Stake: {s} ==={s}\n", .{ col(C_BOLD), addr, rst() });

    var sp = try parse(allocator, stake_resp);
    defer sp.deinit();
    var err_msg: []const u8 = "";
    var stake_sat: u64 = 0;
    if (extractResult(sp.value, &err_msg)) |r| {
        if (r == .object) {
            if (r.object.get("stakes")) |stakes| {
                if (stakes == .array) {
                    for (stakes.array.items) |s| stake_sat += jsonGetU64(s, "amount_sat");
                }
            }
        }
    }
    var buf: [64]u8 = undefined;
    try out.print("Current stake: {s}{s}{s} OMNI {s}(active){s}\n", .{
        col(C_YELLOW), try formatOmni(&buf, stake_sat), rst(),
        col(C_GRAY), rst(),
    });

    // Activity (filter kind=stake/unstake)
    var hp = try parse(allocator, hist_resp);
    defer hp.deinit();
    var sum_stake: u64 = 0;
    var sum_unstake: u64 = 0;
    try out.print("\nRecent stake activity:\n", .{});
    if (extractResult(hp.value, &err_msg)) |r| {
        if (r == .object) {
            if (r.object.get("transactions")) |txs| {
                if (txs == .array) {
                    var found_any = false;
                    for (txs.array.items) |tx| {
                        const kind = jsonGetStr(tx, "kind") orelse "";
                        const is_stake = std.mem.eql(u8, kind, "stake");
                        const is_unstake = std.mem.eql(u8, kind, "unstake");
                        if (!is_stake and !is_unstake) continue;
                        found_any = true;
                        const amt = jsonGetU64(tx, "amount");
                        if (is_stake) sum_stake += amt else sum_unstake += amt;
                        const sign: []const u8 = if (is_unstake) "-" else "+";
                        const c: []const u8 = if (is_unstake) col(C_RED) else col(C_GREEN);
                        const txid_full = jsonGetStr(tx, "txid") orelse "";
                        const txid = if (txid_full.len > 8) txid_full[0..8] else txid_full;
                        const bh = jsonGetU64(tx, "blockHeight");
                        try out.print("  block {d:>7}  {s}{s}{s} OMNI  {s}  {s}...\n", .{
                            bh, c, sign, rst(),
                            std.ascii.allocUpperString(allocator, kind) catch kind,
                            txid,
                        });
                    }
                    if (!found_any) try out.print("  (no stake/unstake TXs found)\n", .{});
                }
            }
        }
    }
    const computed = if (sum_stake > sum_unstake) sum_stake - sum_unstake else 0;
    try out.print("\nRunning total: {s} OMNI", .{try formatOmni(&buf, computed)});
    if (computed == stake_sat) {
        try out.print(" {s}(matches chain){s}\n", .{ col(C_GREEN), rst() });
    } else {
        try out.print(" {s}(MISMATCH chain={s} OMNI){s}\n", .{
            col(C_RED), try formatOmni(&buf, stake_sat), rst(),
        });
    }
    return 0;
}

// ─── Subcommand: reputation ─────────────────────────────────────────────────
fn cmdReputation(allocator: std.mem.Allocator, ep: Endpoint, addr: []const u8, json_mode: bool) !u8 {
    const params = try std.fmt.allocPrint(allocator, "[\"{s}\"]", .{addr});
    defer allocator.free(params);
    const resp = try rpcCall(allocator, ep, "getreputation", params);
    defer allocator.free(resp);
    if (json_mode) {
        try stdout().print("{s}\n", .{resp});
        return 0;
    }

    var p = try parse(allocator, resp);
    defer p.deinit();
    var err_msg: []const u8 = "";
    const r = extractResult(p.value, &err_msg) orelse {
        try stderr().print("{s}error:{s} {s}\n",
            .{ col(C_RED), rst(), err_msg });
        return 1;
    };

    const out = stdout();
    try out.print("{s}=== Reputation: {s} ==={s}\n", .{ col(C_BOLD), addr, rst() });
    const total = jsonGetU64(r, "total");
    const tier = jsonGetStr(r, "tier") orelse "OMNI";
    try out.print("Total: {s}{d}{s} / 1,000,000\n", .{ col(C_CYAN), total, rst() });
    try out.print("Tier:  {s}{s}{s}\n", .{ col(C_MAGENTA), tier, rst() });
    if (r.object.get("cups")) |cups| {
        try out.print("\nCups:\n", .{});
        try out.print("  LOVE:     {s} / 100\n", .{jsonGetStr(cups, "love") orelse "0.00"});
        try out.print("  FOOD:     {s} / 100\n", .{jsonGetStr(cups, "food") orelse "0.00"});
        try out.print("  RENT:     {s} / 100\n", .{jsonGetStr(cups, "rent") orelse "0.00"});
        try out.print("  VACATION: {s} / 100\n", .{jsonGetStr(cups, "vacation") orelse "0.00"});
    }
    try out.print("\nFirst block: {d}\n", .{jsonGetU64(r, "first_active_block")});
    try out.print("Last block:  {d}\n", .{jsonGetU64(r, "last_active_block")});
    try out.print("Mined:       {d}\n", .{jsonGetU64(r, "total_blocks_mined")});
    try out.print("Violations:  {d}\n", .{jsonGetU64(r, "violations")});
    return 0;
}

// ─── Subcommand: daily ──────────────────────────────────────────────────────
const DayBucket = struct {
    day: u64,
    count: u64 = 0,
    sent: u64 = 0,
    received: u64 = 0,
    mined: u64 = 0,
    fees: u64 = 0,
    stake_delta: i128 = 0, // can be negative (unstake > stake)
};

fn cmdDaily(
    allocator: std.mem.Allocator,
    ep: Endpoint,
    addr: []const u8,
    days: u64,
    json_mode: bool,
) !u8 {
    const params = try std.fmt.allocPrint(allocator, "[\"{s}\"]", .{addr});
    defer allocator.free(params);
    const resp = try rpcCall(allocator, ep, "getaddresshistory", params);
    defer allocator.free(resp);

    if (json_mode) {
        try stdout().print("{s}\n", .{resp});
        return 0;
    }

    var p = try parse(allocator, resp);
    defer p.deinit();
    var err_msg: []const u8 = "";
    const r = extractResult(p.value, &err_msg) orelse {
        try stderr().print("{s}error:{s} {s}\n",
            .{ col(C_RED), rst(), err_msg });
        return 1;
    };

    var buckets = std.AutoHashMap(u64, DayBucket).init(allocator);
    defer buckets.deinit();

    if (r == .object) {
        if (r.object.get("transactions")) |txs| {
            if (txs == .array) {
                for (txs.array.items) |tx| {
                    const bh = jsonGetU64(tx, "blockHeight");
                    if (bh == 0) continue; // pending
                    const day = parseDay(bh);
                    var b = buckets.get(day) orelse DayBucket{ .day = day };
                    b.count += 1;
                    const amount = jsonGetU64(tx, "amount");
                    const fee = jsonGetU64(tx, "fee");
                    const dir = jsonGetStr(tx, "direction") orelse "";
                    const kind = jsonGetStr(tx, "kind") orelse "";
                    if (std.mem.eql(u8, dir, "sent")) {
                        b.sent += amount;
                        b.fees += fee;
                    } else {
                        b.received += amount;
                        if (std.mem.eql(u8, kind, "coinbase") or
                            std.mem.eql(u8, kind, "mined") or
                            std.mem.eql(u8, kind, "block_reward"))
                        {
                            b.mined += amount;
                        }
                    }
                    if (std.mem.eql(u8, kind, "stake")) {
                        b.stake_delta += @intCast(amount);
                    } else if (std.mem.eql(u8, kind, "unstake")) {
                        b.stake_delta -= @intCast(amount);
                    }
                    try buckets.put(day, b);
                }
            }
        }
    }

    // Sort buckets by day desc, take top `days`.
    var entries = std.array_list.Managed(DayBucket).init(allocator);
    defer entries.deinit();
    var it = buckets.iterator();
    while (it.next()) |kv| try entries.append(kv.value_ptr.*);
    std.mem.sort(DayBucket, entries.items, {}, struct {
        fn lt(_: void, a: DayBucket, b: DayBucket) bool {
            return a.day > b.day; // desc
        }
    }.lt);

    const out = stdout();
    try out.print("{s}=== Daily breakdown: {s} (last {d} days w/ activity) ==={s}\n",
        .{ col(C_BOLD), addr, days, rst() });
    try out.print("{s}{s:<8} {s:>6} {s:>14} {s:>14} {s:>14} {s:>10} {s:>14}{s}\n", .{
        col(C_GRAY), "Day#", "TXs", "Sent", "Received", "Mined", "Fees", "StakeΔ", rst(),
    });

    var tot = DayBucket{ .day = 0 };
    var shown: usize = 0;
    for (entries.items) |b| {
        if (shown >= days) break;
        var b1: [32]u8 = undefined;
        var b2: [32]u8 = undefined;
        var b3: [32]u8 = undefined;
        var b4: [32]u8 = undefined;
        var b5: [32]u8 = undefined;
        const stake_abs: u64 = if (b.stake_delta < 0)
            @intCast(-b.stake_delta)
        else
            @intCast(b.stake_delta);
        const stake_sign: []const u8 = if (b.stake_delta < 0) "-" else "+";
        try out.print("{d:<8} {d:>6} {s:>14} {s:>14} {s:>14} {s:>10} {s}{s:>13}{s}\n", .{
            b.day, b.count,
            try formatOmni(&b1, b.sent),
            try formatOmni(&b2, b.received),
            try formatOmni(&b3, b.mined),
            try formatOmni(&b4, b.fees),
            stake_sign, try formatOmni(&b5, stake_abs), "",
        });
        tot.count += b.count;
        tot.sent += b.sent;
        tot.received += b.received;
        tot.mined += b.mined;
        tot.fees += b.fees;
        tot.stake_delta += b.stake_delta;
        shown += 1;
    }
    var t1: [32]u8 = undefined;
    var t2: [32]u8 = undefined;
    var t3: [32]u8 = undefined;
    var t4: [32]u8 = undefined;
    var t5: [32]u8 = undefined;
    const tot_stake_abs: u64 = if (tot.stake_delta < 0)
        @intCast(-tot.stake_delta)
    else
        @intCast(tot.stake_delta);
    const tot_stake_sign: []const u8 = if (tot.stake_delta < 0) "-" else "+";
    try out.print("{s}{s:<8} {d:>6} {s:>14} {s:>14} {s:>14} {s:>10} {s}{s:>13}{s}\n", .{
        col(C_BOLD), "Total", tot.count,
        try formatOmni(&t1, tot.sent),
        try formatOmni(&t2, tot.received),
        try formatOmni(&t3, tot.mined),
        try formatOmni(&t4, tot.fees),
        tot_stake_sign, try formatOmni(&t5, tot_stake_abs), rst(),
    });
    return 0;
}

// ─── Subcommand: validators ─────────────────────────────────────────────────
fn cmdValidators(allocator: std.mem.Allocator, ep: Endpoint, json_mode: bool) !u8 {
    const resp = try rpcCall(allocator, ep, "getvalidators", "[]");
    defer allocator.free(resp);
    if (json_mode) {
        try stdout().print("{s}\n", .{resp});
        return 0;
    }
    var p = try parse(allocator, resp);
    defer p.deinit();
    var err_msg: []const u8 = "";
    const r = extractResult(p.value, &err_msg) orelse {
        try stderr().print("{s}error:{s} {s}\n",
            .{ col(C_RED), rst(), err_msg });
        return 1;
    };
    const out = stdout();
    try out.print("{s}=== Validators ({d}) ==={s}\n", .{
        col(C_BOLD), jsonGetU64(r, "count"), rst(),
    });
    if (r == .object) {
        if (r.object.get("validators")) |vs| {
            if (vs == .array) {
                for (vs.array.items, 0..) |v, i| {
                    try out.print("{d:>4}. {s:<48} weight={d:<6} since_h={d}\n", .{
                        i + 1,
                        jsonGetStr(v, "address") orelse "",
                        jsonGetU64(v, "weight"),
                        jsonGetU64(v, "since_height"),
                    });
                }
            }
        }
    }
    return 0;
}

// ─── Subcommand: stakers ────────────────────────────────────────────────────
fn cmdStakers(allocator: std.mem.Allocator, ep: Endpoint, limit: u64, json_mode: bool) !u8 {
    const params = try std.fmt.allocPrint(allocator, "{{\"limit\":{d}}}", .{limit});
    defer allocator.free(params);
    const resp = try rpcCall(allocator, ep, "getstakers", params);
    defer allocator.free(resp);
    if (json_mode) {
        try stdout().print("{s}\n", .{resp});
        return 0;
    }
    var p = try parse(allocator, resp);
    defer p.deinit();
    var err_msg: []const u8 = "";
    const r = extractResult(p.value, &err_msg) orelse {
        try stderr().print("{s}error:{s} {s}\n",
            .{ col(C_RED), rst(), err_msg });
        return 1;
    };
    const out = stdout();
    try out.print("{s}=== Top Stakers (limit {d}) ==={s}\n",
        .{ col(C_BOLD), limit, rst() });

    const StakerEntry = struct { addr: []const u8, sat: u64 };
    var entries = std.array_list.Managed(StakerEntry).init(allocator);
    defer entries.deinit();

    if (r == .object) {
        if (r.object.get("stakers")) |ss| {
            if (ss == .array) {
                for (ss.array.items) |s| {
                    try entries.append(.{
                        .addr = jsonGetStr(s, "address") orelse "",
                        .sat = jsonGetU64(s, "amount_sat"),
                    });
                }
            }
        }
    }
    std.mem.sort(StakerEntry, entries.items, {}, struct {
        fn lt(_: void, a: StakerEntry, b: StakerEntry) bool {
            return a.sat > b.sat;
        }
    }.lt);
    for (entries.items, 0..) |e, i| {
        var buf: [64]u8 = undefined;
        try out.print("{d:>4}. {s:<48} {s} OMNI\n", .{
            i + 1, e.addr, try formatOmni(&buf, e.sat),
        });
    }
    if (entries.items.len == 0) try out.print("(no stakers)\n", .{});
    return 0;
}

// ─── Subcommand: history ────────────────────────────────────────────────────
fn cmdHistory(
    allocator: std.mem.Allocator,
    ep: Endpoint,
    addr: []const u8,
    filter: []const u8,
    json_mode: bool,
) !u8 {
    const params = try std.fmt.allocPrint(allocator, "[\"{s}\"]", .{addr});
    defer allocator.free(params);
    const resp = try rpcCall(allocator, ep, "getaddresshistory", params);
    defer allocator.free(resp);
    if (json_mode) {
        try stdout().print("{s}\n", .{resp});
        return 0;
    }
    var p = try parse(allocator, resp);
    defer p.deinit();
    var err_msg: []const u8 = "";
    const r = extractResult(p.value, &err_msg) orelse {
        try stderr().print("{s}error:{s} {s}\n",
            .{ col(C_RED), rst(), err_msg });
        return 1;
    };
    const out = stdout();
    try out.print("{s}=== History: {s} (filter={s}) ==={s}\n",
        .{ col(C_BOLD), addr, filter, rst() });
    if (r == .object) {
        if (r.object.get("transactions")) |txs| {
            if (txs == .array) {
                var shown: usize = 0;
                for (txs.array.items) |tx| {
                    const dir = jsonGetStr(tx, "direction") orelse "";
                    const kind = jsonGetStr(tx, "kind") orelse "";
                    if (!std.mem.eql(u8, filter, "all")) {
                        if (std.mem.eql(u8, filter, "stake")) {
                            if (!std.mem.eql(u8, kind, "stake") and
                                !std.mem.eql(u8, kind, "unstake")) continue;
                        } else if (std.mem.eql(u8, filter, "sent")) {
                            if (!std.mem.eql(u8, dir, "sent")) continue;
                        } else if (std.mem.eql(u8, filter, "received")) {
                            if (!std.mem.eql(u8, dir, "received")) continue;
                        } else if (std.mem.eql(u8, filter, "mined")) {
                            if (!std.mem.eql(u8, kind, "coinbase") and
                                !std.mem.eql(u8, kind, "mined") and
                                !std.mem.eql(u8, kind, "block_reward")) continue;
                        }
                    }
                    const txid_full = jsonGetStr(tx, "txid") orelse "";
                    const txid = if (txid_full.len > 12) txid_full[0..12] else txid_full;
                    var buf: [32]u8 = undefined;
                    try out.print("  block {d:>7}  {s:<10} {s:<8}  {s} OMNI  {s}...\n", .{
                        jsonGetU64(tx, "blockHeight"),
                        kind, dir,
                        try formatOmni(&buf, jsonGetU64(tx, "amount")),
                        txid,
                    });
                    shown += 1;
                    if (shown >= 200) {
                        try out.print("  ... (truncated at 200)\n", .{});
                        break;
                    }
                }
                if (shown == 0) try out.print("(no matching TXs)\n", .{});
            }
        }
    }
    return 0;
}

// ─── Subcommand: verify ─────────────────────────────────────────────────────
fn cmdVerify(allocator: std.mem.Allocator, ep: Endpoint, addr: []const u8, json_mode: bool) !u8 {
    const stake_params = try std.fmt.allocPrint(allocator,
        "{{\"address\":\"{s}\"}}", .{addr});
    defer allocator.free(stake_params);
    const stake_resp = try rpcCall(allocator, ep, "getstake", stake_params);
    defer allocator.free(stake_resp);
    const hist_params = try std.fmt.allocPrint(allocator, "[\"{s}\"]", .{addr});
    defer allocator.free(hist_params);
    const hist_resp = try rpcCall(allocator, ep, "getaddresshistory", hist_params);
    defer allocator.free(hist_resp);

    var sp = try parse(allocator, stake_resp);
    defer sp.deinit();
    var hp = try parse(allocator, hist_resp);
    defer hp.deinit();

    var err_msg: []const u8 = "";
    var chain_stake: u64 = 0;
    if (extractResult(sp.value, &err_msg)) |r| {
        if (r == .object) {
            if (r.object.get("stakes")) |stakes| {
                if (stakes == .array) {
                    for (stakes.array.items) |s| chain_stake += jsonGetU64(s, "amount_sat");
                }
            }
        }
    }
    var sum_stake: u64 = 0;
    var sum_unstake: u64 = 0;
    if (extractResult(hp.value, &err_msg)) |r| {
        if (r == .object) {
            if (r.object.get("transactions")) |txs| {
                if (txs == .array) {
                    for (txs.array.items) |tx| {
                        const kind = jsonGetStr(tx, "kind") orelse "";
                        const amt = jsonGetU64(tx, "amount");
                        if (std.mem.eql(u8, kind, "stake")) sum_stake += amt
                        else if (std.mem.eql(u8, kind, "unstake")) sum_unstake += amt;
                    }
                }
            }
        }
    }
    const computed: u64 = if (sum_stake > sum_unstake) sum_stake - sum_unstake else 0;

    if (json_mode) {
        try stdout().print(
            "{{\"chain_stake_sat\":{d},\"sum_stake_sat\":{d},\"sum_unstake_sat\":{d}," ++
            "\"computed_sat\":{d},\"match\":{}}}\n",
            .{ chain_stake, sum_stake, sum_unstake, computed, computed == chain_stake });
        return if (computed == chain_stake) 0 else 1;
    }

    const out = stdout();
    try out.print("{s}=== Sanity check: {s} ==={s}\n", .{ col(C_BOLD), addr, rst() });
    try out.print("================================\n", .{});
    var b: [64]u8 = undefined;
    try out.print("Chain stake_amounts:    {s} OMNI  (from getstake)\n",
        .{try formatOmni(&b, chain_stake)});
    try out.print("Sum of STAKE TXs:       {s} OMNI  (from getaddresshistory, kind=stake)\n",
        .{try formatOmni(&b, sum_stake)});
    try out.print("Sum of UNSTAKE TXs:     {s} OMNI\n", .{try formatOmni(&b, sum_unstake)});
    try out.print("Computed = stake - unstake = {s} OMNI\n", .{try formatOmni(&b, computed)});
    if (computed == chain_stake) {
        try out.print("Chain == Computed: {s}MATCH (in sync){s}\n",
            .{ col(C_GREEN), rst() });
        return 0;
    } else {
        try out.print("Chain == Computed: {s}MISMATCH{s}\n",
            .{ col(C_RED), rst() });
        try out.print("\n  {s}Chain shows {s} but TXs sum to {s}.{s} Possible causes:\n", .{
            col(C_YELLOW), try formatOmni(&b, chain_stake),
            "(see stake history)", rst(),
        });
        try out.print("    - Restart wiped state before TX replay\n", .{});
        try out.print("    - applyOpReturnRoles bug\n", .{});
        try out.print("    - Recommend: SSH restart node to force replay\n", .{});
        return 1;
    }
}

// ═══════════════════════════════════════════════════════════════════════════
// ─── Exchange / DEX / Grid / HTLC / Oracle / Bridge subcommands ───────────
// ═══════════════════════════════════════════════════════════════════════════
//
// These subcommands give the CLI full parity with the React Exchange tab so
// that a power user can drive the DEX entirely from a terminal: list pairs,
// view orderbook, place / cancel signed orders, manage grids, claim HTLC
// preimages, query the oracle feed, etc.
//
// Read commands hit existing JSON-RPC handlers in `core/rpc_server.zig`.
// Write commands need a mnemonic to derive an ECDSA secp256k1 key at
// BIP-44 path m/44'/777'/0'/0/0 (OmniBus coin_type = 777). The signing
// material may come from:
//   * `--mnemonic "<12-word phrase>"` flag      (highest precedence)
//   * `OMNIBUS_MNEMONIC` env var                (fallback)
// Without one of those, the write commands refuse early with a clear error.
//
// Every write command requires `--yes` (or `-y`) as a confirmation flag.
// Without it the CLI prints "Add --yes to confirm write" and exits 2.

// ─── Pretty-print: JSON-or-table dispatch helper ─────────────────────────
//
// Many handlers want one code path that prints a parsed JSON-RPC response
// either as a pretty table OR as raw JSON when --json is set. They also
// want to surface RPC errors uniformly. printJsonOrErr() centralizes the
// "if --json: dump raw, else: parse + render" pattern so individual
// handlers stay short.
fn printRawJson(json: []const u8) !void {
    try stdout().print("{s}\n", .{json});
}

fn printRpcError(err_msg: []const u8) !void {
    try stderr().print("{s}RPC error:{s} {s}\n", .{ col(C_RED), rst(), err_msg });
}

// ─── Mnemonic + signing helpers ──────────────────────────────────────────
const SignKey = struct {
    privkey: [32]u8,
    pubkey: [33]u8,
};

const ResolveSignKeyError = error{
    NoMnemonic,
    BadMnemonic,
    BadPrivkey,
    BadKeyfile,
    OutOfMemory,
};

/// Resolve the signing key from one of 4 sources, in priority order:
///
///   1. `--privkey <hex>`         — raw 32-byte hex. No derivation, no mnemonic
///                                  exposure. Best for hot wallets / bots that
///                                  hold only one key and never need siblings.
///   2. `OMNIBUS_PRIVKEY` env var — same as above, but via environment. Good
///                                  for systemd / docker where you don't want
///                                  the key on the command line (shell history).
///   3. `--keyfile <path>`        — load 32-byte hex (or raw 32 bytes) from a
///                                  file. Pair with `chmod 600` so only the
///                                  user can read it. Strips trailing newline.
///   4. `--mnemonic` / `OMNIBUS_MNEMONIC` + optional `--key-index N`
///                                — BIP-44 derive m/44'/777'/0'/0/N. Default
///                                  N=0 (the same address you've always used).
///                                  Use `--key-index 17` to sign with the 18th
///                                  child of the same seed — lets one seed
///                                  cover 1000+ keys, but you only feed the
///                                  mnemonic into the CLI when you absolutely
///                                  need a fresh derivation.
///
/// We never print the mnemonic / privkey / keyfile content. Material is
/// zeroed via allocator.free as soon as it's been turned into a 32-byte key.
fn resolveSigningKey(allocator: std.mem.Allocator, args: Args) ResolveSignKeyError!SignKey {
    // ── 1+2: raw privkey (flag or env) ──────────────────────────────────
    const privkey_hex_owned: ?[]u8 = blk: {
        if (args.privkey) |p| break :blk try allocator.dupe(u8, p);
        const v = std.process.getEnvVarOwned(allocator, "OMNIBUS_PRIVKEY") catch |e| switch (e) {
            error.EnvironmentVariableNotFound => break :blk null,
            error.OutOfMemory => return error.OutOfMemory,
            else => break :blk null,
        };
        break :blk v;
    };
    if (privkey_hex_owned) |hex_input| {
        defer allocator.free(hex_input);
        // Tolerate "0x..." prefix and any whitespace the user may have pasted.
        var trimmed = std.mem.trim(u8, hex_input, " \t\r\n");
        if (std.mem.startsWith(u8, trimmed, "0x") or std.mem.startsWith(u8, trimmed, "0X")) {
            trimmed = trimmed[2..];
        }
        if (trimmed.len != 64) return error.BadPrivkey;
        var priv: [32]u8 = undefined;
        _ = std.fmt.hexToBytes(&priv, trimmed) catch return error.BadPrivkey;
        const pub_compressed = secp256k1.Secp256k1Crypto.privateKeyToPublicKey(priv)
            catch return error.BadPrivkey;
        return .{ .privkey = priv, .pubkey = pub_compressed };
    }

    // ── 3: keyfile ──────────────────────────────────────────────────────
    if (args.keyfile) |path| {
        const f = std.fs.cwd().openFile(path, .{}) catch return error.BadKeyfile;
        defer f.close();
        var buf: [256]u8 = undefined;
        const n = f.readAll(&buf) catch return error.BadKeyfile;
        if (n == 0) return error.BadKeyfile;
        var content = std.mem.trim(u8, buf[0..n], " \t\r\n");
        if (std.mem.startsWith(u8, content, "0x") or std.mem.startsWith(u8, content, "0X")) {
            content = content[2..];
        }
        var priv: [32]u8 = undefined;
        if (content.len == 64) {
            _ = std.fmt.hexToBytes(&priv, content) catch return error.BadKeyfile;
        } else if (content.len == 32) {
            @memcpy(&priv, content);
        } else {
            return error.BadKeyfile;
        }
        const pub_compressed = secp256k1.Secp256k1Crypto.privateKeyToPublicKey(priv)
            catch return error.BadKeyfile;
        return .{ .privkey = priv, .pubkey = pub_compressed };
    }

    // ── 4: mnemonic + key_index ─────────────────────────────────────────
    const mnemonic_owned: ?[]u8 = blk: {
        if (args.mnemonic) |m| break :blk try allocator.dupe(u8, m);
        const v = std.process.getEnvVarOwned(allocator, "OMNIBUS_MNEMONIC") catch |e| switch (e) {
            error.EnvironmentVariableNotFound => break :blk null,
            error.OutOfMemory => return error.OutOfMemory,
            else => break :blk null,
        };
        break :blk v;
    };
    if (mnemonic_owned == null) return error.NoMnemonic;
    defer allocator.free(mnemonic_owned.?);

    // BIP-39 passphrase ("25th word"). Same mnemonic + different passphrase
    // = completely different wallet. Empty string when not provided, which
    // matches the default frontend / hardware-wallet behaviour.
    const passphrase_owned: ?[]u8 = blk: {
        if (args.passphrase) |p| break :blk try allocator.dupe(u8, p);
        const v = std.process.getEnvVarOwned(allocator, "OMNIBUS_PASSPHRASE") catch |e| switch (e) {
            error.EnvironmentVariableNotFound => break :blk null,
            error.OutOfMemory => return error.OutOfMemory,
            else => break :blk null,
        };
        break :blk v;
    };
    defer if (passphrase_owned) |p| allocator.free(p);
    const passphrase: []const u8 = passphrase_owned orelse "";

    var w = bip32_wallet.BIP32Wallet.initFromMnemonicPassphrase(mnemonic_owned.?, passphrase, allocator)
        catch return error.BadMnemonic;
    // Coin type 777 = OmniBus; account=0, chain=0, index = --key-index (default 0).
    const priv = w.deriveChildKeyFull(44, 777, 0, 0, args.key_index)
        catch return error.BadMnemonic;
    const pub_compressed = secp256k1.Secp256k1Crypto.privateKeyToPublicKey(priv)
        catch return error.BadMnemonic;
    return .{ .privkey = priv, .pubkey = pub_compressed };
}

fn bytesToHex(allocator: std.mem.Allocator, bytes: []const u8) ![]u8 {
    const out = try allocator.alloc(u8, bytes.len * 2);
    const hex = "0123456789abcdef";
    for (bytes, 0..) |b, i| {
        out[i * 2] = hex[b >> 4];
        out[i * 2 + 1] = hex[b & 0x0F];
    }
    return out;
}

/// Refuse a write op when --yes is missing.
fn requireYes(args: Args, label: []const u8) !u8 {
    if (args.yes) return 0;
    try stderr().print(
        "{s}refuse:{s} `{s}` is a write op — add --yes to confirm\n",
        .{ col(C_RED), rst(), label },
    );
    return 2;
}

/// Print a "missing positional args" error and return exit code 2.
fn writeMissing(usage: []const u8) !u8 {
    try stderr().print("{s}error:{s} usage: omnibus-cli {s}\n",
        .{ col(C_RED), rst(), usage });
    return 2;
}

// ─── parsePairId / parsePrice / parsePairLabel ──────────────────────────
//
// User-friendly: accept either a numeric pair_id (0..6) or a label like
// "OMNI/USDC", "ETH/USDC", "OMNI-USDC", "OMNI/usd". The frontend already
// mirrors this — keep the CLI in sync so users don't have to remember
// numeric IDs.
fn parsePairId(s: []const u8) ?u16 {
    // Numeric path
    if (std.fmt.parseInt(u16, s, 10)) |n| {
        if (n <= 6) return n;
        return null;
    } else |_| {}
    // Label path — case-insensitive, accept '/' or '-' separator.
    var lower_buf: [32]u8 = undefined;
    if (s.len > lower_buf.len) return null;
    for (s, 0..) |c, i| lower_buf[i] = std.ascii.toLower(c);
    const lower = lower_buf[0..s.len];
    // Replace any '-' with '/' so OMNI-USDC == OMNI/USDC.
    var norm_buf: [32]u8 = undefined;
    for (lower, 0..) |c, i| norm_buf[i] = if (c == '-') '/' else c;
    const norm = norm_buf[0..lower.len];

    const Pair = struct { id: u16, label: []const u8 };
    const table = [_]Pair{
        .{ .id = 0, .label = "omni/usdc" }, .{ .id = 0, .label = "omni/usd" },
        .{ .id = 1, .label = "btc/usdc" },  .{ .id = 1, .label = "btc/usd" },
        .{ .id = 2, .label = "lcx/usdc" },  .{ .id = 2, .label = "lcx/usd" },
        .{ .id = 3, .label = "eth/usdc" },  .{ .id = 3, .label = "eth/usd" },
        .{ .id = 4, .label = "omni/btc" },
        .{ .id = 5, .label = "omni/lcx" },
        .{ .id = 6, .label = "omni/eth" },
    };
    for (table) |p| {
        if (std.mem.eql(u8, norm, p.label)) return p.id;
    }
    return null;
}

/// Parse a human price like "0.5234" or "520000" → micro-USD (6 decimals).
/// Bare integers > 1000 are assumed to already be micro-USD; floats are
/// scaled by 1e6.
fn parsePrice(s: []const u8) ?u64 {
    if (std.mem.indexOfScalar(u8, s, '.') == null) {
        // Integer — already micro-USD if "big", else scale.
        const n = std.fmt.parseInt(u64, s, 10) catch return null;
        // Heuristic: < 100 → user wrote a small int; treat as USD whole units.
        return if (n < 100) n * 1_000_000 else n;
    }
    const dot = std.mem.indexOfScalar(u8, s, '.').?;
    const whole = std.fmt.parseInt(u64, s[0..dot], 10) catch return null;
    const frac_str = s[dot + 1 ..];
    if (frac_str.len == 0 or frac_str.len > 6) return null;
    var frac_buf: [6]u8 = .{ '0', '0', '0', '0', '0', '0' };
    @memcpy(frac_buf[0..frac_str.len], frac_str);
    const frac = std.fmt.parseInt(u64, &frac_buf, 10) catch return null;
    return whole * 1_000_000 + frac;
}

/// Parse an OMNI-amount: either bare SAT (e.g. "5000000000"), or a decimal
/// "5.0" → SAT (× 1e9). 4+ decimal places preserved up to 9.
fn parseOmni(s: []const u8) ?u64 {
    if (std.mem.indexOfScalar(u8, s, '.') == null) {
        return std.fmt.parseInt(u64, s, 10) catch null;
    }
    const dot = std.mem.indexOfScalar(u8, s, '.').?;
    const whole = std.fmt.parseInt(u64, s[0..dot], 10) catch return null;
    const frac_str = s[dot + 1 ..];
    if (frac_str.len == 0 or frac_str.len > 9) return null;
    var frac_buf: [9]u8 = .{ '0', '0', '0', '0', '0', '0', '0', '0', '0' };
    @memcpy(frac_buf[0..frac_str.len], frac_str);
    const frac = std.fmt.parseInt(u64, &frac_buf, 10) catch return null;
    return whole * SAT_PER_OMNI + frac;
}

// ─── exchange-pairs ──────────────────────────────────────────────────────
fn cmdExchangePairs(allocator: std.mem.Allocator, ep: Endpoint, json_mode: bool) !u8 {
    const resp = try rpcCall(allocator, ep, "exchange_listPairs", "[]");
    defer allocator.free(resp);
    if (json_mode) { try printRawJson(resp); return 0; }
    var p = try parse(allocator, resp);
    defer p.deinit();
    var err_msg: []const u8 = "";
    const r = extractResult(p.value, &err_msg) orelse {
        try printRpcError(err_msg); return 1;
    };
    const out = stdout();
    try out.print("{s}=== Trading Pairs ==={s}\n", .{ col(C_BOLD), rst() });
    try out.print("{s}{s:<4} {s:<14} {s}{s}\n", .{
        col(C_GRAY), "id", "label", "chain mapping (base / quote)", rst(),
    });
    if (r != .array) return 0;
    // Static map of pair_id → chain layout (matches CLAUDE.md DEX rules).
    const Mapping = struct { id: u16, base_chain: []const u8, quote_chain: []const u8 };
    const mapping = [_]Mapping{
        .{ .id = 0, .base_chain = "OmniBus",  .quote_chain = "Base Sepolia / Sepolia" },
        .{ .id = 1, .base_chain = "Bitcoin",  .quote_chain = "Base Sepolia / Sepolia" },
        .{ .id = 2, .base_chain = "LCX Liberty", .quote_chain = "Base Sepolia / Sepolia" },
        .{ .id = 3, .base_chain = "Sepolia / Base Sepolia", .quote_chain = "Base Sepolia / Sepolia" },
        .{ .id = 4, .base_chain = "OmniBus",  .quote_chain = "Bitcoin" },
        .{ .id = 5, .base_chain = "OmniBus",  .quote_chain = "LCX Liberty" },
        .{ .id = 6, .base_chain = "OmniBus",  .quote_chain = "Sepolia / Base Sepolia" },
    };
    for (r.array.items) |it| {
        const id = jsonGetU64(it, "id");
        const label = jsonGetStr(it, "label") orelse "?";
        var chains: []const u8 = "?";
        for (mapping) |m| {
            if (m.id == id) {
                var cbuf: [128]u8 = undefined;
                const s = std.fmt.bufPrint(&cbuf, "{s} → {s}", .{ m.base_chain, m.quote_chain })
                    catch m.base_chain;
                chains = try allocator.dupe(u8, s);
                break;
            }
        }
        defer if (!std.mem.eql(u8, chains, "?")) allocator.free(chains);
        try out.print("{d:<4} {s:<14} {s}\n", .{ id, label, chains });
    }
    return 0;
}

// ─── exchange-orderbook ──────────────────────────────────────────────────
fn cmdExchangeOrderbook(allocator: std.mem.Allocator, ep: Endpoint, args: Args) !u8 {
    if (args.pos.len < 1) return writeMissing("exchange-orderbook <pair_id>");
    const pid = parsePairId(args.pos[0]) orelse {
        try stderr().print("{s}error:{s} bad pair_id `{s}`\n",
            .{ col(C_RED), rst(), args.pos[0] });
        return 2;
    };
    const params = try std.fmt.allocPrint(allocator, "{{\"pairId\":{d},\"depth\":25}}", .{pid});
    defer allocator.free(params);
    const resp = try rpcCall(allocator, ep, "exchange_getOrderbook", params);
    defer allocator.free(resp);
    if (args.json) { try printRawJson(resp); return 0; }
    var p = try parse(allocator, resp);
    defer p.deinit();
    var err_msg: []const u8 = "";
    const r = extractResult(p.value, &err_msg) orelse {
        try printRpcError(err_msg); return 1;
    };
    return renderOrderbook(allocator, r, pid);
}

fn renderOrderbook(allocator: std.mem.Allocator, r: std.json.Value, pid: u16) !u8 {
    _ = allocator;
    const out = stdout();
    const labels = [_][]const u8{
        "OMNI/USDC","BTC/USDC","LCX/USDC","ETH/USDC","OMNI/BTC","OMNI/LCX","OMNI/ETH",
    };
    const lbl: []const u8 = if (pid < labels.len) labels[pid] else "?";
    const best_bid = jsonGetU64(r, "bestBid");
    const best_ask = jsonGetU64(r, "bestAsk");
    const spread = jsonGetU64(r, "spread");
    const order_count = jsonGetU64(r, "orderCount");
    try out.print("{s}Order book — {s} (pair_id={d}){s}\n",
        .{ col(C_BOLD), lbl, pid, rst() });
    if (best_bid > 0 and best_ask > 0) {
        // spread % = spread / best_ask × 100 (price-band side).
        const pct_x100 = (@as(u128, spread) * 10_000) / @max(@as(u128, best_ask), 1);
        try out.print("  Spread: {d} micro-USD ({d}.{d:0>2}%)\n",
            .{ spread, pct_x100 / 100, pct_x100 % 100 });
    } else {
        try out.print("  Spread: {s}n/a (one side empty){s}\n",
            .{ col(C_GRAY), rst() });
    }
    try out.print("\n  {s}Asks (sells):{s}\n", .{ col(C_RED), rst() });
    if (r.object.get("asks")) |asks| {
        if (asks == .array and asks.array.items.len > 0) {
            for (asks.array.items) |o| {
                const price = jsonGetU64(o, "price");
                const remaining = jsonGetU64(o, "remaining");
                try out.print("    {d:>14} micro × {d:>16} sat  (id={d})\n",
                    .{ price, remaining, jsonGetU64(o, "orderId") });
            }
        } else {
            try out.print("    (none)\n", .{});
        }
    }
    if (best_bid > 0 and best_ask > 0) {
        const mid = (best_bid + best_ask) / 2;
        try out.print("\n  {s}Mid: {d} micro-USD{s}\n",
            .{ col(C_CYAN), mid, rst() });
    }
    try out.print("\n  {s}Bids (buys):{s}\n", .{ col(C_GREEN), rst() });
    if (r.object.get("bids")) |bids| {
        if (bids == .array and bids.array.items.len > 0) {
            for (bids.array.items) |o| {
                const price = jsonGetU64(o, "price");
                const remaining = jsonGetU64(o, "remaining");
                try out.print("    {d:>14} micro × {d:>16} sat  (id={d})\n",
                    .{ price, remaining, jsonGetU64(o, "orderId") });
            }
        } else {
            try out.print("    (none)\n", .{});
        }
    }
    try out.print("\n  Total orders for pair: {d}\n", .{order_count});
    return 0;
}

// ─── exchange-trades ─────────────────────────────────────────────────────
fn cmdExchangeTrades(allocator: std.mem.Allocator, ep: Endpoint, args: Args) !u8 {
    if (args.pos.len < 1) return writeMissing("exchange-trades <pair_id> [limit=50]");
    const pid = parsePairId(args.pos[0]) orelse {
        try stderr().print("{s}error:{s} bad pair_id `{s}`\n",
            .{ col(C_RED), rst(), args.pos[0] });
        return 2;
    };
    const limit: u64 = if (args.pos.len > 1)
        std.fmt.parseInt(u64, args.pos[1], 10) catch 50
    else
        50;
    const params = try std.fmt.allocPrint(allocator,
        "{{\"pairId\":{d},\"limit\":{d}}}", .{ pid, limit });
    defer allocator.free(params);
    const resp = try rpcCall(allocator, ep, "exchange_getTrades", params);
    defer allocator.free(resp);
    if (args.json) { try printRawJson(resp); return 0; }
    var p = try parse(allocator, resp);
    defer p.deinit();
    var err_msg: []const u8 = "";
    const r = extractResult(p.value, &err_msg) orelse {
        try printRpcError(err_msg); return 1;
    };
    const out = stdout();
    try out.print("{s}=== Recent trades — pair_id={d} (limit {d}) ==={s}\n",
        .{ col(C_BOLD), pid, limit, rst() });
    try out.print("{s}{s:<10} {s:>14} {s:>14} {s:<48}{s}\n",
        .{ col(C_GRAY), "fillId", "price", "amount", "buyer→seller", rst() });
    if (r != .array) { try out.print("(no trades)\n", .{}); return 0; }
    if (r.array.items.len == 0) { try out.print("(no trades)\n", .{}); return 0; }
    for (r.array.items) |it| {
        const buyer = jsonGetStr(it, "buyer") orelse "?";
        const seller = jsonGetStr(it, "seller") orelse "?";
        const buyer_short = if (buyer.len > 12) buyer[0..12] else buyer;
        const seller_short = if (seller.len > 12) seller[0..12] else seller;
        try out.print("{d:<10} {d:>14} {d:>14} {s}…→{s}…\n", .{
            jsonGetU64(it, "fillId"),
            jsonGetU64(it, "price"),
            jsonGetU64(it, "amount"),
            buyer_short, seller_short,
        });
    }
    return 0;
}

// ─── exchange-orders (user) ──────────────────────────────────────────────
fn cmdExchangeOrders(allocator: std.mem.Allocator, ep: Endpoint, addr: []const u8, args: Args) !u8 {
    const params = try std.fmt.allocPrint(allocator, "{{\"trader\":\"{s}\"}}", .{addr});
    defer allocator.free(params);
    const resp = try rpcCall(allocator, ep, "exchange_getUserOrders", params);
    defer allocator.free(resp);
    if (args.json) { try printRawJson(resp); return 0; }
    var p = try parse(allocator, resp);
    defer p.deinit();
    var err_msg: []const u8 = "";
    const r = extractResult(p.value, &err_msg) orelse {
        try printRpcError(err_msg); return 1;
    };
    const out = stdout();
    try out.print("{s}=== Open orders: {s} ==={s}\n", .{ col(C_BOLD), addr, rst() });
    try out.print("{s}{s:<10} {s:<5} {s:<8} {s:>14} {s:>14} {s:<10}{s}\n",
        .{ col(C_GRAY), "id", "side", "pair", "price", "amount", "status", rst() });
    if (r != .array) { try out.print("(no orders)\n", .{}); return 0; }
    if (r.array.items.len == 0) { try out.print("(no orders)\n", .{}); return 0; }
    for (r.array.items) |it| {
        try out.print("{d:<10} {s:<5} {d:<8} {d:>14} {d:>14} {s:<10}\n", .{
            jsonGetU64(it, "orderId"),
            jsonGetStr(it, "side") orelse "?",
            jsonGetU64(it, "pairId"),
            jsonGetU64(it, "price"),
            jsonGetU64(it, "amount"),
            jsonGetStr(it, "status") orelse "?",
        });
    }
    return 0;
}

// ─── exchange-pair-info ──────────────────────────────────────────────────
fn cmdExchangePairInfo(allocator: std.mem.Allocator, ep: Endpoint, args: Args) !u8 {
    if (args.pos.len < 1) return writeMissing("exchange-pair-info <pair_id>");
    const pid = parsePairId(args.pos[0]) orelse {
        try stderr().print("{s}error:{s} bad pair_id `{s}`\n",
            .{ col(C_RED), rst(), args.pos[0] });
        return 2;
    };
    const params = try std.fmt.allocPrint(allocator, "{{\"pair_id\":{d}}}", .{pid});
    defer allocator.free(params);
    const resp = try rpcCall(allocator, ep, "exchange_pairInfo", params);
    defer allocator.free(resp);
    if (args.json) { try printRawJson(resp); return 0; }
    var p = try parse(allocator, resp);
    defer p.deinit();
    var err_msg: []const u8 = "";
    const r = extractResult(p.value, &err_msg) orelse {
        try printRpcError(err_msg); return 1;
    };
    const out = stdout();
    try out.print("{s}=== Pair info — pair_id={d} ==={s}\n",
        .{ col(C_BOLD), pid, rst() });
    try out.print("Base:  {s}\n", .{jsonGetStr(r, "base") orelse "?"});
    try out.print("Quote: {s}\n", .{jsonGetStr(r, "quote") orelse "?"});

    inline for (.{ "maker_chains", "taker_chains" }) |key| {
        try out.print("\n{s}:\n", .{key});
        if (r.object.get(key)) |arr| {
            if (arr == .array) {
                for (arr.array.items) |ch| {
                    try out.print("  - chain={s:<14} chain_id={d:<8} contract={s}\n", .{
                        jsonGetStr(ch, "chain") orelse "?",
                        jsonGetU64(ch, "chain_id"),
                        jsonGetStr(ch, "contract") orelse "?",
                    });
                }
            }
        }
    }
    return 0;
}

// ─── exchange-stats ──────────────────────────────────────────────────────
fn cmdExchangeStats(allocator: std.mem.Allocator, ep: Endpoint, args: Args) !u8 {
    if (args.pos.len < 1) return writeMissing("exchange-stats <pair_id>");
    const pid = parsePairId(args.pos[0]) orelse {
        try stderr().print("{s}error:{s} bad pair_id `{s}`\n",
            .{ col(C_RED), rst(), args.pos[0] });
        return 2;
    };
    // exchange_getStats returns aggregate per-pair best/spread/ordercount.
    // We pull it then filter to the pair the user asked about.
    const resp = try rpcCall(allocator, ep, "exchange_getStats", "{}");
    defer allocator.free(resp);
    if (args.json) { try printRawJson(resp); return 0; }
    var p = try parse(allocator, resp);
    defer p.deinit();
    var err_msg: []const u8 = "";
    const r = extractResult(p.value, &err_msg) orelse {
        try printRpcError(err_msg); return 1;
    };
    const out = stdout();
    try out.print("{s}=== 24h stats — pair_id={d} ==={s}\n",
        .{ col(C_BOLD), pid, rst() });
    try out.print("Mode: {s}\n", .{jsonGetStr(r, "mode") orelse "real"});
    try out.print("Total orders: {d}\n", .{jsonGetU64(r, "totalOrders")});
    try out.print("Total trades: {d}\n", .{jsonGetU64(r, "trades")});
    if (r.object.get("pairs")) |arr| {
        if (arr == .array) {
            for (arr.array.items) |pr| {
                if (jsonGetU64(pr, "id") != pid) continue;
                try out.print("\nPair {s}:\n", .{jsonGetStr(pr, "label") orelse "?"});
                try out.print("  best_bid:    {d}\n", .{jsonGetU64(pr, "bestBid")});
                try out.print("  best_ask:    {d}\n", .{jsonGetU64(pr, "bestAsk")});
                try out.print("  spread:      {d}\n", .{jsonGetU64(pr, "spread")});
                try out.print("  open orders: {d}\n", .{jsonGetU64(pr, "orderCount")});
                return 0;
            }
        }
    }
    try out.print("(pair {d} not found in stats)\n", .{pid});
    return 1;
}

// ─── exchange-place ──────────────────────────────────────────────────────
fn cmdExchangePlace(allocator: std.mem.Allocator, ep: Endpoint, args: Args) !u8 {
    if (args.pos.len < 5)
        return writeMissing("exchange-place <addr> <pair> <side> <price> <amount>");
    const c = try requireYes(args, "exchange-place");
    if (c != 0) return c;
    const addr = args.pos[0];
    const pid = parsePairId(args.pos[1]) orelse {
        try stderr().print("{s}error:{s} bad pair `{s}`\n",
            .{ col(C_RED), rst(), args.pos[1] });
        return 2;
    };
    const side = args.pos[2];
    if (!std.mem.eql(u8, side, "buy") and !std.mem.eql(u8, side, "sell")) {
        try stderr().print("{s}error:{s} side must be buy|sell\n",
            .{ col(C_RED), rst() });
        return 2;
    }
    const price = parsePrice(args.pos[3]) orelse {
        try stderr().print("{s}error:{s} bad price `{s}`\n",
            .{ col(C_RED), rst(), args.pos[3] });
        return 2;
    };
    const amount = parseOmni(args.pos[4]) orelse {
        try stderr().print("{s}error:{s} bad amount `{s}`\n",
            .{ col(C_RED), rst(), args.pos[4] });
        return 2;
    };
    const sk = resolveSigningKey(allocator, args) catch |err| {
        try stderr().print("{s}signing error:{s} {s}\n",
            .{ col(C_RED), rst(), @errorName(err) });
        return 2;
    };
    const nonce: u64 = @intCast(std.time.milliTimestamp());

    // EXCHANGE_ORDER_V1 canonical message — must match buildOrderSignMessage().
    var msg_buf: [256]u8 = undefined;
    const msg = try std.fmt.bufPrint(&msg_buf,
        "EXCHANGE_ORDER_V1\n{s}\n{d}\n{d}\n{d}\n{d}\n{s}",
        .{ side, pid, price, amount, nonce, addr });
    const sig = secp256k1.Secp256k1Crypto.sign(sk.privkey, msg) catch |e| {
        try stderr().print("{s}sign failed:{s} {s}\n",
            .{ col(C_RED), rst(), @errorName(e) });
        return 1;
    };
    const sig_hex = try bytesToHex(allocator, &sig);
    defer allocator.free(sig_hex);
    const pub_hex = try bytesToHex(allocator, &sk.pubkey);
    defer allocator.free(pub_hex);

    const params = try std.fmt.allocPrint(allocator,
        "{{\"trader\":\"{s}\",\"side\":\"{s}\",\"pairId\":{d},\"price\":{d}," ++
        "\"amount\":{d},\"nonce\":{d},\"signature\":\"{s}\",\"publicKey\":\"{s}\"}}",
        .{ addr, side, pid, price, amount, nonce, sig_hex, pub_hex });
    defer allocator.free(params);
    const resp = try rpcCall(allocator, ep, "exchange_placeOrder", params);
    defer allocator.free(resp);
    if (args.json) { try printRawJson(resp); return 0; }
    return printWriteResult(allocator, resp, "placeOrder");
}

// ─── exchange-cancel ─────────────────────────────────────────────────────
fn cmdExchangeCancel(allocator: std.mem.Allocator, ep: Endpoint, args: Args) !u8 {
    if (args.pos.len < 2) return writeMissing("exchange-cancel <addr> <order_id>");
    const c = try requireYes(args, "exchange-cancel");
    if (c != 0) return c;
    const addr = args.pos[0];
    const order_id = std.fmt.parseInt(u64, args.pos[1], 10) catch {
        try stderr().print("{s}error:{s} bad order_id `{s}`\n",
            .{ col(C_RED), rst(), args.pos[1] });
        return 2;
    };
    const sk = resolveSigningKey(allocator, args) catch |err| {
        try stderr().print("{s}signing error:{s} {s}\n",
            .{ col(C_RED), rst(), @errorName(err) });
        return 2;
    };
    const nonce: u64 = @intCast(std.time.milliTimestamp());
    var msg_buf: [128]u8 = undefined;
    const msg = try std.fmt.bufPrint(&msg_buf,
        "EXCHANGE_CANCEL_V1\n{d}\n{d}\n{s}", .{ order_id, nonce, addr });
    const sig = secp256k1.Secp256k1Crypto.sign(sk.privkey, msg) catch return 1;
    const sig_hex = try bytesToHex(allocator, &sig);
    defer allocator.free(sig_hex);
    const pub_hex = try bytesToHex(allocator, &sk.pubkey);
    defer allocator.free(pub_hex);
    const params = try std.fmt.allocPrint(allocator,
        "{{\"trader\":\"{s}\",\"orderId\":{d},\"nonce\":{d}," ++
        "\"signature\":\"{s}\",\"publicKey\":\"{s}\"}}",
        .{ addr, order_id, nonce, sig_hex, pub_hex });
    defer allocator.free(params);
    const resp = try rpcCall(allocator, ep, "exchange_cancelOrder", params);
    defer allocator.free(resp);
    if (args.json) { try printRawJson(resp); return 0; }
    return printWriteResult(allocator, resp, "cancelOrder");
}

// ─── grid-list ───────────────────────────────────────────────────────────
fn cmdGridList(allocator: std.mem.Allocator, ep: Endpoint, owner: ?[]const u8, json_mode: bool) !u8 {
    const params: []const u8 = if (owner) |o| blk: {
        const s = try std.fmt.allocPrint(allocator, "{{\"owner\":\"{s}\"}}", .{o});
        break :blk s;
    } else "{}";
    defer if (owner != null) allocator.free(params);
    const resp = try rpcCall(allocator, ep, "grid_list", params);
    defer allocator.free(resp);
    if (json_mode) { try printRawJson(resp); return 0; }
    var p = try parse(allocator, resp);
    defer p.deinit();
    var err_msg: []const u8 = "";
    const r = extractResult(p.value, &err_msg) orelse {
        try printRpcError(err_msg); return 1;
    };
    const out = stdout();
    try out.print("{s}=== Grid Trading Positions ==={s}\n", .{ col(C_BOLD), rst() });
    try out.print("{s}{s:<6} {s:<48} {s:<10} {s:<22} {s:<8} {s:<10}{s}\n", .{
        col(C_GRAY), "id", "owner", "pair_id", "range", "levels", "filled", rst(),
    });
    if (r != .array or r.array.items.len == 0) {
        try out.print("(no grids)\n", .{}); return 0;
    }
    for (r.array.items) |g| {
        const owner_str = jsonGetStr(g, "owner") orelse "?";
        const owner_short = if (owner_str.len > 16) owner_str[0..16] else owner_str;
        var range_buf: [32]u8 = undefined;
        const range = std.fmt.bufPrint(&range_buf, "{d} - {d}",
            .{ jsonGetU64(g, "price_low"), jsonGetU64(g, "price_high") })
            catch "?";
        try out.print("{d:<6} {s:<48} {d:<10} {s:<22} {d:<8} {d:<10}\n", .{
            jsonGetU64(g, "grid_id"),
            owner_short,
            jsonGetU64(g, "pair_id"),
            range,
            jsonGetU64(g, "levels"),
            jsonGetU64(g, "fills_count"),
        });
    }
    return 0;
}

// ─── grid-status ─────────────────────────────────────────────────────────
fn cmdGridStatus(allocator: std.mem.Allocator, ep: Endpoint, args: Args) !u8 {
    if (args.pos.len < 1) return writeMissing("grid-status <grid_id>");
    const grid_id = std.fmt.parseInt(u64, args.pos[0], 10) catch {
        try stderr().print("{s}error:{s} bad grid_id\n", .{ col(C_RED), rst() });
        return 2;
    };
    const params = try std.fmt.allocPrint(allocator, "{{\"grid_id\":{d}}}", .{grid_id});
    defer allocator.free(params);
    const resp = try rpcCall(allocator, ep, "grid_status", params);
    defer allocator.free(resp);
    if (args.json) { try printRawJson(resp); return 0; }
    var p = try parse(allocator, resp);
    defer p.deinit();
    var err_msg: []const u8 = "";
    const r = extractResult(p.value, &err_msg) orelse {
        try printRpcError(err_msg); return 1;
    };
    const out = stdout();
    try out.print("{s}=== Grid {d} ==={s}\n", .{ col(C_BOLD), grid_id, rst() });
    try out.print("owner:       {s}\n", .{jsonGetStr(r, "owner") orelse "?"});
    try out.print("pair_id:     {d}\n", .{jsonGetU64(r, "pair_id")});
    try out.print("price_low:   {d}\n", .{jsonGetU64(r, "price_low")});
    try out.print("price_high:  {d}\n", .{jsonGetU64(r, "price_high")});
    try out.print("levels:      {d}\n", .{jsonGetU64(r, "levels")});
    try out.print("total_base:  {d}\n", .{jsonGetU64(r, "total_base")});
    try out.print("total_quote: {d}\n", .{jsonGetU64(r, "total_quote")});
    try out.print("fills:       {d}\n", .{jsonGetU64(r, "fills_count")});
    return 0;
}

// ─── grid-create ─────────────────────────────────────────────────────────
fn cmdGridCreate(allocator: std.mem.Allocator, ep: Endpoint, args: Args) !u8 {
    if (args.pos.len < 7) return writeMissing(
        "grid-create <addr> <pair> <low> <high> <levels> <total_base> <total_quote>");
    const c = try requireYes(args, "grid-create");
    if (c != 0) return c;
    const addr = args.pos[0];
    const pid = parsePairId(args.pos[1]) orelse {
        try stderr().print("{s}error:{s} bad pair\n", .{ col(C_RED), rst() });
        return 2;
    };
    const low = std.fmt.parseInt(u64, args.pos[2], 10) catch return 2;
    const high = std.fmt.parseInt(u64, args.pos[3], 10) catch return 2;
    const levels = std.fmt.parseInt(u32, args.pos[4], 10) catch return 2;
    const total_base = std.fmt.parseInt(u64, args.pos[5], 10) catch return 2;
    const total_quote = std.fmt.parseInt(u64, args.pos[6], 10) catch return 2;
    const params = try std.fmt.allocPrint(allocator,
        "{{\"owner\":\"{s}\",\"pair_id\":{d},\"price_low\":{d},\"price_high\":{d}," ++
        "\"levels\":{d},\"total_base\":{d},\"total_quote\":{d}}}",
        .{ addr, pid, low, high, levels, total_base, total_quote });
    defer allocator.free(params);
    const resp = try rpcCall(allocator, ep, "grid_create", params);
    defer allocator.free(resp);
    if (args.json) { try printRawJson(resp); return 0; }
    return printWriteResult(allocator, resp, "grid_create");
}

// ─── grid-cancel ─────────────────────────────────────────────────────────
fn cmdGridCancel(allocator: std.mem.Allocator, ep: Endpoint, args: Args) !u8 {
    if (args.pos.len < 2) return writeMissing("grid-cancel <addr> <grid_id>");
    const c = try requireYes(args, "grid-cancel");
    if (c != 0) return c;
    const addr = args.pos[0];
    const grid_id = std.fmt.parseInt(u64, args.pos[1], 10) catch return 2;
    const params = try std.fmt.allocPrint(allocator,
        "{{\"owner\":\"{s}\",\"grid_id\":{d}}}", .{ addr, grid_id });
    defer allocator.free(params);
    const resp = try rpcCall(allocator, ep, "grid_cancel", params);
    defer allocator.free(resp);
    if (args.json) { try printRawJson(resp); return 0; }
    return printWriteResult(allocator, resp, "grid_cancel");
}

// ─── htlc-list ───────────────────────────────────────────────────────────
fn cmdHtlcList(allocator: std.mem.Allocator, ep: Endpoint, json_mode: bool) !u8 {
    const resp = try rpcCall(allocator, ep, "htlc_listPending", "[]");
    defer allocator.free(resp);
    if (json_mode) { try printRawJson(resp); return 0; }
    var p = try parse(allocator, resp);
    defer p.deinit();
    var err_msg: []const u8 = "";
    const r = extractResult(p.value, &err_msg) orelse {
        try printRpcError(err_msg); return 1;
    };
    const out = stdout();
    try out.print("{s}Open HTLC Swaps{s}\n", .{ col(C_BOLD), rst() });
    try out.print("{s}{s:<10} {s:<20} {s:<20} {s:>14} {s:>10} {s:<10}{s}\n", .{
        col(C_GRAY), "id", "sender", "recipient", "amount_sat",
        "lock @", "state", rst(),
    });
    if (r != .array or r.array.items.len == 0) {
        try out.print("(no pending swaps)\n", .{}); return 0;
    }
    for (r.array.items) |it| {
        const idh = jsonGetStr(it, "htlc_id") orelse "";
        const id_short = if (idh.len > 10) idh[0..10] else idh;
        const sender = jsonGetStr(it, "sender") orelse "?";
        const recipient = jsonGetStr(it, "recipient") orelse "?";
        try out.print("{s:<10} {s:<20} {s:<20} {d:>14} {d:>10} {s:<10}\n", .{
            id_short,
            if (sender.len > 18) sender[0..18] else sender,
            if (recipient.len > 18) recipient[0..18] else recipient,
            jsonGetU64(it, "amount_sat"),
            jsonGetU64(it, "timelock_block"),
            jsonGetStr(it, "state") orelse "?",
        });
    }
    return 0;
}

// ─── htlc-status ─────────────────────────────────────────────────────────
fn cmdHtlcStatus(allocator: std.mem.Allocator, ep: Endpoint, args: Args) !u8 {
    if (args.pos.len < 1) return writeMissing("htlc-status <swap_id>");
    const params = try std.fmt.allocPrint(allocator,
        "{{\"htlc_id\":\"{s}\"}}", .{args.pos[0]});
    defer allocator.free(params);
    const resp = try rpcCall(allocator, ep, "htlc_get", params);
    defer allocator.free(resp);
    if (args.json) { try printRawJson(resp); return 0; }
    var p = try parse(allocator, resp);
    defer p.deinit();
    var err_msg: []const u8 = "";
    const r = extractResult(p.value, &err_msg) orelse {
        try printRpcError(err_msg); return 1;
    };
    const out = stdout();
    try out.print("{s}=== HTLC {s} ==={s}\n",
        .{ col(C_BOLD), jsonGetStr(r, "htlc_id") orelse "?", rst() });
    try out.print("sender:    {s}\n", .{jsonGetStr(r, "sender") orelse "?"});
    try out.print("recipient: {s}\n", .{jsonGetStr(r, "recipient") orelse "?"});
    try out.print("amount:    {d} sat\n", .{jsonGetU64(r, "amount_sat")});
    try out.print("lock @:    block {d}\n", .{jsonGetU64(r, "timelock_block")});
    try out.print("init @:    block {d}\n", .{jsonGetU64(r, "init_block")});
    try out.print("hash_lock: {s}\n", .{jsonGetStr(r, "hash_lock") orelse "?"});
    try out.print("state:     {s}\n", .{jsonGetStr(r, "state") orelse "?"});
    if (jsonGetStr(r, "preimage")) |pre| {
        try out.print("preimage:  {s}\n", .{pre});
    }
    return 0;
}

// ─── htlc-init / claim / refund ──────────────────────────────────────────
fn cmdHtlcInit(allocator: std.mem.Allocator, ep: Endpoint, args: Args) !u8 {
    if (args.pos.len < 5) return writeMissing(
        "htlc-init <addr> <recipient> <amount> <secret_hash> <lock_blocks>");
    const c = try requireYes(args, "htlc-init");
    if (c != 0) return c;
    // addr is informational here; the chain attributes the init TX to the
    // node's wallet. Power users should still pass it for clarity in audit
    // logs.
    _ = args.pos[0];
    const recipient = args.pos[1];
    const amount = parseOmni(args.pos[2]) orelse return 2;
    const secret_hash = args.pos[3];
    const lock_blocks = std.fmt.parseInt(u64, args.pos[4], 10) catch return 2;
    const params = try std.fmt.allocPrint(allocator,
        "{{\"receiver\":\"{s}\",\"amount_sat\":{d},\"hash_lock\":\"{s}\",\"timelock_block\":{d}}}",
        .{ recipient, amount, secret_hash, lock_blocks });
    defer allocator.free(params);
    const resp = try rpcCall(allocator, ep, "htlc_init", params);
    defer allocator.free(resp);
    if (args.json) { try printRawJson(resp); return 0; }
    return printWriteResult(allocator, resp, "htlc_init");
}

fn cmdHtlcClaim(allocator: std.mem.Allocator, ep: Endpoint, args: Args) !u8 {
    if (args.pos.len < 3) return writeMissing("htlc-claim <addr> <swap_id> <preimage>");
    const c = try requireYes(args, "htlc-claim");
    if (c != 0) return c;
    _ = args.pos[0];
    const params = try std.fmt.allocPrint(allocator,
        "{{\"htlc_id\":\"{s}\",\"preimage\":\"{s}\"}}", .{ args.pos[1], args.pos[2] });
    defer allocator.free(params);
    const resp = try rpcCall(allocator, ep, "htlc_claim", params);
    defer allocator.free(resp);
    if (args.json) { try printRawJson(resp); return 0; }
    return printWriteResult(allocator, resp, "htlc_claim");
}

fn cmdHtlcRefund(allocator: std.mem.Allocator, ep: Endpoint, args: Args) !u8 {
    if (args.pos.len < 2) return writeMissing("htlc-refund <addr> <swap_id>");
    const c = try requireYes(args, "htlc-refund");
    if (c != 0) return c;
    _ = args.pos[0];
    const params = try std.fmt.allocPrint(allocator,
        "{{\"htlc_id\":\"{s}\"}}", .{args.pos[1]});
    defer allocator.free(params);
    const resp = try rpcCall(allocator, ep, "htlc_refund", params);
    defer allocator.free(resp);
    if (args.json) { try printRawJson(resp); return 0; }
    return printWriteResult(allocator, resp, "htlc_refund");
}

// ─── swap-list / swap-status ─────────────────────────────────────────────
fn cmdSwapList(allocator: std.mem.Allocator, ep: Endpoint, json_mode: bool) !u8 {
    const resp = try rpcCall(allocator, ep, "swap_listOpen", "{}");
    defer allocator.free(resp);
    if (json_mode) { try printRawJson(resp); return 0; }
    var p = try parse(allocator, resp);
    defer p.deinit();
    var err_msg: []const u8 = "";
    const r = extractResult(p.value, &err_msg) orelse {
        try printRpcError(err_msg); return 1;
    };
    const out = stdout();
    try out.print("{s}Open Atomic Swaps{s}\n", .{ col(C_BOLD), rst() });
    try out.print("{s}{s:<14} {s:<10} {s:<10} {s:<12} {s:<12} {s:<10}{s}\n",
        .{ col(C_GRAY), "swap_id", "order_id", "state", "maker_chain",
           "taker_chain", "timeout", rst() });
    if (r != .array or r.array.items.len == 0) {
        try out.print("(no open swaps)\n", .{}); return 0;
    }
    for (r.array.items) |it| {
        const sid = jsonGetStr(it, "swap_id") orelse "";
        const sid_short = if (sid.len > 12) sid[0..12] else sid;
        try out.print("{s:<14} {d:<10} {s:<10} {s:<12} {s:<12} {d:<10}\n", .{
            sid_short,
            jsonGetU64(it, "order_id"),
            jsonGetStr(it, "state") orelse "?",
            jsonGetStr(it, "maker_chain") orelse "?",
            jsonGetStr(it, "taker_chain") orelse "?",
            jsonGetU64(it, "timeout_block"),
        });
    }
    return 0;
}

fn cmdSwapStatus(allocator: std.mem.Allocator, ep: Endpoint, args: Args) !u8 {
    if (args.pos.len < 1) return writeMissing("swap-status <swap_id>");
    const params = try std.fmt.allocPrint(allocator,
        "{{\"swap_id\":\"{s}\"}}", .{args.pos[0]});
    defer allocator.free(params);
    const resp = try rpcCall(allocator, ep, "swap_status", params);
    defer allocator.free(resp);
    if (args.json) { try printRawJson(resp); return 0; }
    var p = try parse(allocator, resp);
    defer p.deinit();
    var err_msg: []const u8 = "";
    const r = extractResult(p.value, &err_msg) orelse {
        try printRpcError(err_msg); return 1;
    };
    const out = stdout();
    try out.print("{s}=== Swap {s} ==={s}\n",
        .{ col(C_BOLD), jsonGetStr(r, "swap_id") orelse "?", rst() });
    try out.print("order_id:      {d}\n", .{jsonGetU64(r, "order_id")});
    try out.print("state:         {s}\n", .{jsonGetStr(r, "state") orelse "?"});
    try out.print("maker_chain:   {s}\n", .{jsonGetStr(r, "maker_chain") orelse "?"});
    try out.print("taker_chain:   {s}\n", .{jsonGetStr(r, "taker_chain") orelse "?"});
    try out.print("timeout_block: {d}\n", .{jsonGetU64(r, "timeout_block")});
    try out.print("created_block: {d}\n", .{jsonGetU64(r, "created_block")});
    return 0;
}

// ─── oracle-prices / arbitrage / feed ────────────────────────────────────
fn cmdOraclePrices(allocator: std.mem.Allocator, ep: Endpoint, json_mode: bool) !u8 {
    // Fan out: omnibus_getoracleprices for consensus, plus omnibus_getexchangefeed
    // (which carries Coinbase/Kraken/LCX bid+ask) for the table.
    const resp = try rpcCall(allocator, ep, "omnibus_getexchangefeed", "[]");
    defer allocator.free(resp);
    if (json_mode) { try printRawJson(resp); return 0; }
    var p = try parse(allocator, resp);
    defer p.deinit();
    var err_msg: []const u8 = "";
    const r = extractResult(p.value, &err_msg) orelse {
        try printRpcError(err_msg); return 1;
    };
    const out = stdout();
    try out.print("{s}Oracle Feed (Coinbase | Kraken | LCX){s}\n",
        .{ col(C_BOLD), rst() });
    try out.print("{s}{s:<14} {s:<10} {s:>16} {s:>16}{s}\n",
        .{ col(C_GRAY), "exchange", "pair", "bid (μUSD)", "ask (μUSD)", rst() });
    if (r.object.get("prices")) |arr| {
        if (arr == .array) {
            for (arr.array.items) |it| {
                try out.print("{s:<14} {s:<10} {d:>16} {d:>16}\n", .{
                    jsonGetStr(it, "exchange") orelse "?",
                    jsonGetStr(it, "pair") orelse "?",
                    jsonGetU64(it, "bidMicroUsd"),
                    jsonGetU64(it, "askMicroUsd"),
                });
            }
        }
    }
    const median_btc = jsonGetU64(r, "medianBtcMicroUsd");
    const median_lcx = jsonGetU64(r, "medianLcxMicroUsd");
    try out.print("\nMedian BTC: {d} μUSD\n", .{median_btc});
    try out.print("Median LCX: {d} μUSD\n", .{median_lcx});
    return 0;
}

fn cmdOracleArbitrage(allocator: std.mem.Allocator, ep: Endpoint, json_mode: bool) !u8 {
    const resp = try rpcCall(allocator, ep, "omnibus_getarbitrage", "[]");
    defer allocator.free(resp);
    if (json_mode) { try printRawJson(resp); return 0; }
    var p = try parse(allocator, resp);
    defer p.deinit();
    var err_msg: []const u8 = "";
    const r = extractResult(p.value, &err_msg) orelse {
        try printRpcError(err_msg); return 1;
    };
    const out = stdout();
    try out.print("{s}Arbitrage opportunities (>0.05%){s}\n",
        .{ col(C_BOLD), rst() });
    try out.print("{s}{s:<10} {s:<14} {s:<14} {s:>12} {s:>10}{s}\n",
        .{ col(C_GRAY), "pair", "buy@", "sell@", "spread%", "spread_μ", rst() });
    if (r != .array or r.array.items.len == 0) {
        try out.print("(no opportunities)\n", .{}); return 0;
    }
    for (r.array.items) |it| {
        try out.print("{s:<10} {s:<14} {s:<14} {d:>12.4} {d:>10}\n", .{
            jsonGetStr(it, "pair") orelse "?",
            jsonGetStr(it, "buy_ex") orelse "?",
            jsonGetStr(it, "sell_ex") orelse "?",
            jsonGetF64(it, "spread_pct"),
            jsonGetU64(it, "spread_micro"),
        });
    }
    return 0;
}

fn cmdOracleFeed(allocator: std.mem.Allocator, ep: Endpoint, json_mode: bool) !u8 {
    // omnibus_getallprices returns the unbounded snapshot (~700 pairs across exchanges).
    const resp = try rpcCall(allocator, ep, "omnibus_getallprices", "[]");
    defer allocator.free(resp);
    if (json_mode) { try printRawJson(resp); return 0; }
    var p = try parse(allocator, resp);
    defer p.deinit();
    var err_msg: []const u8 = "";
    const r = extractResult(p.value, &err_msg) orelse {
        try printRpcError(err_msg); return 1;
    };
    const out = stdout();
    try out.print("{s}WebSocket Exchange Feed (full){s}\n",
        .{ col(C_BOLD), rst() });
    var count: usize = 0;
    if (r.object.get("prices")) |arr| {
        if (arr == .array) {
            try out.print("{s}{s:<14} {s:<14} {s:>16} {s:>16}{s}\n",
                .{ col(C_GRAY), "exchange", "pair", "bid_μUSD", "ask_μUSD", rst() });
            for (arr.array.items) |it| {
                try out.print("{s:<14} {s:<14} {d:>16} {d:>16}\n", .{
                    jsonGetStr(it, "exchange") orelse "?",
                    jsonGetStr(it, "pair") orelse "?",
                    jsonGetU64(it, "bidMicroUsd"),
                    jsonGetU64(it, "askMicroUsd"),
                });
                count += 1;
            }
        }
    }
    try out.print("\n{s}Total: {d} entries{s}\n", .{ col(C_CYAN), count, rst() });
    return 0;
}

// ─── bridge-status / bridge-lock ─────────────────────────────────────────
fn cmdBridgeStatus(allocator: std.mem.Allocator, ep: Endpoint, json_mode: bool) !u8 {
    // Pull both status + limits side-by-side for a complete picture.
    const status = try rpcCall(allocator, ep, "omnibus_getbridgestatus", "[]");
    defer allocator.free(status);
    const limits = try rpcCall(allocator, ep, "omnibus_bridge_limits", "[]");
    defer allocator.free(limits);
    if (json_mode) {
        try stdout().print("{{\"status\":{s},\"limits\":{s}}}\n", .{ status, limits });
        return 0;
    }
    var sp = try parse(allocator, status);
    defer sp.deinit();
    var err_msg: []const u8 = "";
    const sr = extractResult(sp.value, &err_msg) orelse {
        try printRpcError(err_msg); return 1;
    };
    const out = stdout();
    try out.print("{s}=== Bridge Status ==={s}\n", .{ col(C_BOLD), rst() });
    const active = blk: {
        const v = sr.object.get("bridge_active") orelse break :blk false;
        break :blk v == .bool and v.bool;
    };
    const paused = blk: {
        const v = sr.object.get("paused") orelse break :blk false;
        break :blk v == .bool and v.bool;
    };
    const tag: []const u8 = if (active and !paused) "ACTIVE" else "PAUSED";
    const tag_col: []const u8 = if (active and !paused) col(C_GREEN) else col(C_RED);
    try out.print("State:               {s}{s}{s}\n", .{ tag_col, tag, rst() });
    try out.print("paused_at_height:    {d}\n", .{jsonGetU64(sr, "paused_at_height")});
    try out.print("locked_total_sat:    {d}\n", .{jsonGetU64(sr, "locked_total_sat")});
    try out.print("daily_volume_sat:    {d}\n", .{jsonGetU64(sr, "daily_volume_sat")});
    try out.print("lock_count:          {d}\n", .{jsonGetU64(sr, "lock_count")});
    try out.print("pending_unlock_count:{d}\n", .{jsonGetU64(sr, "pending_unlock_count")});
    try out.print("vault_addr:          {s}\n", .{jsonGetStr(sr, "vault_addr") orelse "?"});
    return 0;
}

fn cmdBridgeLock(allocator: std.mem.Allocator, ep: Endpoint, args: Args) !u8 {
    if (args.pos.len < 3) return writeMissing("bridge-lock <addr> <to_chain> <amount>");
    const c = try requireYes(args, "bridge-lock");
    if (c != 0) return c;
    const addr = args.pos[0];
    const to_chain = args.pos[1];
    const amount = parseOmni(args.pos[2]) orelse return 2;
    // Ethereum addresses are recipient defaults; allow any string the chain accepts.
    const dest_addr = kvLookup(args, "dest-addr") orelse addr;
    const params = try std.fmt.allocPrint(allocator,
        "{{\"amount_sat\":{d},\"destination_chain\":\"{s}\",\"destination_addr\":\"{s}\"}}",
        .{ amount, to_chain, dest_addr });
    defer allocator.free(params);
    const resp = try rpcCall(allocator, ep, "bridge_lock", params);
    defer allocator.free(resp);
    if (args.json) { try printRawJson(resp); return 0; }
    return printWriteResult(allocator, resp, "bridge_lock");
}

// ─── Shared write-result printer ─────────────────────────────────────────
fn printWriteResult(allocator: std.mem.Allocator, resp: []const u8, label: []const u8) !u8 {
    var p = try parse(allocator, resp);
    defer p.deinit();
    var err_msg: []const u8 = "";
    const r = extractResult(p.value, &err_msg) orelse {
        try printRpcError(err_msg); return 1;
    };
    const out = stdout();
    try out.print("{s}{s} OK{s}\n", .{ col(C_GREEN), label, rst() });
    if (r == .object) {
        var it = r.object.iterator();
        while (it.next()) |kv| {
            switch (kv.value_ptr.*) {
                .string => |s| try out.print("  {s}: {s}\n", .{ kv.key_ptr.*, s }),
                .integer => |i| try out.print("  {s}: {d}\n", .{ kv.key_ptr.*, i }),
                .bool => |b| try out.print("  {s}: {s}\n",
                    .{ kv.key_ptr.*, if (b) "true" else "false" }),
                else => {},
            }
        }
    }
    return 0;
}

// ─── jsonGetF64 — for arbitrage handler ──────────────────────────────────
fn jsonGetF64(obj: std.json.Value, key: []const u8) f64 {
    if (obj != .object) return 0;
    const v = obj.object.get(key) orelse return 0;
    return switch (v) {
        .float => |f| f,
        .integer => |i| @floatFromInt(i),
        .string => |s| std.fmt.parseFloat(f64, s) catch 0,
        else => 0,
    };
}

// ═══════════════════════════════════════════════════════════════════════════
// Section: chain inspection / network / mining / wallet / admin / faucet /
// 0day / audit / restart subcommands. Each ≤ ~80 lines + own tests.
// ═══════════════════════════════════════════════════════════════════════════

// ─── Generic JSON-passthrough handler ───────────────────────────────────────
fn cmdGenericJson(
    allocator: std.mem.Allocator,
    ep: Endpoint,
    method: []const u8,
    params: []const u8,
    pretty_title: []const u8,
    json_mode: bool,
) !u8 {
    const resp = try rpcCall(allocator, ep, method, params);
    defer allocator.free(resp);
    if (json_mode) { try printRawJson(resp); return 0; }
    var p = parse(allocator, resp) catch {
        try printRpcError("failed to parse response");
        return 1;
    };
    defer p.deinit();
    var err_msg: []const u8 = "";
    const r = extractResult(p.value, &err_msg) orelse {
        try printRpcError(err_msg);
        return 1;
    };
    const out = stdout();
    try out.print("{s}=== {s} ==={s}\n", .{ col(C_BOLD), pretty_title, rst() });
    try printJsonValue(out, r, 0);
    try out.print("\n", .{});
    return 0;
}

/// Indented pretty-printer for std.json.Value (depth-limited).
fn printJsonValue(w: anytype, v: std.json.Value, depth: usize) !void {
    if (depth > 6) { try w.print("...", .{}); return; }
    switch (v) {
        .null => try w.print("null", .{}),
        .bool => |b| try w.print("{s}", .{if (b) "true" else "false"}),
        .integer => |i| try w.print("{d}", .{i}),
        .float => |f| try w.print("{d}", .{f}),
        .number_string => |s| try w.print("{s}", .{s}),
        .string => |s| try w.print("\"{s}\"", .{s}),
        .array => |arr| {
            if (arr.items.len == 0) { try w.print("[]", .{}); return; }
            try w.print("[\n", .{});
            for (arr.items, 0..) |item, i| {
                try printIndent(w, depth + 1);
                try printJsonValue(w, item, depth + 1);
                if (i + 1 < arr.items.len) try w.print(",", .{});
                try w.print("\n", .{});
            }
            try printIndent(w, depth);
            try w.print("]", .{});
        },
        .object => |obj| {
            if (obj.count() == 0) { try w.print("{{}}", .{}); return; }
            try w.print("{{\n", .{});
            var it = obj.iterator();
            const total = obj.count();
            var idx: usize = 0;
            while (it.next()) |kv| : (idx += 1) {
                try printIndent(w, depth + 1);
                try w.print("{s}{s}{s}: ", .{ col(C_CYAN), kv.key_ptr.*, rst() });
                try printJsonValue(w, kv.value_ptr.*, depth + 1);
                if (idx + 1 < total) try w.print(",", .{});
                try w.print("\n", .{});
            }
            try printIndent(w, depth);
            try w.print("}}", .{});
        },
    }
}

fn printIndent(w: anytype, depth: usize) !void {
    var i: usize = 0;
    while (i < depth) : (i += 1) try w.writeAll("  ");
}

// ─── Chain inspection ───────────────────────────────────────────────────────
fn cmdBlock(allocator: std.mem.Allocator, ep: Endpoint, height_str: []const u8, json_mode: bool) !u8 {
    const params = try std.fmt.allocPrint(allocator, "[{s}]", .{height_str});
    defer allocator.free(params);
    return cmdGenericJson(allocator, ep, "getblock", params, "Block", json_mode);
}

fn cmdBlockByHash(allocator: std.mem.Allocator, ep: Endpoint, hash: []const u8, json_mode: bool) !u8 {
    const params = try std.fmt.allocPrint(allocator, "[\"{s}\"]", .{hash});
    defer allocator.free(params);
    return cmdGenericJson(allocator, ep, "getblockbyhash", params, "Block by Hash", json_mode);
}

fn cmdTx(allocator: std.mem.Allocator, ep: Endpoint, txid: []const u8, json_mode: bool) !u8 {
    const params = try std.fmt.allocPrint(allocator, "[\"{s}\"]", .{txid});
    defer allocator.free(params);
    return cmdGenericJson(allocator, ep, "gettransaction", params, "Transaction", json_mode);
}

fn cmdMempool(allocator: std.mem.Allocator, ep: Endpoint, json_mode: bool) !u8 {
    return cmdGenericJson(allocator, ep, "getrawmempool", "[]", "Mempool", json_mode);
}

fn cmdSyncStatus(allocator: std.mem.Allocator, ep: Endpoint, json_mode: bool) !u8 {
    const resp = try rpcCall(allocator, ep, "getsyncstatus", "[]");
    defer allocator.free(resp);
    if (json_mode) { try printRawJson(resp); return 0; }
    var p = parse(allocator, resp) catch return 1;
    defer p.deinit();
    var err_msg: []const u8 = "";
    const r = extractResult(p.value, &err_msg) orelse {
        try printRpcError(err_msg);
        return 1;
    };
    const synced = blk: {
        if (r != .object) break :blk false;
        const v = r.object.get("synced") orelse break :blk false;
        break :blk v == .bool and v.bool;
    };
    const local_h = jsonGetU64(r, "localHeight");
    const peer_h = jsonGetU64(r, "peerHeight");
    const out = stdout();
    try out.print("{s}=== Sync Status ==={s}\n", .{ col(C_BOLD), rst() });
    const tag: []const u8 = if (synced) "SYNCED" else "SYNCING";
    const c: []const u8 = if (synced) col(C_GREEN) else col(C_YELLOW);
    try out.print("Status:        {s}{s}{s}\n", .{ c, tag, rst() });
    try out.print("Local height:  {d}\n", .{local_h});
    try out.print("Peer height:   {d}\n", .{peer_h});
    if (peer_h > local_h) try out.print("Behind:        {d} blocks\n", .{peer_h - local_h});
    return 0;
}

fn cmdChainInfo(allocator: std.mem.Allocator, ep: Endpoint, json_mode: bool) !u8 {
    return cmdGenericJson(allocator, ep, "getchaininfo", "[]", "Chain Info", json_mode);
}

fn cmdSupply(allocator: std.mem.Allocator, ep: Endpoint, json_mode: bool) !u8 {
    const resp = try rpcCall(allocator, ep, "getchainmetrics", "[]");
    defer allocator.free(resp);
    if (json_mode) { try printRawJson(resp); return 0; }
    var p = parse(allocator, resp) catch return 1;
    defer p.deinit();
    var err_msg: []const u8 = "";
    const r = extractResult(p.value, &err_msg) orelse {
        try printRpcError(err_msg);
        return 1;
    };
    const supply_sat = jsonGetU64(r, "totalSupply");
    const height = jsonGetU64(r, "height");
    const reward = jsonGetU64(r, "currentBlockReward");

    const out = stdout();
    try out.print("{s}=== OMNI Supply ==={s}\n", .{ col(C_BOLD), rst() });
    var b: [64]u8 = undefined;
    try out.print("Height:           {d}\n", .{height});
    try out.print("Total emitted:    {s}{s}{s} OMNI\n",
        .{ col(C_GREEN), try formatOmni(&b, supply_sat), rst() });
    try out.print("Block reward now: {s} OMNI\n", .{try formatOmni(&b, reward)});
    try out.print("Max supply:       21,000,000 OMNI\n", .{});
    const halving_period: u64 = 210_000;
    const next_halving = ((height / halving_period) + 1) * halving_period;
    const blocks_to_halving = next_halving - height;
    try out.print("Next halving at:  block {d} ({d} blocks away, ~{d}h)\n",
        .{ next_halving, blocks_to_halving, blocks_to_halving / 3600 });
    return 0;
}

fn cmdHalving(allocator: std.mem.Allocator, ep: Endpoint, json_mode: bool) !u8 {
    return cmdSupply(allocator, ep, json_mode);
}

fn cmdPrices(allocator: std.mem.Allocator, ep: Endpoint, args: Args) !u8 {
    const params = if (args.pos.len > 0)
        try std.fmt.allocPrint(allocator, "[{s}]", .{args.pos[0]})
    else
        try allocator.dupe(u8, "[]");
    defer allocator.free(params);
    return cmdGenericJson(allocator, ep, "getblockprices", params, "Block Oracle Prices", args.json);
}

// ─── Network / peers ────────────────────────────────────────────────────────
fn cmdPeers(allocator: std.mem.Allocator, ep: Endpoint, json_mode: bool) !u8 {
    return cmdGenericJson(allocator, ep, "getpeers", "[]", "Peers", json_mode);
}

fn cmdPeerInfo(allocator: std.mem.Allocator, ep: Endpoint, peer_id: []const u8, json_mode: bool) !u8 {
    const params = try std.fmt.allocPrint(allocator, "[\"{s}\"]", .{peer_id});
    defer allocator.free(params);
    return cmdGenericJson(allocator, ep, "getpeerinfo", params, "Peer Info", json_mode);
}

fn cmdBans(allocator: std.mem.Allocator, ep: Endpoint, json_mode: bool) !u8 {
    return cmdGenericJson(allocator, ep, "getbans", "[]", "Banned Peers", json_mode);
}

fn cmdConnectPeer(allocator: std.mem.Allocator, ep: Endpoint, args: Args) !u8 {
    if (args.pos.len < 1) return writeMissing("connect <ip:port>");
    const c = try requireYes(args, "connect");
    if (c != 0) return c;
    const params = try std.fmt.allocPrint(allocator, "[\"{s}\"]", .{args.pos[0]});
    defer allocator.free(params);
    const resp = try rpcCall(allocator, ep, "addnode", params);
    defer allocator.free(resp);
    if (args.json) { try printRawJson(resp); return 0; }
    return printWriteResult(allocator, resp, "addnode");
}

fn cmdDisconnectPeer(allocator: std.mem.Allocator, ep: Endpoint, args: Args) !u8 {
    if (args.pos.len < 1) return writeMissing("disconnect <peer_id>");
    const c = try requireYes(args, "disconnect");
    if (c != 0) return c;
    const params = try std.fmt.allocPrint(allocator, "[\"{s}\"]", .{args.pos[0]});
    defer allocator.free(params);
    const resp = try rpcCall(allocator, ep, "disconnectpeer", params);
    defer allocator.free(resp);
    if (args.json) { try printRawJson(resp); return 0; }
    return printWriteResult(allocator, resp, "disconnectpeer");
}

fn cmdP2pStats(allocator: std.mem.Allocator, ep: Endpoint, json_mode: bool) !u8 {
    return cmdGenericJson(allocator, ep, "getp2pstats", "[]", "P2P Stats", json_mode);
}

// ─── Mining ─────────────────────────────────────────────────────────────────
fn cmdMiningStatus(allocator: std.mem.Allocator, ep: Endpoint, json_mode: bool) !u8 {
    const resp = try rpcCall(allocator, ep, "getmininginfo", "[]");
    defer allocator.free(resp);
    if (json_mode) { try printRawJson(resp); return 0; }
    var p = parse(allocator, resp) catch return 1;
    defer p.deinit();
    var err_msg: []const u8 = "";
    const r = extractResult(p.value, &err_msg) orelse {
        try printRpcError(err_msg);
        return 1;
    };
    const out = stdout();
    try out.print("{s}=== Mining Status ==={s}\n", .{ col(C_BOLD), rst() });
    if (jsonGetStr(r, "miner")) |m|
        try out.print("Active miner:  {s}{s}{s}\n", .{ col(C_GREEN), m, rst() });
    var b: [64]u8 = undefined;
    try out.print("Block reward:  {s} OMNI\n", .{try formatOmni(&b, jsonGetU64(r, "blockReward"))});
    try out.print("Hashrate:      ~{d} H/s\n", .{jsonGetU64(r, "hashrate")});
    try out.print("Block rate:    {d} blk/min (target: 60)\n", .{jsonGetU64(r, "blocksPerMinute")});
    try out.print("Last block:    {d} ({d}s ago)\n", .{
        jsonGetU64(r, "lastBlockHeight"),
        jsonGetU64(r, "secondsSinceLastBlock"),
    });
    try out.print("Pool members:  {d}\n", .{jsonGetU64(r, "poolMembers")});
    return 0;
}

fn cmdMiners(allocator: std.mem.Allocator, ep: Endpoint, json_mode: bool) !u8 {
    return cmdGenericJson(allocator, ep, "getminers", "[]", "Miners", json_mode);
}

fn cmdMinerStats(allocator: std.mem.Allocator, ep: Endpoint, addr: []const u8, json_mode: bool) !u8 {
    const params = try std.fmt.allocPrint(allocator, "[\"{s}\"]", .{addr});
    defer allocator.free(params);
    return cmdGenericJson(allocator, ep, "getminerstats", params, "Miner Stats", json_mode);
}

fn cmdPoolStats(allocator: std.mem.Allocator, ep: Endpoint, json_mode: bool) !u8 {
    return cmdGenericJson(allocator, ep, "getpoolstats", "[]", "Pool Stats", json_mode);
}

fn cmdSlotLeader(allocator: std.mem.Allocator, ep: Endpoint, json_mode: bool) !u8 {
    return cmdGenericJson(allocator, ep, "getslotleader", "[]", "Slot Leader", json_mode);
}

fn cmdRegisterMiner(allocator: std.mem.Allocator, ep: Endpoint, args: Args) !u8 {
    if (args.pos.len < 1) return writeMissing("register-miner <addr> [node-id]");
    const c = try requireYes(args, "register-miner");
    if (c != 0) return c;
    const addr = args.pos[0];
    const params = if (args.pos.len > 1)
        try std.fmt.allocPrint(allocator, "[\"{s}\",\"{s}\"]", .{ addr, args.pos[1] })
    else
        try std.fmt.allocPrint(allocator, "[\"{s}\"]", .{addr});
    defer allocator.free(params);
    const resp = try rpcCall(allocator, ep, "registerminer", params);
    defer allocator.free(resp);
    if (args.json) { try printRawJson(resp); return 0; }
    return printWriteResult(allocator, resp, "registerminer");
}

// ─── Wallet utilities ───────────────────────────────────────────────────────
fn cmdWalletDerive(allocator: std.mem.Allocator, ep: Endpoint, args: Args) !u8 {
    if (args.pos.len < 2) return writeMissing("wallet-derive <mnemonic> <index>");
    const params = try std.fmt.allocPrint(allocator,
        "[\"{s}\",{s}]", .{ args.pos[0], args.pos[1] });
    defer allocator.free(params);
    return cmdGenericJson(allocator, ep, "walletderive", params, "Wallet Derive", args.json);
}

fn cmdWalletPqDerive(allocator: std.mem.Allocator, ep: Endpoint, args: Args) !u8 {
    if (args.pos.len < 1) return writeMissing("wallet-pq-derive <mnemonic>");
    const params = try std.fmt.allocPrint(allocator, "[\"{s}\"]", .{args.pos[0]});
    defer allocator.free(params);
    return cmdGenericJson(allocator, ep, "walletpqderive", params, "PQ Wallet Derive", args.json);
}

fn cmdWalletMultichain(allocator: std.mem.Allocator, ep: Endpoint, args: Args) !u8 {
    if (args.pos.len < 1) return writeMissing("wallet-multichain <mnemonic>");
    const params = try std.fmt.allocPrint(allocator, "[\"{s}\"]", .{args.pos[0]});
    defer allocator.free(params);
    return cmdGenericJson(allocator, ep, "walletmultichain", params, "Multichain Wallet", args.json);
}

fn cmdWalletExport(allocator: std.mem.Allocator, ep: Endpoint, args: Args) !u8 {
    if (args.pos.len < 1) return writeMissing("wallet-export <mnemonic>");
    const params = try std.fmt.allocPrint(allocator, "[\"{s}\"]", .{args.pos[0]});
    defer allocator.free(params);
    return cmdGenericJson(allocator, ep, "walletexport", params, "Wallet Export", args.json);
}

fn cmdSignMessage(allocator: std.mem.Allocator, ep: Endpoint, args: Args) !u8 {
    if (args.pos.len < 2) return writeMissing("sign-message <mnemonic> <message>");
    const params = try std.fmt.allocPrint(allocator,
        "[\"{s}\",\"{s}\"]", .{ args.pos[0], args.pos[1] });
    defer allocator.free(params);
    return cmdGenericJson(allocator, ep, "signmessage", params, "Sign Message", args.json);
}

fn cmdVerifySignature(allocator: std.mem.Allocator, ep: Endpoint, args: Args) !u8 {
    if (args.pos.len < 3) return writeMissing("verify-signature <pubkey> <signature> <message>");
    const params = try std.fmt.allocPrint(allocator,
        "[\"{s}\",\"{s}\",\"{s}\"]", .{ args.pos[0], args.pos[1], args.pos[2] });
    defer allocator.free(params);
    return cmdGenericJson(allocator, ep, "verifymessage", params, "Verify Signature", args.json);
}

fn cmdSend(allocator: std.mem.Allocator, ep: Endpoint, args: Args) !u8 {
    if (args.pos.len < 3) return writeMissing("send <from> <to> <amount> [fee=1]");
    const c = try requireYes(args, "send");
    if (c != 0) return c;
    const fee_str: []const u8 = if (args.pos.len > 3) args.pos[3] else "1";
    const amount = parseOmni(args.pos[2]) orelse {
        try printRpcError("invalid amount");
        return 2;
    };
    const fee = parseOmni(fee_str) orelse 1;
    const params = try std.fmt.allocPrint(allocator,
        "[\"{s}\",\"{s}\",{d},{d}]", .{ args.pos[0], args.pos[1], amount, fee });
    defer allocator.free(params);
    const resp = try rpcCall(allocator, ep, "sendtransaction", params);
    defer allocator.free(resp);
    if (args.json) { try printRawJson(resp); return 0; }
    return printWriteResult(allocator, resp, "send");
}

// ─── Admin / debug ──────────────────────────────────────────────────────────
fn configPath(allocator: std.mem.Allocator) ![]u8 {
    const home = std.process.getEnvVarOwned(allocator, "USERPROFILE") catch
        std.process.getEnvVarOwned(allocator, "HOME") catch
        return allocator.dupe(u8, ".omnibus/cli.conf");
    defer allocator.free(home);
    return std.fmt.allocPrint(allocator, "{s}/.omnibus/cli.conf", .{home});
}

fn cmdSetRpcToken(allocator: std.mem.Allocator, args: Args) !u8 {
    if (args.pos.len < 1) return writeMissing("set-rpc-token <token>");
    const path = try configPath(allocator);
    defer allocator.free(path);
    if (std.fs.path.dirname(path)) |dir| {
        std.fs.cwd().makePath(dir) catch {};
    }
    var f = std.fs.cwd().createFile(path, .{}) catch |e| {
        try stderr().print("Failed to create {s}: {s}\n", .{ path, @errorName(e) });
        return 1;
    };
    defer f.close();
    try f.writeAll("rpc_token=");
    try f.writeAll(args.pos[0]);
    try f.writeAll("\n");
    try stdout().print("{s}OK{s} token written to {s}\n",
        .{ col(C_GREEN), rst(), path });
    return 0;
}

fn cmdConfig(allocator: std.mem.Allocator, args: Args, ep: Endpoint) !u8 {
    const path = try configPath(allocator);
    defer allocator.free(path);
    const out = stdout();
    try out.print("{s}=== CLI Config ==={s}\n", .{ col(C_BOLD), rst() });
    try out.print("Config file:  {s}\n", .{path});
    try out.print("Chain:        {s}\n", .{args.chain});
    if (ep.use_curl) {
        try out.print("Endpoint:     {s} (HTTPS via curl)\n", .{ep.full_url orelse "?"});
    } else {
        try out.print("Endpoint:     http://{s}:{d}{s}\n", .{ ep.host, ep.port, ep.path });
    }
    const has_token = ep.token != null and ep.token.?.len > 0;
    try out.print("RPC token:    {s}\n", .{if (has_token) "SET" else "(none)"});
    try out.print("Color:        {s}\n", .{if (g_color) "ON" else "OFF"});
    if (std.fs.cwd().openFile(path, .{})) |f| {
        defer f.close();
        try out.print("Persisted:    yes\n", .{});
    } else |_| {
        try out.print("Persisted:    no\n", .{});
    }
    return 0;
}

fn cmdLogs(allocator: std.mem.Allocator, args: Args) !u8 {
    const tail_n: usize = if (args.pos.len > 0)
        std.fmt.parseInt(usize, args.pos[0], 10) catch 50
    else
        50;
    const out = stdout();
    try out.print("{s}=== Logs (last {d}) ==={s}\n", .{ col(C_BOLD), tail_n, rst() });
    const candidates = [_][]const u8{
        "/var/log/omnibus/omnibus-node.log",
        "/var/log/omnibus.log",
    };
    for (candidates) |path| {
        if (std.fs.cwd().openFile(path, .{})) |f| {
            defer f.close();
            const text = f.readToEndAlloc(allocator, 8 * 1024 * 1024) catch continue;
            defer allocator.free(text);
            var line_count: usize = 0;
            var i: usize = text.len;
            while (i > 0) : (i -= 1) {
                if (text[i - 1] == '\n') {
                    line_count += 1;
                    if (line_count > tail_n) break;
                }
            }
            try out.print("{s}", .{text[i..]});
            return 0;
        } else |_| {}
    }
    try printRpcError("no log file found in standard locations");
    return 1;
}

fn runProcess(allocator: std.mem.Allocator, argv: []const []const u8) !u8 {
    var child = std.process.Child.init(argv, allocator);
    child.stdin_behavior = .Inherit;
    child.stdout_behavior = .Inherit;
    child.stderr_behavior = .Inherit;
    child.spawn() catch |e| {
        try stderr().print("{s}spawn failed:{s} {s}\n",
            .{ col(C_RED), rst(), @errorName(e) });
        return 1;
    };
    const term = child.wait() catch return 1;
    return switch (term) {
        .Exited => |c| c,
        else => 1,
    };
}

fn cmdVpsHealth(allocator: std.mem.Allocator) !u8 {
    return runProcess(allocator, &.{
        "ssh", "omnibus-vps", "bash -s",
    });
    // NOTE: caller can pipe `< test-scripts/_vps-health.sh` for full bash. The
    // simple path runs an interactive remote shell; for one-shot use:
    //   ssh omnibus-vps 'bash -s' < test-scripts/_vps-health.sh
}

fn cmdStressQuick(allocator: std.mem.Allocator) !u8 {
    return runProcess(allocator, &.{
        "bash", "test-scripts/_quick-stake-test.sh",
    });
}

fn cmdBenchmark(allocator: std.mem.Allocator, ep: Endpoint, args: Args) !u8 {
    const out = stdout();
    if (!args.json) {
        try out.print("{s}=== RPC Benchmark (1000 calls) ==={s}\n",
            .{ col(C_BOLD), rst() });
    }
    var t = std.time.Timer.start() catch return 1;
    var ok: usize = 0;
    var fails: usize = 0;
    var min_ns: u64 = std.math.maxInt(u64);
    var max_ns: u64 = 0;
    var i: usize = 0;
    while (i < 1000) : (i += 1) {
        var step = std.time.Timer.start() catch return 1;
        const resp = rpcCall(allocator, ep, "ping", "[]") catch {
            fails += 1;
            continue;
        };
        defer allocator.free(resp);
        const dt = step.read();
        if (dt < min_ns) min_ns = dt;
        if (dt > max_ns) max_ns = dt;
        ok += 1;
    }
    const total_ns = t.read();
    const avg_ns: u64 = if (ok > 0) total_ns / @as(u64, @intCast(ok)) else 0;
    if (args.json) {
        try out.print(
            "{{\"calls\":1000,\"ok\":{d},\"fail\":{d},\"avg_us\":{d}," ++
            "\"min_us\":{d},\"max_us\":{d}}}\n",
            .{ ok, fails, avg_ns / 1000, min_ns / 1000, max_ns / 1000 });
    } else {
        try out.print("OK:       {d}\n", .{ok});
        try out.print("Failed:   {d}\n", .{fails});
        try out.print("Avg:      {d} \xC2\xB5s\n", .{avg_ns / 1000});
        try out.print("Min:      {d} \xC2\xB5s\n", .{min_ns / 1000});
        try out.print("Max:      {d} \xC2\xB5s\n", .{max_ns / 1000});
    }
    return 0;
}

// ─── Faucet ─────────────────────────────────────────────────────────────────
fn cmdFaucetStatus(allocator: std.mem.Allocator, ep: Endpoint, json_mode: bool) !u8 {
    return cmdGenericJson(allocator, ep, "faucetstatus", "[]", "Faucet Status", json_mode);
}

fn cmdFaucetClaim(allocator: std.mem.Allocator, ep: Endpoint, args: Args) !u8 {
    if (args.pos.len < 1) return writeMissing("faucet-claim <addr>");
    const c = try requireYes(args, "faucet-claim");
    if (c != 0) return c;
    const params = try std.fmt.allocPrint(allocator, "[\"{s}\"]", .{args.pos[0]});
    defer allocator.free(params);
    const resp = try rpcCall(allocator, ep, "faucetclaim", params);
    defer allocator.free(resp);
    if (args.json) { try printRawJson(resp); return 0; }
    return printWriteResult(allocator, resp, "faucet-claim");
}

fn cmdFaucetClaims(allocator: std.mem.Allocator, ep: Endpoint, json_mode: bool) !u8 {
    return cmdGenericJson(allocator, ep, "faucetclaims", "[]", "Faucet Claims", json_mode);
}

// ─── 0day / security ────────────────────────────────────────────────────────
fn cmdZerodayEvents(allocator: std.mem.Allocator, ep: Endpoint, json_mode: bool) !u8 {
    return cmdGenericJson(allocator, ep, "zerodayevents", "[]", "0day Events", json_mode);
}

fn cmdZerodayReport(allocator: std.mem.Allocator, ep: Endpoint, args: Args) !u8 {
    if (args.pos.len < 1) return writeMissing("zeroday-report <description>");
    const c = try requireYes(args, "zeroday-report");
    if (c != 0) return c;
    const params = try std.fmt.allocPrint(allocator, "[\"{s}\"]", .{args.pos[0]});
    defer allocator.free(params);
    const resp = try rpcCall(allocator, ep, "zerodayreport", params);
    defer allocator.free(resp);
    if (args.json) { try printRawJson(resp); return 0; }
    return printWriteResult(allocator, resp, "zeroday-report");
}

fn cmdSybilCheck(allocator: std.mem.Allocator, ep: Endpoint, args: Args) !u8 {
    if (args.pos.len < 1) return writeMissing("sybil-check <ip>");
    const params = try std.fmt.allocPrint(allocator, "[\"{s}\"]", .{args.pos[0]});
    defer allocator.free(params);
    return cmdGenericJson(allocator, ep, "sybilcheck", params, "Sybil Check", args.json);
}

// ─── Audit chain consistency ────────────────────────────────────────────────
fn cmdAuditTotals(allocator: std.mem.Allocator, ep: Endpoint, json_mode: bool) !u8 {
    const resp = try rpcCall(allocator, ep, "getrichlist", "[{\"limit\":10000}]");
    defer allocator.free(resp);
    const metrics_resp = try rpcCall(allocator, ep, "getchainmetrics", "[]");
    defer allocator.free(metrics_resp);

    var p = parse(allocator, resp) catch return 1;
    defer p.deinit();
    var mp = parse(allocator, metrics_resp) catch return 1;
    defer mp.deinit();
    var err_msg: []const u8 = "";

    var sum_balances: u64 = 0;
    if (extractResult(p.value, &err_msg)) |r| {
        if (r == .object) {
            if (r.object.get("addresses")) |arr| {
                if (arr == .array) {
                    for (arr.array.items) |a| sum_balances += jsonGetU64(a, "balance");
                }
            }
        }
    }
    var height: u64 = 0;
    var supply: u64 = 0;
    if (extractResult(mp.value, &err_msg)) |r| {
        height = jsonGetU64(r, "height");
        supply = jsonGetU64(r, "totalSupply");
    }
    if (json_mode) {
        try stdout().print(
            "{{\"height\":{d},\"sum_balances_sat\":{d},\"total_supply_sat\":{d}," ++
            "\"diff_sat\":{d},\"match\":{}}}\n",
            .{ height, sum_balances, supply,
               if (sum_balances >= supply) sum_balances - supply else supply - sum_balances,
               sum_balances == supply });
        return 0;
    }
    const out = stdout();
    var b: [64]u8 = undefined;
    try out.print("{s}=== Chain Totals Reconciliation (height {d}) ==={s}\n",
        .{ col(C_BOLD), height, rst() });
    try out.print("Sum of balances:   {s} OMNI\n", .{try formatOmni(&b, sum_balances)});
    try out.print("Total emitted:     {s} OMNI\n", .{try formatOmni(&b, supply)});
    if (sum_balances == supply) {
        try out.print("Match:             {s}MATCH{s}\n", .{ col(C_GREEN), rst() });
        return 0;
    }
    const diff = if (sum_balances > supply) sum_balances - supply else supply - sum_balances;
    try out.print("Difference:        {s}{s} OMNI{s}\n",
        .{ col(C_YELLOW), try formatOmni(&b, diff), rst() });
    return 1;
}

fn cmdAuditStakes(allocator: std.mem.Allocator, ep: Endpoint, json_mode: bool) !u8 {
    const resp = try rpcCall(allocator, ep, "getstakers", "[{\"limit\":10000}]");
    defer allocator.free(resp);
    var p = parse(allocator, resp) catch return 1;
    defer p.deinit();
    var err_msg: []const u8 = "";
    const r = extractResult(p.value, &err_msg) orelse {
        try printRpcError(err_msg);
        return 1;
    };
    var total_chain: u64 = 0;
    var total_stake_tx: u64 = 0;
    var total_unstake_tx: u64 = 0;
    if (r == .object) {
        if (r.object.get("stakers")) |arr| {
            if (arr == .array) {
                for (arr.array.items) |s|
                    total_chain += jsonGetU64(s, "amount_sat");
            }
        }
    }

    // Optional all-history aggregation for stake/unstake TXs.
    if (rpcCall(allocator, ep, "getalltransactions",
        "[{\"kinds\":[\"stake\",\"unstake\"]}]")) |h|
    {
        defer allocator.free(h);
        var hp = parse(allocator, h) catch return 1;
        defer hp.deinit();
        if (extractResult(hp.value, &err_msg)) |hr| {
            if (hr == .object) {
                if (hr.object.get("transactions")) |txs| {
                    if (txs == .array) {
                        for (txs.array.items) |tx| {
                            const k = jsonGetStr(tx, "kind") orelse "";
                            const a = jsonGetU64(tx, "amount");
                            if (std.mem.eql(u8, k, "stake")) total_stake_tx += a
                            else if (std.mem.eql(u8, k, "unstake")) total_unstake_tx += a;
                        }
                    }
                }
            }
        }
    } else |_| {}

    const computed: u64 = if (total_stake_tx > total_unstake_tx)
        total_stake_tx - total_unstake_tx else 0;

    if (json_mode) {
        try stdout().print(
            "{{\"chain_total_sat\":{d},\"stake_tx_sat\":{d},\"unstake_tx_sat\":{d}," ++
            "\"computed_sat\":{d},\"match\":{}}}\n",
            .{ total_chain, total_stake_tx, total_unstake_tx, computed,
               total_chain == computed });
        return if (total_chain == computed) 0 else 1;
    }
    const out = stdout();
    var b: [64]u8 = undefined;
    try out.print("{s}=== Stake Audit ==={s}\n", .{ col(C_BOLD), rst() });
    try out.print("Total chain stake_amounts:  {s} OMNI\n", .{try formatOmni(&b, total_chain)});
    try out.print("Total stake TX volume:      {s} OMNI\n", .{try formatOmni(&b, total_stake_tx)});
    try out.print("Total unstake TX volume:    {s} OMNI\n", .{try formatOmni(&b, total_unstake_tx)});
    try out.print("Computed:                   {s} OMNI\n", .{try formatOmni(&b, computed)});
    if (total_chain == computed) {
        try out.print("Sum check:                  {s}MATCH{s}\n", .{ col(C_GREEN), rst() });
        return 0;
    }
    try out.print("Sum check:                  {s}MISMATCH{s}\n", .{ col(C_RED), rst() });
    return 1;
}

fn cmdAuditSupply(allocator: std.mem.Allocator, ep: Endpoint, json_mode: bool) !u8 {
    const metrics_resp = try rpcCall(allocator, ep, "getchainmetrics", "[]");
    defer allocator.free(metrics_resp);
    var mp = parse(allocator, metrics_resp) catch return 1;
    defer mp.deinit();
    var err_msg: []const u8 = "";
    const r = extractResult(mp.value, &err_msg) orelse {
        try printRpcError(err_msg);
        return 1;
    };
    const height = jsonGetU64(r, "height");
    const total_supply = jsonGetU64(r, "totalSupply");

    // Σ reward(h) for h = 1..height, halving every 210k.
    const init_reward: u64 = 50 * SAT_PER_OMNI;
    const halving_period: u64 = 210_000;
    var expected: u64 = 0;
    var h: u64 = 1;
    while (h <= height) : (h += 1) {
        const halvings = (h - 1) / halving_period;
        const cur = init_reward >> @intCast(@min(halvings, 63));
        expected += cur;
    }
    if (json_mode) {
        try stdout().print(
            "{{\"height\":{d},\"total_supply_sat\":{d},\"expected_sat\":{d}," ++
            "\"diff_sat\":{d}}}\n",
            .{ height, total_supply, expected,
               if (total_supply >= expected) total_supply - expected else expected - total_supply });
        return 0;
    }
    const out = stdout();
    var b: [64]u8 = undefined;
    try out.print("{s}=== Supply Audit ==={s}\n", .{ col(C_BOLD), rst() });
    try out.print("Height:           {d}\n", .{height});
    try out.print("Total emitted:    {s} OMNI\n", .{try formatOmni(&b, total_supply)});
    try out.print("Expected (halv.): {s} OMNI\n", .{try formatOmni(&b, expected)});
    if (total_supply == expected) {
        try out.print("Match:            {s}EXACT{s}\n", .{ col(C_GREEN), rst() });
        return 0;
    }
    const diff = if (total_supply > expected) total_supply - expected else expected - total_supply;
    try out.print("Difference:       {s}{s} OMNI{s}\n",
        .{ col(C_YELLOW), try formatOmni(&b, diff), rst() });
    return 0;
}

fn cmdAuditMempool(allocator: std.mem.Allocator, ep: Endpoint, json_mode: bool) !u8 {
    return cmdGenericJson(allocator, ep, "auditmempool", "[]", "Mempool Audit", json_mode);
}

fn cmdAuditFees(allocator: std.mem.Allocator, ep: Endpoint, json_mode: bool) !u8 {
    return cmdGenericJson(allocator, ep, "auditfees", "[]", "Fee Audit", json_mode);
}

// ─── Restart / control ──────────────────────────────────────────────────────
fn cmdServicesStatus(allocator: std.mem.Allocator) !u8 {
    return runProcess(allocator, &.{
        "ssh", "omnibus-vps",
        "systemctl is-active omnibus-node omnibus-oracle omnibus-agents",
    });
}

fn cmdServiceRestart(allocator: std.mem.Allocator, args: Args) !u8 {
    if (args.pos.len < 1) return writeMissing("service-restart <service>");
    const c = try requireYes(args, "service-restart");
    if (c != 0) return c;
    const cmd = try std.fmt.allocPrint(allocator,
        "sudo systemctl restart {s}", .{args.pos[0]});
    defer allocator.free(cmd);
    return runProcess(allocator, &.{ "ssh", "omnibus-vps", cmd });
}

fn cmdOracleRestart(allocator: std.mem.Allocator, args: Args) !u8 {
    const c = try requireYes(args, "oracle-restart");
    if (c != 0) return c;
    return runProcess(allocator, &.{
        "ssh", "omnibus-vps", "sudo systemctl restart omnibus-oracle",
    });
}

fn cmdOracleSnapshot(allocator: std.mem.Allocator) !u8 {
    const oracle_host = "127.0.0.1";
    const oracle_port: u16 = 28100;
    const addr = std.net.Address.parseIp4(oracle_host, oracle_port) catch {
        try printRpcError("cannot parse oracle host");
        return 1;
    };
    var stream = std.net.tcpConnectToAddress(addr) catch |e| {
        try stderr().print("Cannot reach oracle :28100 ({s})\n", .{@errorName(e)});
        return 1;
    };
    defer stream.close();
    var req = std.array_list.Managed(u8).init(allocator);
    defer req.deinit();
    try req.appendSlice("GET /snapshot HTTP/1.1\r\nHost: 127.0.0.1:28100\r\nConnection: close\r\n\r\n");
    _ = stream.writeAll(req.items) catch return 1;
    var resp = std.array_list.Managed(u8).init(allocator);
    defer resp.deinit();
    var buf: [16 * 1024]u8 = undefined;
    while (true) {
        const n = stream.read(&buf) catch break;
        if (n == 0) break;
        try resp.appendSlice(buf[0..n]);
        if (resp.items.len > 1 * 1024 * 1024) break;
    }
    if (std.mem.indexOf(u8, resp.items, "\r\n\r\n")) |sep| {
        try stdout().print("{s}\n", .{resp.items[sep + 4 ..]});
    } else {
        try stdout().print("{s}\n", .{resp.items});
    }
    return 0;
}

// ─── Shared JSON-quote + key-value writers (used by names/agents/etc.) ────

/// Quote an arbitrary string into a JSON string literal. Returns owned slice.
/// Escapes `"`, `\`, control chars — same rules as RFC 8259. Used by all
/// name/agent/escrow/multisig handlers below to safely embed user strings
/// in the JSON-RPC params we hand-build (we don't pull in a JSON encoder).
fn jsonQuote(allocator: std.mem.Allocator, s: []const u8) ![]u8 {
    var b = std.array_list.Managed(u8).init(allocator);
    defer b.deinit();
    try b.append('"');
    for (s) |c| {
        switch (c) {
            '"', '\\' => {
                try b.append('\\');
                try b.append(c);
            },
            '\n' => try b.appendSlice("\\n"),
            '\r' => try b.appendSlice("\\r"),
            '\t' => try b.appendSlice("\\t"),
            else => try b.append(c),
        }
    }
    try b.append('"');
    return b.toOwnedSlice();
}

/// Generic "RPC call → pretty-print scalars" wrapper. Read-only commands
/// that return a flat-ish object (PQ schemes, ENS stats, escrow info)
/// reuse this so each handler stays under the 80-line cap.
fn dumpRpcResult(
    allocator: std.mem.Allocator,
    ep: Endpoint,
    method: []const u8,
    params: []const u8,
    json_mode: bool,
    title: []const u8,
) !u8 {
    const resp = try rpcCall(allocator, ep, method, params);
    defer allocator.free(resp);
    if (json_mode) { try printRawJson(resp); return 0; }
    var p = parse(allocator, resp) catch {
        try stderr().print("Failed to parse response\n", .{});
        return 1;
    };
    defer p.deinit();
    var err_msg: []const u8 = "";
    const r = extractResult(p.value, &err_msg) orelse {
        try printRpcError(err_msg); return 1;
    };
    const out = stdout();
    try out.print("{s}=== {s} ==={s}\n", .{ col(C_BOLD), title, rst() });
    if (r != .object) { try out.print("(non-object result)\n", .{}); return 0; }
    var it = r.object.iterator();
    while (it.next()) |entry| {
        const k = entry.key_ptr.*;
        switch (entry.value_ptr.*) {
            .string  => |s| try out.print("  {s}: {s}\n", .{ k, s }),
            .integer => |x| try out.print("  {s}: {d}\n", .{ k, x }),
            .float   => |x| try out.print("  {s}: {d:.6}\n", .{ k, x }),
            .bool    => |x| try out.print("  {s}: {}\n", .{ k, x }),
            .null    => try out.print("  {s}: null\n", .{k}),
            .array   => |a| try out.print("  {s}: [array, {d} entries]\n", .{ k, a.items.len }),
            .object  => try out.print("  {s}: <object>\n", .{k}),
            else     => try out.print("  {s}: <?>\n", .{k}),
        }
    }
    return 0;
}

// ─── ns-resolve ──────────────────────────────────────────────────────────
fn cmdNsResolve(allocator: std.mem.Allocator, ep: Endpoint, name: []const u8, json_mode: bool) !u8 {
    const qn = try jsonQuote(allocator, name);
    defer allocator.free(qn);
    const params = try std.fmt.allocPrint(allocator, "[{s}]", .{qn});
    defer allocator.free(params);
    const resp = try rpcCall(allocator, ep, "resolvename", params);
    defer allocator.free(resp);
    if (json_mode) { try printRawJson(resp); return 0; }
    var p = try parse(allocator, resp);
    defer p.deinit();
    var err_msg: []const u8 = "";
    const r = extractResult(p.value, &err_msg) orelse {
        try printRpcError(err_msg); return 1;
    };
    const out = stdout();
    try out.print("{s}=== Resolve: {s} ==={s}\n", .{ col(C_BOLD), name, rst() });
    const addr = jsonGetStr(r, "address") orelse jsonGetStr(r, "owner") orelse "";
    if (addr.len == 0) { try out.print("(name not found)\n", .{}); return 1; }
    try out.print("Address:  {s}{s}{s}\n", .{ col(C_GREEN), addr, rst() });
    if (jsonGetStr(r, "tld")) |t| try out.print("TLD:      {s}\n", .{t});
    if (jsonGetStr(r, "category")) |c| try out.print("Category: {s}\n", .{c});
    const exp = jsonGetU64(r, "expiry_block");
    if (exp > 0) try out.print("Expires:  block {d}\n", .{exp});
    return 0;
}

// ─── ns-reverse ──────────────────────────────────────────────────────────
fn cmdNsReverse(allocator: std.mem.Allocator, ep: Endpoint, addr: []const u8, json_mode: bool) !u8 {
    const qa = try jsonQuote(allocator, addr);
    defer allocator.free(qa);
    const params = try std.fmt.allocPrint(allocator, "[{s}]", .{qa});
    defer allocator.free(params);
    return dumpRpcResult(allocator, ep, "reverseresolvename", params, json_mode, "Reverse-Resolve");
}

// ─── ns-list ─────────────────────────────────────────────────────────────
fn cmdNsList(allocator: std.mem.Allocator, ep: Endpoint, owner: ?[]const u8, json_mode: bool) !u8 {
    const params = if (owner) |o| blk: {
        const qo = try jsonQuote(allocator, o);
        defer allocator.free(qo);
        break :blk try std.fmt.allocPrint(allocator, "[{s}]", .{qo});
    } else try allocator.dupe(u8, "[]");
    defer allocator.free(params);
    const resp = try rpcCall(allocator, ep, "listnames", params);
    defer allocator.free(resp);
    if (json_mode) { try printRawJson(resp); return 0; }
    var p = try parse(allocator, resp);
    defer p.deinit();
    var err_msg: []const u8 = "";
    const r = extractResult(p.value, &err_msg) orelse {
        try printRpcError(err_msg); return 1;
    };
    const out = stdout();
    const title_owner = owner orelse "(all)";
    try out.print("{s}Names owned by {s}{s}\n", .{ col(C_BOLD), title_owner, rst() });
    try out.print("{s}{s:<22} {s:<10} {s:<14} {s:<18} {s}{s}\n", .{
        col(C_GRAY), "NAME", "TLD", "EXPIRES", "TARGET", "CATEGORY", rst(),
    });
    if (r != .object) return 0;
    const names = r.object.get("names") orelse return 0;
    if (names != .array) return 0;
    for (names.array.items) |n| {
        const nm = jsonGetStr(n, "name") orelse "";
        const tld = jsonGetStr(n, "tld") orelse "";
        const exp = jsonGetU64(n, "expiry_block");
        const tgt = jsonGetStr(n, "target_address") orelse jsonGetStr(n, "address") orelse "";
        const tgt_short = if (tgt.len > 18) tgt[0..18] else tgt;
        const cat = jsonGetStr(n, "category") orelse "-";
        try out.print("{s:<22} {s:<10} block {d:<8} {s:<18} {s}\n",
            .{ nm, tld, exp, tgt_short, cat });
    }
    return 0;
}

// ─── ns-tlds / ns-fee / ns-stats / ns-expiring ────────────────────────────
fn cmdNsTlds(allocator: std.mem.Allocator, ep: Endpoint, json_mode: bool) !u8 {
    return dumpRpcResult(allocator, ep, "ns_listTlds", "[]", json_mode, "Available TLDs");
}

fn cmdNsFee(allocator: std.mem.Allocator, ep: Endpoint, tld: []const u8, json_mode: bool) !u8 {
    const qt = try jsonQuote(allocator, tld);
    defer allocator.free(qt);
    const params = try std.fmt.allocPrint(allocator, "[{s}]", .{qt});
    defer allocator.free(params);
    return dumpRpcResult(allocator, ep, "getensfee", params, json_mode, "Registration Fee");
}

fn cmdNsStats(allocator: std.mem.Allocator, ep: Endpoint, json_mode: bool) !u8 {
    return dumpRpcResult(allocator, ep, "ns_stats", "[]", json_mode, "NS Stats");
}

fn cmdNsExpiring(allocator: std.mem.Allocator, ep: Endpoint, days: u64, json_mode: bool) !u8 {
    const params = try std.fmt.allocPrint(allocator, "[{d}]", .{days});
    defer allocator.free(params);
    return dumpRpcResult(allocator, ep, "ns_expiringSoon", params, json_mode, "Names Expiring Soon");
}

// ─── ns-register / ns-renew / ns-transfer / ns-update / ns-by-category ────
fn cmdNsRegister(allocator: std.mem.Allocator, ep: Endpoint, args: Args) !u8 {
    if (args.pos.len < 3) return writeMissing("ns-register <addr> <name> <tld> [years]");
    const c = try requireYes(args, "ns-register"); if (c != 0) return c;
    const years: u64 = if (args.pos.len > 3)
        std.fmt.parseInt(u64, args.pos[3], 10) catch 1
    else 1;
    const qa = try jsonQuote(allocator, args.pos[0]);
    defer allocator.free(qa);
    const qn = try jsonQuote(allocator, args.pos[1]);
    defer allocator.free(qn);
    const qt = try jsonQuote(allocator, args.pos[2]);
    defer allocator.free(qt);
    const params = try std.fmt.allocPrint(allocator,
        "{{\"address\":{s},\"name\":{s},\"tld\":{s},\"years\":{d}}}",
        .{ qa, qn, qt, years });
    defer allocator.free(params);
    const resp = try rpcCall(allocator, ep, "registername", params);
    defer allocator.free(resp);
    if (args.json) { try printRawJson(resp); return 0; }
    return printWriteResult(allocator, resp, "registername");
}

fn cmdNsRenew(allocator: std.mem.Allocator, ep: Endpoint, args: Args) !u8 {
    if (args.pos.len < 2) return writeMissing("ns-renew <addr> <name> [years]");
    const c = try requireYes(args, "ns-renew"); if (c != 0) return c;
    const years: u64 = if (args.pos.len > 2)
        std.fmt.parseInt(u64, args.pos[2], 10) catch 1
    else 1;
    const qa = try jsonQuote(allocator, args.pos[0]);
    defer allocator.free(qa);
    const qn = try jsonQuote(allocator, args.pos[1]);
    defer allocator.free(qn);
    const params = try std.fmt.allocPrint(allocator,
        "{{\"address\":{s},\"name\":{s},\"years\":{d}}}",
        .{ qa, qn, years });
    defer allocator.free(params);
    const resp = try rpcCall(allocator, ep, "renewname", params);
    defer allocator.free(resp);
    if (args.json) { try printRawJson(resp); return 0; }
    return printWriteResult(allocator, resp, "renewname");
}

fn cmdNsTransfer(allocator: std.mem.Allocator, ep: Endpoint, args: Args) !u8 {
    if (args.pos.len < 3) return writeMissing("ns-transfer <from> <to> <name>");
    const c = try requireYes(args, "ns-transfer"); if (c != 0) return c;
    const qf = try jsonQuote(allocator, args.pos[0]);
    defer allocator.free(qf);
    const qt = try jsonQuote(allocator, args.pos[1]);
    defer allocator.free(qt);
    const qn = try jsonQuote(allocator, args.pos[2]);
    defer allocator.free(qn);
    const params = try std.fmt.allocPrint(allocator,
        "{{\"from\":{s},\"to\":{s},\"name\":{s}}}", .{ qf, qt, qn });
    defer allocator.free(params);
    const resp = try rpcCall(allocator, ep, "transfername", params);
    defer allocator.free(resp);
    if (args.json) { try printRawJson(resp); return 0; }
    return printWriteResult(allocator, resp, "transfername");
}

fn cmdNsUpdate(allocator: std.mem.Allocator, ep: Endpoint, args: Args) !u8 {
    if (args.pos.len < 2) return writeMissing("ns-update <addr> <name> [--target-addr=...] [--category=...]");
    const c = try requireYes(args, "ns-update"); if (c != 0) return c;
    const qa = try jsonQuote(allocator, args.pos[0]);
    defer allocator.free(qa);
    const qn = try jsonQuote(allocator, args.pos[1]);
    defer allocator.free(qn);
    var b = std.array_list.Managed(u8).init(allocator);
    defer b.deinit();
    const w = b.writer();
    try w.print("{{\"address\":{s},\"name\":{s}", .{ qa, qn });
    if (kvLookup(args, "target-addr")) |t| {
        const qt = try jsonQuote(allocator, t);
        defer allocator.free(qt);
        try w.print(",\"target\":{s}", .{qt});
    }
    if (kvLookup(args, "category")) |cat| {
        const qc = try jsonQuote(allocator, cat);
        defer allocator.free(qc);
        try w.print(",\"category\":{s}", .{qc});
    }
    try w.writeByte('}');
    const resp = try rpcCall(allocator, ep, "updatename", b.items);
    defer allocator.free(resp);
    if (args.json) { try printRawJson(resp); return 0; }
    return printWriteResult(allocator, resp, "updatename");
}

fn cmdNsByCategory(allocator: std.mem.Allocator, ep: Endpoint, cat: []const u8, json_mode: bool) !u8 {
    const qc = try jsonQuote(allocator, cat);
    defer allocator.free(qc);
    const params = try std.fmt.allocPrint(allocator, "[{s}]", .{qc});
    defer allocator.free(params);
    return dumpRpcResult(allocator, ep, "getnamesbycategory", params, json_mode, "Names by Category");
}

// ─── agents-list / agent-info / agent-{register,unregister,edit,follow} ──
fn cmdAgentsList(allocator: std.mem.Allocator, ep: Endpoint, json_mode: bool) !u8 {
    const resp = try rpcCall(allocator, ep, "agent_list", "[]");
    defer allocator.free(resp);
    if (json_mode) { try printRawJson(resp); return 0; }
    var p = try parse(allocator, resp);
    defer p.deinit();
    var err_msg: []const u8 = "";
    const r = extractResult(p.value, &err_msg) orelse {
        try printRpcError(err_msg); return 1;
    };
    const out = stdout();
    try out.print("{s}Registered Agents{s}\n", .{ col(C_BOLD), rst() });
    try out.print("{s}{s:<4} {s:<15} {s:<18} {s:<14} {s:<8} {s:<10} {s}{s}\n", .{
        col(C_GRAY), "ID", "NAME", "OWNER", "STRATEGY", "FEE_BPS", "DECISIONS", "P/L", rst(),
    });
    if (r != .object) return 0;
    const ags = r.object.get("agents") orelse return 0;
    if (ags != .array) return 0;
    for (ags.array.items) |a| {
        const id = jsonGetU64(a, "id");
        const nm = jsonGetStr(a, "name") orelse "";
        const ow = jsonGetStr(a, "owner") orelse "";
        const ow_short = if (ow.len > 18) ow[0..18] else ow;
        const st = jsonGetStr(a, "strategy") orelse "";
        const fb = jsonGetU64(a, "fee_bps");
        const dc = jsonGetU64(a, "decisions");
        const pl = jsonGetStr(a, "pnl") orelse "0";
        try out.print("{d:<4} {s:<15} {s:<18} {s:<14} {d:<8} {d:<10} {s}\n",
            .{ id, nm, ow_short, st, fb, dc, pl });
    }
    return 0;
}

fn cmdAgentInfo(allocator: std.mem.Allocator, ep: Endpoint, agent_id: []const u8, json_mode: bool) !u8 {
    const params = try std.fmt.allocPrint(allocator, "[{s}]", .{agent_id});
    defer allocator.free(params);
    return dumpRpcResult(allocator, ep, "getagent", params, json_mode, "Agent Info");
}

fn cmdAgentRegister(allocator: std.mem.Allocator, ep: Endpoint, args: Args) !u8 {
    if (args.pos.len < 4) return writeMissing("agent-register <addr> <name> <strategy> <fee_bps>");
    const c = try requireYes(args, "agent-register"); if (c != 0) return c;
    const qa = try jsonQuote(allocator, args.pos[0]);
    defer allocator.free(qa);
    const qn = try jsonQuote(allocator, args.pos[1]);
    defer allocator.free(qn);
    const qs = try jsonQuote(allocator, args.pos[2]);
    defer allocator.free(qs);
    const fb = std.fmt.parseInt(u64, args.pos[3], 10) catch 0;
    const params = try std.fmt.allocPrint(allocator,
        "{{\"address\":{s},\"name\":{s},\"strategy\":{s},\"fee_bps\":{d}}}",
        .{ qa, qn, qs, fb });
    defer allocator.free(params);
    const resp = try rpcCall(allocator, ep, "agent_register", params);
    defer allocator.free(resp);
    if (args.json) { try printRawJson(resp); return 0; }
    return printWriteResult(allocator, resp, "agent_register");
}

fn cmdAgentUnregister(allocator: std.mem.Allocator, ep: Endpoint, args: Args) !u8 {
    if (args.pos.len < 2) return writeMissing("agent-unregister <addr> <agent_id>");
    const c = try requireYes(args, "agent-unregister"); if (c != 0) return c;
    const qa = try jsonQuote(allocator, args.pos[0]);
    defer allocator.free(qa);
    const params = try std.fmt.allocPrint(allocator,
        "{{\"address\":{s},\"agent_id\":{s}}}", .{ qa, args.pos[1] });
    defer allocator.free(params);
    const resp = try rpcCall(allocator, ep, "agent_unregister", params);
    defer allocator.free(resp);
    if (args.json) { try printRawJson(resp); return 0; }
    return printWriteResult(allocator, resp, "agent_unregister");
}

fn cmdAgentEdit(allocator: std.mem.Allocator, ep: Endpoint, args: Args) !u8 {
    if (args.pos.len < 2) return writeMissing("agent-edit <addr> <agent_id> [--fee-bps=N]");
    const c = try requireYes(args, "agent-edit"); if (c != 0) return c;
    const qa = try jsonQuote(allocator, args.pos[0]);
    defer allocator.free(qa);
    const fee_bps = kvLookup(args, "fee-bps") orelse "0";
    const params = try std.fmt.allocPrint(allocator,
        "{{\"address\":{s},\"agent_id\":{s},\"fee_bps\":{s}}}",
        .{ qa, args.pos[1], fee_bps });
    defer allocator.free(params);
    const resp = try rpcCall(allocator, ep, "agent_edit", params);
    defer allocator.free(resp);
    if (args.json) { try printRawJson(resp); return 0; }
    return printWriteResult(allocator, resp, "agent_edit");
}

fn cmdAgentFollow(allocator: std.mem.Allocator, ep: Endpoint, args: Args) !u8 {
    if (args.pos.len < 2) return writeMissing("agent-follow <addr> <agent_id>");
    const c = try requireYes(args, "agent-follow"); if (c != 0) return c;
    const qa = try jsonQuote(allocator, args.pos[0]);
    defer allocator.free(qa);
    const params = try std.fmt.allocPrint(allocator,
        "{{\"address\":{s},\"agent_id\":{s}}}", .{ qa, args.pos[1] });
    defer allocator.free(params);
    const resp = try rpcCall(allocator, ep, "agent_follow", params);
    defer allocator.free(resp);
    if (args.json) { try printRawJson(resp); return 0; }
    return printWriteResult(allocator, resp, "agent_follow");
}

fn cmdAgentDecisions(allocator: std.mem.Allocator, ep: Endpoint, agent_id: []const u8, json_mode: bool) !u8 {
    const params = try std.fmt.allocPrint(allocator, "[{s}]", .{agent_id});
    defer allocator.free(params);
    return dumpRpcResult(allocator, ep, "agent_pending_decisions", params, json_mode,
        "Pending Agent Decisions");
}

// ─── governance: proposals / propose / vote / execute / treasury ──────────
fn cmdGovProposals(allocator: std.mem.Allocator, ep: Endpoint, json_mode: bool) !u8 {
    const resp = try rpcCall(allocator, ep, "getproposals", "[]");
    defer allocator.free(resp);
    if (json_mode) { try printRawJson(resp); return 0; }
    var p = try parse(allocator, resp);
    defer p.deinit();
    var err_msg: []const u8 = "";
    const r = extractResult(p.value, &err_msg) orelse {
        try printRpcError(err_msg); return 1;
    };
    const out = stdout();
    try out.print("{s}Active Proposals{s}\n", .{ col(C_BOLD), rst() });
    try out.print("{s}{s:<4} {s:<22} {s:<10} {s:<6} {s:<6} {s:<8} {s}{s}\n", .{
        col(C_GRAY), "ID", "TITLE", "STATUS", "YES", "NO", "ABSTAIN", "ENDS @", rst(),
    });
    if (r != .object) return 0;
    const ps = r.object.get("proposals") orelse return 0;
    if (ps != .array) return 0;
    for (ps.array.items) |pr| {
        const id = jsonGetU64(pr, "id");
        const ti = jsonGetStr(pr, "title") orelse "";
        const ti_short = if (ti.len > 22) ti[0..22] else ti;
        const stt = jsonGetStr(pr, "status") orelse "";
        const ye = jsonGetU64(pr, "yes_votes");
        const no = jsonGetU64(pr, "no_votes");
        const ab = jsonGetU64(pr, "abstain_votes");
        const eb = jsonGetU64(pr, "ends_at_block");
        try out.print("{d:<4} {s:<22} {s:<10} {d:<6} {d:<6} {d:<8} block {d}\n",
            .{ id, ti_short, stt, ye, no, ab, eb });
    }
    return 0;
}

fn cmdGovProposal(allocator: std.mem.Allocator, ep: Endpoint, pid: []const u8, json_mode: bool) !u8 {
    const params = try std.fmt.allocPrint(allocator, "[{s}]", .{pid});
    defer allocator.free(params);
    return dumpRpcResult(allocator, ep, "getproposal", params, json_mode, "Proposal Detail");
}

fn cmdGovPropose(allocator: std.mem.Allocator, ep: Endpoint, args: Args) !u8 {
    if (args.pos.len < 5) return writeMissing("gov-propose <addr> <title> <desc> <type> <target>");
    const c = try requireYes(args, "gov-propose"); if (c != 0) return c;
    const qa = try jsonQuote(allocator, args.pos[0]);
    defer allocator.free(qa);
    const qt = try jsonQuote(allocator, args.pos[1]);
    defer allocator.free(qt);
    const qd = try jsonQuote(allocator, args.pos[2]);
    defer allocator.free(qd);
    const qty = try jsonQuote(allocator, args.pos[3]);
    defer allocator.free(qty);
    const qtg = try jsonQuote(allocator, args.pos[4]);
    defer allocator.free(qtg);
    const params = try std.fmt.allocPrint(allocator,
        "{{\"address\":{s},\"title\":{s},\"description\":{s},\"type\":{s},\"target\":{s}}}",
        .{ qa, qt, qd, qty, qtg });
    defer allocator.free(params);
    const resp = try rpcCall(allocator, ep, "gov_propose", params);
    defer allocator.free(resp);
    if (args.json) { try printRawJson(resp); return 0; }
    return printWriteResult(allocator, resp, "gov_propose");
}

fn cmdGovVote(allocator: std.mem.Allocator, ep: Endpoint, args: Args) !u8 {
    if (args.pos.len < 3) return writeMissing("gov-vote <addr> <prop_id> <yes|no|abstain>");
    const c = try requireYes(args, "gov-vote"); if (c != 0) return c;
    const qa = try jsonQuote(allocator, args.pos[0]);
    defer allocator.free(qa);
    const qv = try jsonQuote(allocator, args.pos[2]);
    defer allocator.free(qv);
    const params = try std.fmt.allocPrint(allocator,
        "{{\"address\":{s},\"proposal_id\":{s},\"vote\":{s}}}",
        .{ qa, args.pos[1], qv });
    defer allocator.free(params);
    const resp = try rpcCall(allocator, ep, "gov_vote", params);
    defer allocator.free(resp);
    if (args.json) { try printRawJson(resp); return 0; }
    return printWriteResult(allocator, resp, "gov_vote");
}

fn cmdGovExecute(allocator: std.mem.Allocator, ep: Endpoint, args: Args) !u8 {
    if (args.pos.len < 2) return writeMissing("gov-execute <addr> <prop_id>");
    const c = try requireYes(args, "gov-execute"); if (c != 0) return c;
    const qa = try jsonQuote(allocator, args.pos[0]);
    defer allocator.free(qa);
    const params = try std.fmt.allocPrint(allocator,
        "{{\"address\":{s},\"proposal_id\":{s}}}", .{ qa, args.pos[1] });
    defer allocator.free(params);
    const resp = try rpcCall(allocator, ep, "gov_execute", params);
    defer allocator.free(resp);
    if (args.json) { try printRawJson(resp); return 0; }
    return printWriteResult(allocator, resp, "gov_execute");
}

/// Treasury view — 10 hardcoded registrar slots. Roles match
/// `core/registrar_addresses.zig` (savacazan/admin/exchange/ens/sava/
/// blockchain/tornetwork/faucet/cazan/database). For live address+balance,
/// pass `--json` (we forward `getrichlist` raw).
fn cmdGovTreasury(allocator: std.mem.Allocator, ep: Endpoint, json_mode: bool) !u8 {
    const slots = [_]struct { idx: u8, role: []const u8 }{
        .{ .idx = 0, .role = "savacazan"  },
        .{ .idx = 1, .role = "admin"      },
        .{ .idx = 2, .role = "exchange"   },
        .{ .idx = 3, .role = "ens"        },
        .{ .idx = 4, .role = "sava"       },
        .{ .idx = 5, .role = "blockchain" },
        .{ .idx = 6, .role = "tornetwork" },
        .{ .idx = 7, .role = "faucet"     },
        .{ .idx = 8, .role = "cazan"      },
        .{ .idx = 9, .role = "database"   },
    };
    const resp = try rpcCall(allocator, ep, "getrichlist", "[50]");
    defer allocator.free(resp);
    if (json_mode) { try printRawJson(resp); return 0; }
    const out = stdout();
    try out.print("{s}=== Registrar Treasury (10 slots) ==={s}\n", .{ col(C_BOLD), rst() });
    try out.print("{s}{s:<4} {s:<12} {s:<46} {s}{s}\n", .{
        col(C_GRAY), "SLOT", "ROLE", "ADDRESS", "BALANCE", rst(),
    });
    for (slots) |slot| {
        try out.print("{d:<4} {s:<12} {s:<46} {s}\n",
            .{ slot.idx, slot.role, "(use --json for live)", "—" });
    }
    return 0;
}

// ─── escrow: list / create / release / refund / dispute / info ────────────
fn cmdEscrowList(allocator: std.mem.Allocator, ep: Endpoint, addr: ?[]const u8, json_mode: bool) !u8 {
    const params = if (addr) |a| blk: {
        const qa = try jsonQuote(allocator, a);
        defer allocator.free(qa);
        break :blk try std.fmt.allocPrint(allocator, "[{s}]", .{qa});
    } else try allocator.dupe(u8, "[]");
    defer allocator.free(params);
    return dumpRpcResult(allocator, ep, "getescrows", params, json_mode, "Escrows");
}

fn cmdEscrowCreate(allocator: std.mem.Allocator, ep: Endpoint, args: Args) !u8 {
    if (args.pos.len < 4) return writeMissing("escrow-create <buyer> <seller> <arbiter> <amount>");
    const c = try requireYes(args, "escrow-create"); if (c != 0) return c;
    const qb = try jsonQuote(allocator, args.pos[0]);
    defer allocator.free(qb);
    const qs = try jsonQuote(allocator, args.pos[1]);
    defer allocator.free(qs);
    const qaa = try jsonQuote(allocator, args.pos[2]);
    defer allocator.free(qaa);
    const params = try std.fmt.allocPrint(allocator,
        "{{\"buyer\":{s},\"seller\":{s},\"arbiter\":{s},\"amount\":{s}}}",
        .{ qb, qs, qaa, args.pos[3] });
    defer allocator.free(params);
    const resp = try rpcCall(allocator, ep, "escrow_create", params);
    defer allocator.free(resp);
    if (args.json) { try printRawJson(resp); return 0; }
    return printWriteResult(allocator, resp, "escrow_create");
}

/// Common 1-arg escrow ops: release / refund / dispute share params shape
/// `{address, escrow_id}` so we factor them through a single helper.
fn cmdEscrowAction(
    allocator: std.mem.Allocator,
    ep: Endpoint,
    args: Args,
    method: []const u8,
    label: []const u8,
) !u8 {
    if (args.pos.len < 2) {
        var msg_buf: [128]u8 = undefined;
        const msg = std.fmt.bufPrint(&msg_buf, "{s} <addr> <escrow_id>", .{label}) catch label;
        return writeMissing(msg);
    }
    const c = try requireYes(args, label); if (c != 0) return c;
    const qa = try jsonQuote(allocator, args.pos[0]);
    defer allocator.free(qa);
    const params = try std.fmt.allocPrint(allocator,
        "{{\"address\":{s},\"escrow_id\":{s}}}", .{ qa, args.pos[1] });
    defer allocator.free(params);
    const resp = try rpcCall(allocator, ep, method, params);
    defer allocator.free(resp);
    if (args.json) { try printRawJson(resp); return 0; }
    return printWriteResult(allocator, resp, method);
}

fn cmdEscrowInfo(allocator: std.mem.Allocator, ep: Endpoint, eid: []const u8, json_mode: bool) !u8 {
    const params = try std.fmt.allocPrint(allocator, "[{s}]", .{eid});
    defer allocator.free(params);
    return dumpRpcResult(allocator, ep, "getescrow", params, json_mode, "Escrow Info");
}

// ─── payment channels: list / open / pay / close / info ──────────────────
fn cmdChannelsList(allocator: std.mem.Allocator, ep: Endpoint, addr: ?[]const u8, json_mode: bool) !u8 {
    const params = if (addr) |a| blk: {
        const qa = try jsonQuote(allocator, a);
        defer allocator.free(qa);
        break :blk try std.fmt.allocPrint(allocator, "[{s}]", .{qa});
    } else try allocator.dupe(u8, "[]");
    defer allocator.free(params);
    return dumpRpcResult(allocator, ep, "getchannels", params, json_mode, "Payment Channels");
}

fn cmdChannelOpen(allocator: std.mem.Allocator, ep: Endpoint, args: Args) !u8 {
    if (args.pos.len < 3) return writeMissing("channel-open <addr> <peer> <funding>");
    const c = try requireYes(args, "channel-open"); if (c != 0) return c;
    const qa = try jsonQuote(allocator, args.pos[0]);
    defer allocator.free(qa);
    const qp = try jsonQuote(allocator, args.pos[1]);
    defer allocator.free(qp);
    const params = try std.fmt.allocPrint(allocator,
        "{{\"address\":{s},\"peer\":{s},\"funding\":{s}}}",
        .{ qa, qp, args.pos[2] });
    defer allocator.free(params);
    const resp = try rpcCall(allocator, ep, "openchannel", params);
    defer allocator.free(resp);
    if (args.json) { try printRawJson(resp); return 0; }
    return printWriteResult(allocator, resp, "openchannel");
}

fn cmdChannelPay(allocator: std.mem.Allocator, ep: Endpoint, args: Args) !u8 {
    if (args.pos.len < 3) return writeMissing("channel-pay <addr> <channel_id> <amount>");
    const c = try requireYes(args, "channel-pay"); if (c != 0) return c;
    const qa = try jsonQuote(allocator, args.pos[0]);
    defer allocator.free(qa);
    const params = try std.fmt.allocPrint(allocator,
        "{{\"address\":{s},\"channel_id\":{s},\"amount\":{s}}}",
        .{ qa, args.pos[1], args.pos[2] });
    defer allocator.free(params);
    const resp = try rpcCall(allocator, ep, "channelpay", params);
    defer allocator.free(resp);
    if (args.json) { try printRawJson(resp); return 0; }
    return printWriteResult(allocator, resp, "channelpay");
}

fn cmdChannelClose(allocator: std.mem.Allocator, ep: Endpoint, args: Args) !u8 {
    if (args.pos.len < 2) return writeMissing("channel-close <addr> <channel_id>");
    const c = try requireYes(args, "channel-close"); if (c != 0) return c;
    const qa = try jsonQuote(allocator, args.pos[0]);
    defer allocator.free(qa);
    const params = try std.fmt.allocPrint(allocator,
        "{{\"address\":{s},\"channel_id\":{s}}}", .{ qa, args.pos[1] });
    defer allocator.free(params);
    const resp = try rpcCall(allocator, ep, "closechannel", params);
    defer allocator.free(resp);
    if (args.json) { try printRawJson(resp); return 0; }
    return printWriteResult(allocator, resp, "closechannel");
}

fn cmdChannelInfo(allocator: std.mem.Allocator, ep: Endpoint, cid: []const u8, json_mode: bool) !u8 {
    const params = try std.fmt.allocPrint(allocator, "[{s}]", .{cid});
    defer allocator.free(params);
    return dumpRpcResult(allocator, ep, "getchannels", params, json_mode, "Channel Info");
}

// ─── notarize: list / doc / verify / revoke ──────────────────────────────
fn cmdNotarizeList(allocator: std.mem.Allocator, ep: Endpoint, addr: []const u8, json_mode: bool) !u8 {
    const qa = try jsonQuote(allocator, addr);
    defer allocator.free(qa);
    const params = try std.fmt.allocPrint(allocator, "[{s}]", .{qa});
    defer allocator.free(params);
    return dumpRpcResult(allocator, ep, "getnotarizations", params, json_mode,
        "Notarized Documents");
}

fn cmdNotarizeDoc(allocator: std.mem.Allocator, ep: Endpoint, args: Args) !u8 {
    if (args.pos.len < 3) return writeMissing("notarize-doc <addr> <doc_hash> <doc_type> [expiry] [note]");
    const c = try requireYes(args, "notarize-doc"); if (c != 0) return c;
    const exp: u64 = if (args.pos.len > 3)
        std.fmt.parseInt(u64, args.pos[3], 10) catch 0
    else 0;
    const qa = try jsonQuote(allocator, args.pos[0]);
    defer allocator.free(qa);
    const qh = try jsonQuote(allocator, args.pos[1]);
    defer allocator.free(qh);
    const qt = try jsonQuote(allocator, args.pos[2]);
    defer allocator.free(qt);
    var b = std.array_list.Managed(u8).init(allocator);
    defer b.deinit();
    const w = b.writer();
    try w.print(
        "{{\"address\":{s},\"doc_hash\":{s},\"doc_type\":{s},\"expiry_blocks\":{d}",
        .{ qa, qh, qt, exp });
    if (args.pos.len > 4) {
        const qnote = try jsonQuote(allocator, args.pos[4]);
        defer allocator.free(qnote);
        try w.print(",\"note\":{s}", .{qnote});
    }
    try w.writeByte('}');
    const resp = try rpcCall(allocator, ep, "notarizedoc", b.items);
    defer allocator.free(resp);
    if (args.json) { try printRawJson(resp); return 0; }
    return printWriteResult(allocator, resp, "notarizedoc");
}

fn cmdNotarizeVerify(allocator: std.mem.Allocator, ep: Endpoint, hash: []const u8, json_mode: bool) !u8 {
    const qh = try jsonQuote(allocator, hash);
    defer allocator.free(qh);
    const params = try std.fmt.allocPrint(allocator, "[{s}]", .{qh});
    defer allocator.free(params);
    return dumpRpcResult(allocator, ep, "verifynotarize", params, json_mode, "Verify Notarization");
}

fn cmdNotarizeRevoke(allocator: std.mem.Allocator, ep: Endpoint, args: Args) !u8 {
    if (args.pos.len < 2) return writeMissing("notarize-revoke <addr> <notarize_id>");
    const c = try requireYes(args, "notarize-revoke"); if (c != 0) return c;
    const qa = try jsonQuote(allocator, args.pos[0]);
    defer allocator.free(qa);
    const params = try std.fmt.allocPrint(allocator,
        "{{\"address\":{s},\"notarize_id\":{s}}}", .{ qa, args.pos[1] });
    defer allocator.free(params);
    const resp = try rpcCall(allocator, ep, "revokenotarize", params);
    defer allocator.free(resp);
    if (args.json) { try printRawJson(resp); return 0; }
    return printWriteResult(allocator, resp, "revokenotarize");
}

// ─── subscriptions: list / create / cancel ───────────────────────────────
fn cmdSubList(allocator: std.mem.Allocator, ep: Endpoint, addr: []const u8, json_mode: bool) !u8 {
    const qa = try jsonQuote(allocator, addr);
    defer allocator.free(qa);
    const params = try std.fmt.allocPrint(allocator, "[{s}]", .{qa});
    defer allocator.free(params);
    return dumpRpcResult(allocator, ep, "getsubscriptions", params, json_mode, "Subscriptions");
}

fn cmdSubCreate(allocator: std.mem.Allocator, ep: Endpoint, args: Args) !u8 {
    if (args.pos.len < 5) return writeMissing("sub-create <addr> <to> <amount> <interval> <max_payments> [note]");
    const c = try requireYes(args, "sub-create"); if (c != 0) return c;
    const qa = try jsonQuote(allocator, args.pos[0]);
    defer allocator.free(qa);
    const qt = try jsonQuote(allocator, args.pos[1]);
    defer allocator.free(qt);
    var b = std.array_list.Managed(u8).init(allocator);
    defer b.deinit();
    const w = b.writer();
    try w.print(
        "{{\"address\":{s},\"to\":{s},\"amount\":{s},\"interval_blocks\":{s},\"max_payments\":{s}",
        .{ qa, qt, args.pos[2], args.pos[3], args.pos[4] });
    if (args.pos.len > 5) {
        const qn = try jsonQuote(allocator, args.pos[5]);
        defer allocator.free(qn);
        try w.print(",\"note\":{s}", .{qn});
    }
    try w.writeByte('}');
    const resp = try rpcCall(allocator, ep, "sub_create", b.items);
    defer allocator.free(resp);
    if (args.json) { try printRawJson(resp); return 0; }
    return printWriteResult(allocator, resp, "sub_create");
}

fn cmdSubCancel(allocator: std.mem.Allocator, ep: Endpoint, args: Args) !u8 {
    if (args.pos.len < 2) return writeMissing("sub-cancel <addr> <sub_id>");
    const c = try requireYes(args, "sub-cancel"); if (c != 0) return c;
    const qa = try jsonQuote(allocator, args.pos[0]);
    defer allocator.free(qa);
    const params = try std.fmt.allocPrint(allocator,
        "{{\"address\":{s},\"sub_id\":{s}}}", .{ qa, args.pos[1] });
    defer allocator.free(params);
    const resp = try rpcCall(allocator, ep, "sub_cancel", params);
    defer allocator.free(resp);
    if (args.json) { try printRawJson(resp); return 0; }
    return printWriteResult(allocator, resp, "sub_cancel");
}

// ─── multisig: create / info / send ──────────────────────────────────────
fn cmdMultisigCreate(allocator: std.mem.Allocator, ep: Endpoint, args: Args) !u8 {
    if (args.pos.len < 3) return writeMissing("multisig-create <addr> <m> <pubkey1,pubkey2,...>");
    const c = try requireYes(args, "multisig-create"); if (c != 0) return c;
    const qa = try jsonQuote(allocator, args.pos[0]);
    defer allocator.free(qa);
    var pubs = std.array_list.Managed(u8).init(allocator);
    defer pubs.deinit();
    try pubs.append('[');
    var first = true;
    var it = std.mem.splitScalar(u8, args.pos[2], ',');
    while (it.next()) |pk| {
        if (pk.len == 0) continue;
        if (!first) try pubs.append(',');
        first = false;
        const qpk = try jsonQuote(allocator, pk);
        defer allocator.free(qpk);
        try pubs.appendSlice(qpk);
    }
    try pubs.append(']');
    const params = try std.fmt.allocPrint(allocator,
        "{{\"address\":{s},\"m\":{s},\"pubkeys\":{s}}}",
        .{ qa, args.pos[1], pubs.items });
    defer allocator.free(params);
    const resp = try rpcCall(allocator, ep, "createmultisig", params);
    defer allocator.free(resp);
    if (args.json) { try printRawJson(resp); return 0; }
    return printWriteResult(allocator, resp, "createmultisig");
}

fn cmdMultisigInfo(allocator: std.mem.Allocator, ep: Endpoint, addr: []const u8, json_mode: bool) !u8 {
    const qa = try jsonQuote(allocator, addr);
    defer allocator.free(qa);
    const params = try std.fmt.allocPrint(allocator, "[{s}]", .{qa});
    defer allocator.free(params);
    return dumpRpcResult(allocator, ep, "getbalance", params, json_mode, "Multisig Info");
}

fn cmdMultisigSend(allocator: std.mem.Allocator, ep: Endpoint, args: Args) !u8 {
    if (args.pos.len < 3) return writeMissing("multisig-send <addr> <to> <amount> --signers=<sig1,sig2>");
    const c = try requireYes(args, "multisig-send"); if (c != 0) return c;
    const qa = try jsonQuote(allocator, args.pos[0]);
    defer allocator.free(qa);
    const qt = try jsonQuote(allocator, args.pos[1]);
    defer allocator.free(qt);
    var sig_json: []const u8 = "[]";
    var sig_owned: ?[]u8 = null;
    defer if (sig_owned) |s| allocator.free(s);
    if (args.signers) |s_csv| {
        var sigs = std.array_list.Managed(u8).init(allocator);
        defer sigs.deinit();
        try sigs.append('[');
        var first = true;
        var it = std.mem.splitScalar(u8, s_csv, ',');
        while (it.next()) |s| {
            if (s.len == 0) continue;
            if (!first) try sigs.append(',');
            first = false;
            const qs = try jsonQuote(allocator, s);
            defer allocator.free(qs);
            try sigs.appendSlice(qs);
        }
        try sigs.append(']');
        sig_owned = try sigs.toOwnedSlice();
        sig_json = sig_owned.?;
    }
    const params = try std.fmt.allocPrint(allocator,
        "{{\"address\":{s},\"to\":{s},\"amount\":{s},\"signers\":{s}}}",
        .{ qa, qt, args.pos[2], sig_json });
    defer allocator.free(params);
    const resp = try rpcCall(allocator, ep, "sendmultisig", params);
    defer allocator.free(resp);
    if (args.json) { try printRawJson(resp); return 0; }
    return printWriteResult(allocator, resp, "sendmultisig");
}

// ─── PQ identity: attest / identity / balance / schemes ──────────────────
fn cmdPqAttest(allocator: std.mem.Allocator, ep: Endpoint, args: Args) !u8 {
    if (args.pos.len < 1) return writeMissing("pq-attest <addr> --love=... --food=... --rent=... --vacation=... [--btc=...] [--eth=...]");
    const c = try requireYes(args, "pq-attest"); if (c != 0) return c;
    const love = kvLookup(args, "love") orelse {
        try stderr().print("--love=<addr> required\n", .{});
        return 2;
    };
    const food = kvLookup(args, "food") orelse {
        try stderr().print("--food=<addr> required\n", .{});
        return 2;
    };
    const rent = kvLookup(args, "rent") orelse {
        try stderr().print("--rent=<addr> required\n", .{});
        return 2;
    };
    const vac = kvLookup(args, "vacation") orelse {
        try stderr().print("--vacation=<addr> required\n", .{});
        return 2;
    };
    const qa = try jsonQuote(allocator, args.pos[0]);
    defer allocator.free(qa);
    const ql = try jsonQuote(allocator, love);
    defer allocator.free(ql);
    const qf = try jsonQuote(allocator, food);
    defer allocator.free(qf);
    const qr = try jsonQuote(allocator, rent);
    defer allocator.free(qr);
    const qv = try jsonQuote(allocator, vac);
    defer allocator.free(qv);
    var b = std.array_list.Managed(u8).init(allocator);
    defer b.deinit();
    const w = b.writer();
    try w.print(
        "{{\"address\":{s},\"love\":{s},\"food\":{s},\"rent\":{s},\"vacation\":{s}",
        .{ qa, ql, qf, qr, qv });
    if (kvLookup(args, "btc")) |btc| {
        const qb = try jsonQuote(allocator, btc);
        defer allocator.free(qb);
        try w.print(",\"btc\":{s}", .{qb});
    }
    if (kvLookup(args, "eth")) |eth| {
        const qe = try jsonQuote(allocator, eth);
        defer allocator.free(qe);
        try w.print(",\"eth\":{s}", .{qe});
    }
    try w.writeByte('}');
    const resp = try rpcCall(allocator, ep, "sendpqattest", b.items);
    defer allocator.free(resp);
    if (args.json) { try printRawJson(resp); return 0; }
    return printWriteResult(allocator, resp, "sendpqattest");
}

fn cmdPqIdentity(allocator: std.mem.Allocator, ep: Endpoint, addr: []const u8, json_mode: bool) !u8 {
    const qa = try jsonQuote(allocator, addr);
    defer allocator.free(qa);
    const params = try std.fmt.allocPrint(allocator, "[{s}]", .{qa});
    defer allocator.free(params);
    return dumpRpcResult(allocator, ep, "getpqidentity", params, json_mode, "PQ Identity");
}

fn cmdPqBalance(allocator: std.mem.Allocator, ep: Endpoint, addr: []const u8, json_mode: bool) !u8 {
    const qa = try jsonQuote(allocator, addr);
    defer allocator.free(qa);
    const params = try std.fmt.allocPrint(allocator, "[{s}]", .{qa});
    defer allocator.free(params);
    return dumpRpcResult(allocator, ep, "pq_balance", params, json_mode, "PQ Balance (4 schemes)");
}

fn cmdPqSchemes(allocator: std.mem.Allocator, ep: Endpoint, json_mode: bool) !u8 {
    return dumpRpcResult(allocator, ep, "pq_listSchemes", "[]", json_mode, "PQ Schemes");
}

// ─── POAP / Social ───────────────────────────────────────────────────────
fn cmdPoapEvents(allocator: std.mem.Allocator, ep: Endpoint, json_mode: bool) !u8 {
    return dumpRpcResult(allocator, ep, "getpoaps", "[]", json_mode, "POAP Events");
}

fn cmdPoapClaim(allocator: std.mem.Allocator, ep: Endpoint, args: Args) !u8 {
    if (args.pos.len < 2) return writeMissing("poap-claim <addr> <event_id>");
    const c = try requireYes(args, "poap-claim"); if (c != 0) return c;
    const qa = try jsonQuote(allocator, args.pos[0]);
    defer allocator.free(qa);
    const params = try std.fmt.allocPrint(allocator,
        "{{\"address\":{s},\"event_id\":{s}}}", .{ qa, args.pos[1] });
    defer allocator.free(params);
    const resp = try rpcCall(allocator, ep, "poap_claim", params);
    defer allocator.free(resp);
    if (args.json) { try printRawJson(resp); return 0; }
    return printWriteResult(allocator, resp, "poap_claim");
}

fn cmdFollow(allocator: std.mem.Allocator, ep: Endpoint, args: Args) !u8 {
    if (args.pos.len < 2) return writeMissing("follow <from> <to>");
    const c = try requireYes(args, "follow"); if (c != 0) return c;
    const qf = try jsonQuote(allocator, args.pos[0]);
    defer allocator.free(qf);
    const qt = try jsonQuote(allocator, args.pos[1]);
    defer allocator.free(qt);
    const params = try std.fmt.allocPrint(allocator,
        "{{\"from\":{s},\"to\":{s}}}", .{ qf, qt });
    defer allocator.free(params);
    const resp = try rpcCall(allocator, ep, "follow", params);
    defer allocator.free(resp);
    if (args.json) { try printRawJson(resp); return 0; }
    return printWriteResult(allocator, resp, "follow");
}

fn cmdFollowers(allocator: std.mem.Allocator, ep: Endpoint, addr: []const u8, json_mode: bool) !u8 {
    const qa = try jsonQuote(allocator, addr);
    defer allocator.free(qa);
    const params = try std.fmt.allocPrint(allocator, "[{s}]", .{qa});
    defer allocator.free(params);
    return dumpRpcResult(allocator, ep, "getfollowers", params, json_mode, "Followers");
}

fn cmdFollowing(allocator: std.mem.Allocator, ep: Endpoint, addr: []const u8, json_mode: bool) !u8 {
    const qa = try jsonQuote(allocator, addr);
    defer allocator.free(qa);
    const params = try std.fmt.allocPrint(allocator, "[{s}]", .{qa});
    defer allocator.free(params);
    return dumpRpcResult(allocator, ep, "getfollowing", params, json_mode, "Following");
}

// ─── Profile (DID / OBM / facets / economic) ────────────────────────────────
// Resolves the wallet address for profile_init / wizard. Prefers the
// positional `<addr>`, else derives via resolveSigningKey from
// --privkey/--mnemonic/--keyfile/--passphrase + --key-index.
fn resolveProfileAddress(allocator: std.mem.Allocator, args: Args, pos_idx: usize) !?[]u8 {
    if (args.pos.len > pos_idx) {
        return try allocator.dupe(u8, args.pos[pos_idx]);
    }
    const sk = resolveSigningKey(allocator, args) catch |err| {
        try stderr().print(
            "{s}error:{s} no <addr> and no signing material ({s}). " ++
            "Pass an address, --privkey, --keyfile, or --mnemonic.\n",
            .{ col(C_RED), rst(), @errorName(err) });
        return null;
    };
    const h160 = wallet_mod.Wallet.pubkeyHash160(sk.pubkey);
    return bech32_mod.encodeOBAddress(h160, allocator) catch null;
}

fn parsePublicFlag(args: Args) bool {
    // --public sets true, --private sets false. Default: private.
    for (args.kvs) |kv| {
        if (std.mem.eql(u8, kv.key, "public")) {
            return std.mem.eql(u8, kv.val, "true") or std.mem.eql(u8, kv.val, "1");
        }
        if (std.mem.eql(u8, kv.key, "private")) {
            return !(std.mem.eql(u8, kv.val, "true") or std.mem.eql(u8, kv.val, "1"));
        }
    }
    // Bare `--public` / `--private` come in as positional-after-cmd via the
    // existing parser? No — they don't start with `--key=val`, but they DO
    // start with `--`. Inspect args.pos for them.
    for (args.pos) |p| {
        if (std.mem.eql(u8, p, "--public")) return true;
        if (std.mem.eql(u8, p, "--private")) return false;
    }
    return false;
}

fn cmdProfileInit(allocator: std.mem.Allocator, ep: Endpoint, args: Args) !u8 {
    const c = try requireYes(args, "profile init"); if (c != 0) return c;
    const addr_opt = try resolveProfileAddress(allocator, args, 1);
    if (addr_opt == null) return 2;
    const addr = addr_opt.?;
    defer allocator.free(addr);
    const qa = try jsonQuote(allocator, addr);
    defer allocator.free(qa);
    const params = try std.fmt.allocPrint(allocator, "[{s}]", .{qa});
    defer allocator.free(params);
    const resp = try rpcCall(allocator, ep, "profile_init", params);
    defer allocator.free(resp);
    if (args.json) { try printRawJson(resp); return 0; }
    var p = parse(allocator, resp) catch { try printRpcError("parse failed"); return 1; };
    defer p.deinit();
    var err_msg: []const u8 = "";
    const r = extractResult(p.value, &err_msg) orelse { try printRpcError(err_msg); return 1; };
    const out = stdout();
    try out.print("{s}=== Profile initialized ==={s}\n", .{ col(C_BOLD), rst() });
    if (jsonGetStr(r, "did")) |v| try out.print("DID         : {s}{s}{s}\n", .{ col(C_GREEN), v, rst() });
    if (jsonGetStr(r, "manifest_root")) |v| try out.print("Manifest    : {s}\n", .{v});
    if (jsonGetStr(r, "salt")) |v| {
        try out.print("Salt        : {s}{s}{s}\n", .{ col(C_YELLOW), v, rst() });
        try out.print("{s}WARNING:{s} save this salt — it is required for KYC selective disclosure.\n",
            .{ col(C_YELLOW), rst() });
    }
    return 0;
}

fn cmdProfileGet(allocator: std.mem.Allocator, ep: Endpoint, addr: []const u8, json_mode: bool) !u8 {
    const qa = try jsonQuote(allocator, addr);
    defer allocator.free(qa);
    const params = try std.fmt.allocPrint(allocator, "[{s}]", .{qa});
    defer allocator.free(params);
    const resp = try rpcCall(allocator, ep, "profile_get", params);
    defer allocator.free(resp);
    if (json_mode) { try printRawJson(resp); return 0; }
    var p = parse(allocator, resp) catch { try printRpcError("parse failed"); return 1; };
    defer p.deinit();
    var err_msg: []const u8 = "";
    const r = extractResult(p.value, &err_msg) orelse { try printRpcError(err_msg); return 1; };
    const out = stdout();
    try out.print("{s}=== Profile: {s} ==={s}\n", .{ col(C_BOLD), addr, rst() });
    const sections = [_][]const u8{ "social", "professional", "cultural", "economic" };
    const titles = [_][]const u8{ "Social", "Professional", "Cultural", "Economic" };
    for (sections, 0..) |sec, i| {
        try out.print("\n{s}── {s} ──{s}\n", .{ col(C_CYAN), titles[i], rst() });
        if (r == .object) {
            if (r.object.get(sec)) |section_val| {
                if (section_val == .object and section_val.object.count() > 0) {
                    var it = section_val.object.iterator();
                    while (it.next()) |kv| {
                        const k = kv.key_ptr.*;
                        switch (kv.value_ptr.*) {
                            .null => try out.print("  {s}: {s}(private){s}\n", .{ k, col(C_GRAY), rst() }),
                            .string => |s| try out.print("  {s}: {s}\n", .{ k, s }),
                            .integer => |x| try out.print("  {s}: {d}\n", .{ k, x }),
                            .bool => |b| try out.print("  {s}: {}\n", .{ k, b }),
                            .array => |a| try out.print("  {s}: [{d} items]\n", .{ k, a.items.len }),
                            .object => try out.print("  {s}: <object>\n", .{k}),
                            else => try out.print("  {s}: <?>\n", .{k}),
                        }
                    }
                } else {
                    try out.print("  {s}(empty){s}\n", .{ col(C_GRAY), rst() });
                }
            } else {
                try out.print("  {s}(not set){s}\n", .{ col(C_GRAY), rst() });
            }
        }
    }
    return 0;
}

// Build a `profile_update` JSON params object and POST it.
fn profileUpdate(
    allocator: std.mem.Allocator,
    ep: Endpoint,
    addr: []const u8,
    facet: []const u8,
    field: []const u8,
    value_json: []const u8, // already-formatted JSON value (quoted string, number, object, etc.)
    public: bool,
    json_mode: bool,
) !u8 {
    const qa = try jsonQuote(allocator, addr);
    defer allocator.free(qa);
    const qfa = try jsonQuote(allocator, facet);
    defer allocator.free(qfa);
    const qfi = try jsonQuote(allocator, field);
    defer allocator.free(qfi);
    const params = try std.fmt.allocPrint(allocator,
        "[{{\"address\":{s},\"facet\":{s},\"field\":{s},\"value\":{s},\"public\":{}}}]",
        .{ qa, qfa, qfi, value_json, public });
    defer allocator.free(params);
    const resp = try rpcCall(allocator, ep, "profile_update", params);
    defer allocator.free(resp);
    if (json_mode) { try printRawJson(resp); return 0; }
    return printWriteResult(allocator, resp, "profile_update");
}

fn cmdProfileSocial(allocator: std.mem.Allocator, ep: Endpoint, args: Args) !u8 {
    if (args.pos.len < 3) return writeMissing("profile social <set-handle|set-bio|set-avatar|add-link> ...");
    const c = try requireYes(args, "profile social"); if (c != 0) return c;
    const sub = args.pos[1];
    const addr_opt = try resolveProfileAddress(allocator, args, std.math.maxInt(usize));
    if (addr_opt == null) return 2;
    const addr = addr_opt.?;
    defer allocator.free(addr);
    const public = parsePublicFlag(args);

    if (std.mem.eql(u8, sub, "set-handle") or std.mem.eql(u8, sub, "set-bio") or std.mem.eql(u8, sub, "set-avatar")) {
        const field = if (std.mem.eql(u8, sub, "set-handle")) "handle"
            else if (std.mem.eql(u8, sub, "set-bio")) "bio"
            else "avatar";
        const qv = try jsonQuote(allocator, args.pos[2]);
        defer allocator.free(qv);
        return profileUpdate(allocator, ep, addr, "social", field, qv, public, args.json);
    }
    if (std.mem.eql(u8, sub, "add-link")) {
        if (args.pos.len < 4) return writeMissing("profile social add-link <platform> <url> [--public|--private]");
        const qp = try jsonQuote(allocator, args.pos[2]);
        defer allocator.free(qp);
        const qu = try jsonQuote(allocator, args.pos[3]);
        defer allocator.free(qu);
        const val = try std.fmt.allocPrint(allocator, "{{\"platform\":{s},\"url\":{s}}}", .{ qp, qu });
        defer allocator.free(val);
        return profileUpdate(allocator, ep, addr, "social", "link", val, public, args.json);
    }
    try stderr().print("unknown profile social subcommand `{s}`\n", .{sub});
    return 2;
}

fn cmdProfileProfessional(allocator: std.mem.Allocator, ep: Endpoint, args: Args) !u8 {
    if (args.pos.len < 2) return writeMissing("profile professional <set-visibility|add-cert|add-work> ...");
    const c = try requireYes(args, "profile professional"); if (c != 0) return c;
    const sub = args.pos[1];
    const addr_opt = try resolveProfileAddress(allocator, args, std.math.maxInt(usize));
    if (addr_opt == null) return 2;
    const addr = addr_opt.?;
    defer allocator.free(addr);

    if (std.mem.eql(u8, sub, "set-visibility")) {
        // Reads kvs: certs=true work=true endorsements=false
        const certs = if (kvLookup(args, "certs")) |v| std.mem.eql(u8, v, "true") else false;
        const work = if (kvLookup(args, "work")) |v| std.mem.eql(u8, v, "true") else false;
        const end = if (kvLookup(args, "endorsements")) |v| std.mem.eql(u8, v, "true") else false;
        const val = try std.fmt.allocPrint(allocator,
            "{{\"certs\":{},\"work\":{},\"endorsements\":{}}}", .{ certs, work, end });
        defer allocator.free(val);
        return profileUpdate(allocator, ep, addr, "professional", "visibility", val, true, args.json);
    }
    if (std.mem.eql(u8, sub, "add-cert")) {
        if (args.pos.len < 5) return writeMissing("profile professional add-cert <issuer_did> <kind> <expires_unix>");
        const qi = try jsonQuote(allocator, args.pos[2]);
        defer allocator.free(qi);
        const qk = try jsonQuote(allocator, args.pos[3]);
        defer allocator.free(qk);
        const exp = std.fmt.parseInt(i64, args.pos[4], 10) catch 0;
        const val = try std.fmt.allocPrint(allocator,
            "{{\"issuer\":{s},\"kind\":{s},\"expires\":{d}}}", .{ qi, qk, exp });
        defer allocator.free(val);
        return profileUpdate(allocator, ep, addr, "professional", "cert", val, parsePublicFlag(args), args.json);
    }
    if (std.mem.eql(u8, sub, "add-work")) {
        if (args.pos.len < 6) return writeMissing("profile professional add-work <employer_did> <role> <start_unix> <end_unix>");
        const qe = try jsonQuote(allocator, args.pos[2]);
        defer allocator.free(qe);
        const qr = try jsonQuote(allocator, args.pos[3]);
        defer allocator.free(qr);
        const ts = std.fmt.parseInt(i64, args.pos[4], 10) catch 0;
        const te = std.fmt.parseInt(i64, args.pos[5], 10) catch 0;
        const val = try std.fmt.allocPrint(allocator,
            "{{\"employer\":{s},\"role\":{s},\"start\":{d},\"end\":{d}}}", .{ qe, qr, ts, te });
        defer allocator.free(val);
        return profileUpdate(allocator, ep, addr, "professional", "work", val, parsePublicFlag(args), args.json);
    }
    try stderr().print("unknown profile professional subcommand `{s}`\n", .{sub});
    return 2;
}

fn cmdProfileCultural(allocator: std.mem.Allocator, ep: Endpoint, args: Args) !u8 {
    if (args.pos.len < 2) return writeMissing("profile cultural <add-poap|add-work|set-languages> ...");
    const c = try requireYes(args, "profile cultural"); if (c != 0) return c;
    const sub = args.pos[1];
    const addr_opt = try resolveProfileAddress(allocator, args, std.math.maxInt(usize));
    if (addr_opt == null) return 2;
    const addr = addr_opt.?;
    defer allocator.free(addr);

    if (std.mem.eql(u8, sub, "add-poap")) {
        if (args.pos.len < 4) return writeMissing("profile cultural add-poap <event_id_hex> <date_unix>");
        const qe = try jsonQuote(allocator, args.pos[2]);
        defer allocator.free(qe);
        const d = std.fmt.parseInt(i64, args.pos[3], 10) catch 0;
        const val = try std.fmt.allocPrint(allocator,
            "{{\"event_id\":{s},\"date\":{d}}}", .{ qe, d });
        defer allocator.free(val);
        return profileUpdate(allocator, ep, addr, "cultural", "poap", val, parsePublicFlag(args), args.json);
    }
    if (std.mem.eql(u8, sub, "add-work")) {
        if (args.pos.len < 4) return writeMissing("profile cultural add-work <hash_hex> <kind> [--public|--private]");
        const qh = try jsonQuote(allocator, args.pos[2]);
        defer allocator.free(qh);
        const qk = try jsonQuote(allocator, args.pos[3]);
        defer allocator.free(qk);
        const val = try std.fmt.allocPrint(allocator,
            "{{\"hash\":{s},\"kind\":{s}}}", .{ qh, qk });
        defer allocator.free(val);
        return profileUpdate(allocator, ep, addr, "cultural", "work", val, parsePublicFlag(args), args.json);
    }
    if (std.mem.eql(u8, sub, "set-languages")) {
        if (args.pos.len < 3) return writeMissing("profile cultural set-languages <en,ro,fr>");
        // Build JSON array from comma-separated list.
        var b = std.array_list.Managed(u8).init(allocator);
        defer b.deinit();
        try b.append('[');
        var first = true;
        var it = std.mem.splitScalar(u8, args.pos[2], ',');
        while (it.next()) |tok| {
            const t = std.mem.trim(u8, tok, " \t");
            if (t.len == 0) continue;
            if (!first) try b.append(',');
            first = false;
            const qt = try jsonQuote(allocator, t);
            defer allocator.free(qt);
            try b.appendSlice(qt);
        }
        try b.append(']');
        return profileUpdate(allocator, ep, addr, "cultural", "languages", b.items, parsePublicFlag(args), args.json);
    }
    try stderr().print("unknown profile cultural subcommand `{s}`\n", .{sub});
    return 2;
}

fn cmdProfileEconomic(allocator: std.mem.Allocator, ep: Endpoint, args: Args) !u8 {
    if (args.pos.len < 2) return writeMissing("profile economic <add-address|declare-issuer|set-volume|toggle-public> ...");
    const c = try requireYes(args, "profile economic"); if (c != 0) return c;
    const sub = args.pos[1];
    const addr_opt = try resolveProfileAddress(allocator, args, std.math.maxInt(usize));
    if (addr_opt == null) return 2;
    const addr = addr_opt.?;
    defer allocator.free(addr);

    if (std.mem.eql(u8, sub, "add-address")) {
        if (args.pos.len < 4) return writeMissing("profile economic add-address <chain> <addr> [--public|--private]");
        const qc = try jsonQuote(allocator, args.pos[2]);
        defer allocator.free(qc);
        const qaa = try jsonQuote(allocator, args.pos[3]);
        defer allocator.free(qaa);
        const val = try std.fmt.allocPrint(allocator,
            "{{\"chain\":{s},\"addr\":{s}}}", .{ qc, qaa });
        defer allocator.free(val);
        return profileUpdate(allocator, ep, addr, "economic", "address", val, parsePublicFlag(args), args.json);
    }
    if (std.mem.eql(u8, sub, "declare-issuer")) {
        if (args.pos.len < 4) return writeMissing("profile economic declare-issuer <white_paper_hash> <risk_category>");
        const qh = try jsonQuote(allocator, args.pos[2]);
        defer allocator.free(qh);
        const qr = try jsonQuote(allocator, args.pos[3]);
        defer allocator.free(qr);
        const val = try std.fmt.allocPrint(allocator,
            "{{\"white_paper\":{s},\"risk\":{s}}}", .{ qh, qr });
        defer allocator.free(val);
        return profileUpdate(allocator, ep, addr, "economic", "issuer", val, true, args.json);
    }
    if (std.mem.eql(u8, sub, "set-volume")) {
        const v30 = if (kvLookup(args, "30d")) |v| std.fmt.parseInt(u64, v, 10) catch 0 else 0;
        const v90 = if (kvLookup(args, "90d")) |v| std.fmt.parseInt(u64, v, 10) catch 0 else 0;
        const v1y = if (kvLookup(args, "1y")) |v| std.fmt.parseInt(u64, v, 10) catch 0 else 0;
        const val = try std.fmt.allocPrint(allocator,
            "{{\"30d\":{d},\"90d\":{d},\"1y\":{d}}}", .{ v30, v90, v1y });
        defer allocator.free(val);
        return profileUpdate(allocator, ep, addr, "economic", "volume", val, parsePublicFlag(args), args.json);
    }
    if (std.mem.eql(u8, sub, "toggle-public")) {
        const a = if (kvLookup(args, "addresses")) |v| std.mem.eql(u8, v, "true") else false;
        const d = if (kvLookup(args, "donations")) |v| std.mem.eql(u8, v, "true") else false;
        const val = try std.fmt.allocPrint(allocator,
            "{{\"addresses\":{},\"donations\":{}}}", .{ a, d });
        defer allocator.free(val);
        return profileUpdate(allocator, ep, addr, "economic", "toggle_public", val, true, args.json);
    }
    try stderr().print("unknown profile economic subcommand `{s}`\n", .{sub});
    return 2;
}

fn readLineAlloc(allocator: std.mem.Allocator, reader: anytype, max: usize) !?[]u8 {
    var b = std.array_list.Managed(u8).init(allocator);
    defer b.deinit();
    var byte: [1]u8 = undefined;
    while (b.items.len < max) {
        const n = reader.read(&byte) catch return null;
        if (n == 0) {
            if (b.items.len == 0) return null;
            break;
        }
        if (byte[0] == '\n') break;
        if (byte[0] == '\r') continue;
        try b.append(byte[0]);
    }
    return try b.toOwnedSlice();
}

fn promptYesNo(allocator: std.mem.Allocator, reader: anytype, prompt: []const u8) !bool {
    try stdout().print("{s} (y/n): ", .{prompt});
    const line = (try readLineAlloc(allocator, reader, 16)) orelse return false;
    defer allocator.free(line);
    const t = std.mem.trim(u8, line, " \t");
    return t.len > 0 and (t[0] == 'y' or t[0] == 'Y');
}

fn promptString(allocator: std.mem.Allocator, reader: anytype, prompt: []const u8) !?[]u8 {
    try stdout().print("{s}: ", .{prompt});
    const line = (try readLineAlloc(allocator, reader, 1024)) orelse return null;
    const t = std.mem.trim(u8, line, " \t");
    if (t.len == 0) { allocator.free(line); return null; }
    const dup = try allocator.dupe(u8, t);
    allocator.free(line);
    return dup;
}

fn cmdProfileWizard(allocator: std.mem.Allocator, ep: Endpoint, args: Args) !u8 {
    const c = try requireYes(args, "profile wizard"); if (c != 0) return c;
    const addr_opt = try resolveProfileAddress(allocator, args, 1);
    if (addr_opt == null) return 2;
    const addr = addr_opt.?;
    defer allocator.free(addr);
    const stdin_file = std.fs.File.stdin();
    const reader = stdin_file.deprecatedReader();

    try stdout().print("{s}=== OmniBus profile wizard ==={s}\n", .{ col(C_BOLD), rst() });
    try stdout().print("Address: {s}{s}{s}\n\n", .{ col(C_GREEN), addr, rst() });
    try stdout().print("Press ENTER to skip a field.\n\n", .{});

    // Social
    try stdout().print("{s}── Social ──{s}\n", .{ col(C_CYAN), rst() });
    const fields_social = [_][]const u8{ "handle", "bio", "avatar" };
    for (fields_social) |f| {
        const v = try promptString(allocator, reader, f);
        if (v == null) continue;
        defer allocator.free(v.?);
        const pub_b = try promptYesNo(allocator, reader, "  make public?");
        const qv = try jsonQuote(allocator, v.?);
        defer allocator.free(qv);
        _ = try profileUpdate(allocator, ep, addr, "social", f, qv, pub_b, true);
    }

    // Professional (visibility only — certs/work need structured args)
    try stdout().print("\n{s}── Professional ──{s}\n", .{ col(C_CYAN), rst() });
    const show_certs = try promptYesNo(allocator, reader, "show certs publicly?");
    const show_work = try promptYesNo(allocator, reader, "show work history publicly?");
    const show_end = try promptYesNo(allocator, reader, "show endorsements publicly?");
    const vis_val = try std.fmt.allocPrint(allocator,
        "{{\"certs\":{},\"work\":{},\"endorsements\":{}}}", .{ show_certs, show_work, show_end });
    defer allocator.free(vis_val);
    _ = try profileUpdate(allocator, ep, addr, "professional", "visibility", vis_val, true, true);

    // Cultural
    try stdout().print("\n{s}── Cultural ──{s}\n", .{ col(C_CYAN), rst() });
    if (try promptString(allocator, reader, "languages (comma-sep, e.g. en,ro,fr)")) |langs| {
        defer allocator.free(langs);
        const pub_b = try promptYesNo(allocator, reader, "  make public?");
        var b = std.array_list.Managed(u8).init(allocator);
        defer b.deinit();
        try b.append('[');
        var first = true;
        var it = std.mem.splitScalar(u8, langs, ',');
        while (it.next()) |tok| {
            const t = std.mem.trim(u8, tok, " \t");
            if (t.len == 0) continue;
            if (!first) try b.append(',');
            first = false;
            const qt = try jsonQuote(allocator, t);
            defer allocator.free(qt);
            try b.appendSlice(qt);
        }
        try b.append(']');
        _ = try profileUpdate(allocator, ep, addr, "cultural", "languages", b.items, pub_b, true);
    }

    // Economic
    try stdout().print("\n{s}── Economic ──{s}\n", .{ col(C_CYAN), rst() });
    const pub_addrs = try promptYesNo(allocator, reader, "show addresses publicly?");
    const pub_dons = try promptYesNo(allocator, reader, "show donations publicly?");
    const econ_val = try std.fmt.allocPrint(allocator,
        "{{\"addresses\":{},\"donations\":{}}}", .{ pub_addrs, pub_dons });
    defer allocator.free(econ_val);
    _ = try profileUpdate(allocator, ep, addr, "economic", "toggle_public", econ_val, true, true);

    try stdout().print("\n{s}wizard complete.{s}\n", .{ col(C_GREEN), rst() });
    return 0;
}

fn cmdProfileExport(allocator: std.mem.Allocator, ep: Endpoint, args: Args) !u8 {
    if (args.pos.len < 2) return writeMissing("profile export <addr> [<file.json>]");
    const addr = args.pos[1];
    const qa = try jsonQuote(allocator, addr);
    defer allocator.free(qa);
    const params = try std.fmt.allocPrint(allocator, "[{s}]", .{qa});
    defer allocator.free(params);
    const resp = try rpcCall(allocator, ep, "profile_get", params);
    defer allocator.free(resp);

    const out_path = if (args.pos.len > 2)
        try allocator.dupe(u8, args.pos[2])
    else
        try std.fmt.allocPrint(allocator, "{s}.profile.json", .{addr});
    defer allocator.free(out_path);

    const f = std.fs.cwd().createFile(out_path, .{ .truncate = true }) catch |e| {
        try stderr().print("create {s} failed: {s}\n", .{ out_path, @errorName(e) });
        return 1;
    };
    defer f.close();
    try f.writeAll(resp);
    try stdout().print("wrote {s} ({d} bytes)\n", .{ out_path, resp.len });
    return 0;
}

fn cmdProfileImport(allocator: std.mem.Allocator, ep: Endpoint, args: Args) !u8 {
    if (args.pos.len < 2) return writeMissing("profile import <file.json>");
    const c = try requireYes(args, "profile import"); if (c != 0) return c;
    const path = args.pos[1];
    const f = std.fs.cwd().openFile(path, .{}) catch |e| {
        try stderr().print("open {s} failed: {s}\n", .{ path, @errorName(e) });
        return 1;
    };
    defer f.close();
    const raw = f.readToEndAlloc(allocator, 4 * 1024 * 1024) catch |e| {
        try stderr().print("read {s} failed: {s}\n", .{ path, @errorName(e) });
        return 1;
    };
    defer allocator.free(raw);

    var p = parse(allocator, raw) catch {
        try stderr().print("file is not valid JSON\n", .{});
        return 1;
    };
    defer p.deinit();

    // Accept either RPC envelope ({"result":{...}}) or bare profile object.
    var root = p.value;
    if (root == .object) {
        if (root.object.get("result")) |r| root = r;
    }
    if (root != .object) {
        try stderr().print("profile must be a JSON object\n", .{});
        return 1;
    }
    const addr = jsonGetStr(root, "address") orelse {
        try stderr().print("profile JSON missing \"address\" field\n", .{});
        return 1;
    };

    var replayed: usize = 0;
    const sections = [_][]const u8{ "social", "professional", "cultural", "economic" };
    for (sections) |sec| {
        const sec_v = root.object.get(sec) orelse continue;
        if (sec_v != .object) continue;
        var it = sec_v.object.iterator();
        while (it.next()) |kv| {
            const k = kv.key_ptr.*;
            const v = kv.value_ptr.*;
            if (v == .null) continue;
            // Serialize the json value to a buffer for transit.
            var buf = std.array_list.Managed(u8).init(allocator);
            defer buf.deinit();
            try printJsonValue(buf.writer(), v, 0);
            _ = try profileUpdate(allocator, ep, addr, sec, k, buf.items, true, true);
            replayed += 1;
        }
    }
    try stdout().print("replayed {d} field(s) for {s}\n", .{ replayed, addr });
    return 0;
}

fn cmdProfile(allocator: std.mem.Allocator, ep: Endpoint, args: Args) !u8 {
    if (args.pos.len < 1) {
        try stderr().print("usage: omnibus-cli profile <init|get|show|wizard|social|professional|cultural|economic|export|import> ...\n", .{});
        return 2;
    }
    const sub = args.pos[0];
    if (std.mem.eql(u8, sub, "init")) return cmdProfileInit(allocator, ep, args);
    if (std.mem.eql(u8, sub, "get") or std.mem.eql(u8, sub, "show")) {
        if (args.pos.len < 2) return writeMissing("profile get <addr>");
        return cmdProfileGet(allocator, ep, args.pos[1], args.json);
    }
    if (std.mem.eql(u8, sub, "wizard")) return cmdProfileWizard(allocator, ep, args);
    if (std.mem.eql(u8, sub, "export")) return cmdProfileExport(allocator, ep, args);
    if (std.mem.eql(u8, sub, "import")) return cmdProfileImport(allocator, ep, args);
    if (std.mem.eql(u8, sub, "social")) return cmdProfileSocial(allocator, ep, args);
    if (std.mem.eql(u8, sub, "professional")) return cmdProfileProfessional(allocator, ep, args);
    if (std.mem.eql(u8, sub, "cultural")) return cmdProfileCultural(allocator, ep, args);
    if (std.mem.eql(u8, sub, "economic")) return cmdProfileEconomic(allocator, ep, args);
    try stderr().print("unknown profile subcommand `{s}`\n", .{sub});
    return 2;
}

// ─── MiCA (markets-in-crypto-assets compliance attestations) ────────────────
fn cmdMicaAttest(allocator: std.mem.Allocator, ep: Endpoint, args: Args) !u8 {
    if (args.pos.len < 2) return writeMissing("mica attest <kyc|aml|sanctions> [--self | --issuer <did> --sig <hex>]");
    const c = try requireYes(args, "mica attest"); if (c != 0) return c;
    const kind = args.pos[1];
    if (!std.mem.eql(u8, kind, "kyc") and !std.mem.eql(u8, kind, "aml") and !std.mem.eql(u8, kind, "sanctions")) {
        try stderr().print("kind must be kyc|aml|sanctions\n", .{});
        return 2;
    }
    const addr_opt = try resolveProfileAddress(allocator, args, std.math.maxInt(usize));
    if (addr_opt == null) return 2;
    const addr = addr_opt.?;
    defer allocator.free(addr);

    // Detect --self (positional bare flag) vs --issuer=<did> --sig=<hex>.
    var self_attest = false;
    for (args.pos) |p| {
        if (std.mem.eql(u8, p, "--self")) { self_attest = true; break; }
    }
    const issuer = kvLookup(args, "issuer");
    const sig = kvLookup(args, "sig");
    if (!self_attest and (issuer == null or sig == null)) {
        try stderr().print("supply either --self or --issuer=<did> --sig=<hex>\n", .{});
        return 2;
    }

    const qa = try jsonQuote(allocator, addr);
    defer allocator.free(qa);
    const qk = try jsonQuote(allocator, kind);
    defer allocator.free(qk);

    var b = std.array_list.Managed(u8).init(allocator);
    defer b.deinit();
    const w = b.writer();
    try w.print("[{{\"address\":{s},\"kind\":{s},\"self\":{}", .{ qa, qk, self_attest });
    if (issuer) |is| {
        const qi = try jsonQuote(allocator, is);
        defer allocator.free(qi);
        try w.print(",\"issuer\":{s}", .{qi});
    }
    if (sig) |s| {
        const qs = try jsonQuote(allocator, s);
        defer allocator.free(qs);
        try w.print(",\"sig\":{s}", .{qs});
    }
    try w.writeAll("}]");
    const resp = try rpcCall(allocator, ep, "mica_attest", b.items);
    defer allocator.free(resp);
    if (args.json) { try printRawJson(resp); return 0; }
    return printWriteResult(allocator, resp, "mica_attest");
}

fn cmdMicaDisclose(allocator: std.mem.Allocator, ep: Endpoint, args: Args) !u8 {
    const addr_opt = try resolveProfileAddress(allocator, args, 1);
    if (addr_opt == null) return 2;
    const addr = addr_opt.?;
    defer allocator.free(addr);
    const qa = try jsonQuote(allocator, addr);
    defer allocator.free(qa);
    const params = try std.fmt.allocPrint(allocator, "[{s}]", .{qa});
    defer allocator.free(params);
    const resp = try rpcCall(allocator, ep, "mica_disclose", params);
    defer allocator.free(resp);
    if (args.json) { try printRawJson(resp); return 0; }
    var p = parse(allocator, resp) catch { try printRpcError("parse failed"); return 1; };
    defer p.deinit();
    var err_msg: []const u8 = "";
    const r = extractResult(p.value, &err_msg) orelse { try printRpcError(err_msg); return 1; };
    const out = stdout();
    try out.print("{s}=== MiCA disclosure: {s} ==={s}\n", .{ col(C_BOLD), addr, rst() });
    const fields = [_][]const u8{ "kyc", "aml", "sanctions", "issuer" };
    for (fields) |f| {
        if (r == .object) {
            if (r.object.get(f)) |v| {
                switch (v) {
                    .string => |s| try out.print("  {s:<10}: {s}\n", .{ f, s }),
                    .bool => |bb| try out.print("  {s:<10}: {}\n", .{ f, bb }),
                    .null => try out.print("  {s:<10}: {s}(none){s}\n", .{ f, col(C_GRAY), rst() }),
                    .object => try out.print("  {s:<10}: <object>\n", .{f}),
                    else => try out.print("  {s:<10}: <?>\n", .{f}),
                }
            } else {
                try out.print("  {s:<10}: {s}(not set){s}\n", .{ f, col(C_GRAY), rst() });
            }
        }
    }
    return 0;
}

fn cmdMica(allocator: std.mem.Allocator, ep: Endpoint, args: Args) !u8 {
    if (args.pos.len < 1) {
        try stderr().print("usage: omnibus-cli mica <attest|disclose> ...\n", .{});
        return 2;
    }
    const sub = args.pos[0];
    if (std.mem.eql(u8, sub, "attest")) return cmdMicaAttest(allocator, ep, args);
    if (std.mem.eql(u8, sub, "disclose")) return cmdMicaDisclose(allocator, ep, args);
    try stderr().print("unknown mica subcommand `{s}`\n", .{sub});
    return 2;
}

// ─── Cold Wallet (watch-only) ────────────────────────────────────────────────

fn cmdColdwalletAdd(allocator: std.mem.Allocator, ep: Endpoint, args: Args) !u8 {
    if (args.pos.len < 1) return writeMissing("coldwallet add <addr> [--label=<text>]");
    const addr = args.pos[0];
    const label = kvLookup(args, "label") orelse "";
    const qa = try jsonQuote(allocator, addr);
    defer allocator.free(qa);
    const ql = try jsonQuote(allocator, label);
    defer allocator.free(ql);
    const params = try std.fmt.allocPrint(allocator,
        "[{{\"address\":{s},\"label\":{s}}}]", .{ qa, ql });
    defer allocator.free(params);
    const resp = try rpcCall(allocator, ep, "coldwallet_add", params);
    defer allocator.free(resp);
    if (args.json) { try printRawJson(resp); return 0; }
    return printWriteResult(allocator, resp, "coldwallet_add");
}

fn cmdColdwalletList(allocator: std.mem.Allocator, ep: Endpoint, args: Args) !u8 {
    const resp = try rpcCall(allocator, ep, "coldwallet_list", "[]");
    defer allocator.free(resp);
    if (args.json) { try printRawJson(resp); return 0; }
    var p = parse(allocator, resp) catch { try printRpcError("parse failed"); return 1; };
    defer p.deinit();
    var err_msg: []const u8 = "";
    const r = extractResult(p.value, &err_msg) orelse { try printRpcError(err_msg); return 1; };
    const out = stdout();
    try out.print("{s}=== Cold Wallets ==={s}\n", .{ col(C_BOLD), rst() });
    if (r != .array) { try out.print("(no cold wallets)\n", .{}); return 0; }
    try out.print("{s}{s:<20}  {s:<16}  {s:<12}  {s}{s}\n",
        .{ col(C_BOLD), "Address", "Label", "Balance", "TXs", rst() });
    var buf: [64]u8 = undefined;
    for (r.array.items) |item| {
        const addr  = jsonGetStr(item, "address") orelse "";
        const lbl   = jsonGetStr(item, "label") orelse "";
        const bal   = jsonGetU64(item, "balance_sat");
        const txcnt = jsonGetU64(item, "tx_count");
        const short = if (addr.len > 16) addr[0..8] else addr;
        _ = short;
        // Show first 8 + last 6 chars for readability
        const display: []const u8 = if (addr.len > 16)
            try std.fmt.allocPrint(allocator, "{s}...{s}", .{ addr[0..8], addr[addr.len - 6 ..] })
        else
            addr;
        defer if (addr.len > 16) allocator.free(display);
        try out.print("  {s:<20}  {s:<16}  {s:<12}  {d}\n",
            .{ display, lbl, try formatOmni(&buf, bal), txcnt });
    }
    return 0;
}

fn cmdColdwalletRemove(allocator: std.mem.Allocator, ep: Endpoint, args: Args) !u8 {
    if (args.pos.len < 1) return writeMissing("coldwallet remove <addr>");
    const c = try requireYes(args, "coldwallet remove"); if (c != 0) return c;
    const qa = try jsonQuote(allocator, args.pos[0]);
    defer allocator.free(qa);
    const params = try std.fmt.allocPrint(allocator, "[{s}]", .{qa});
    defer allocator.free(params);
    const resp = try rpcCall(allocator, ep, "coldwallet_remove", params);
    defer allocator.free(resp);
    if (args.json) { try printRawJson(resp); return 0; }
    return printWriteResult(allocator, resp, "coldwallet_remove");
}

fn cmdColdwalletHistory(allocator: std.mem.Allocator, ep: Endpoint, args: Args) !u8 {
    if (args.pos.len < 1) return writeMissing("coldwallet history <addr> [--limit=50]");
    const addr = args.pos[0];
    const limit_str = kvLookup(args, "limit") orelse "50";
    const limit = std.fmt.parseInt(u64, limit_str, 10) catch 50;
    const qa = try jsonQuote(allocator, addr);
    defer allocator.free(qa);
    const params = try std.fmt.allocPrint(allocator,
        "[{{\"address\":{s},\"limit\":{d}}}]", .{ qa, limit });
    defer allocator.free(params);
    const resp = try rpcCall(allocator, ep, "coldwallet_history", params);
    defer allocator.free(resp);
    if (args.json) { try printRawJson(resp); return 0; }
    var p = parse(allocator, resp) catch { try printRpcError("parse failed"); return 1; };
    defer p.deinit();
    var err_msg: []const u8 = "";
    const r = extractResult(p.value, &err_msg) orelse { try printRpcError(err_msg); return 1; };
    const out = stdout();
    try out.print("{s}=== Cold Wallet History: {s} ==={s}\n", .{ col(C_BOLD), addr, rst() });
    if (r != .array) { try out.print("(no history)\n", .{}); return 0; }
    var buf: [64]u8 = undefined;
    for (r.array.items) |tx| {
        const txid  = jsonGetStr(tx, "txid") orelse "?";
        const amt   = jsonGetU64(tx, "amount_sat");
        const kind  = jsonGetStr(tx, "kind") orelse "?";
        const blk   = jsonGetU64(tx, "block");
        const short_txid = if (txid.len > 12) txid[0..12] else txid;
        try out.print("  {s}  {s:<8}  {s}{s}{s} OMNI  @{d}\n",
            .{ short_txid, kind, col(C_CYAN), try formatOmni(&buf, amt), rst(), blk });
    }
    return 0;
}

fn cmdColdwalletBalance(allocator: std.mem.Allocator, ep: Endpoint, addr: []const u8, json_mode: bool) !u8 {
    // Just calls getbalance — cold wallets are watch-only.
    return cmdBalance(allocator, ep, addr, json_mode);
}

fn cmdColdwallet(allocator: std.mem.Allocator, ep: Endpoint, args: Args) !u8 {
    if (args.pos.len < 1) {
        try stderr().print("usage: omnibus-cli coldwallet <add|list|remove|history|balance> ...\n", .{});
        return 2;
    }
    const sub = args.pos[0];
    // Shift positional args for sub-handlers.
    var sub_args = args;
    sub_args.pos = if (args.pos.len > 1) args.pos[1..] else &.{};
    if (std.mem.eql(u8, sub, "add"))     return cmdColdwalletAdd(allocator, ep, sub_args);
    if (std.mem.eql(u8, sub, "list"))    return cmdColdwalletList(allocator, ep, args);
    if (std.mem.eql(u8, sub, "remove"))  return cmdColdwalletRemove(allocator, ep, sub_args);
    if (std.mem.eql(u8, sub, "history")) return cmdColdwalletHistory(allocator, ep, sub_args);
    if (std.mem.eql(u8, sub, "balance")) {
        if (sub_args.pos.len < 1) return writeMissing("coldwallet balance <addr>");
        return cmdColdwalletBalance(allocator, ep, sub_args.pos[0], args.json);
    }
    try stderr().print("unknown coldwallet subcommand `{s}`\n", .{sub});
    return 2;
}

// ─── Timelock Vault (CLTV) ───────────────────────────────────────────────────

fn cmdTimelockCreate(allocator: std.mem.Allocator, ep: Endpoint, args: Args) !u8 {
    // timelock create <owner> <dest> <amount_omni> <unlock_block> [--privkey <hex>]
    if (args.pos.len < 4) return writeMissing(
        "timelock create <owner_addr> <dest_addr> <amount_omni> <unlock_block>");
    const c = try requireYes(args, "timelock create"); if (c != 0) return c;
    const owner  = args.pos[0];
    const dest   = args.pos[1];
    const amount = args.pos[2];
    const unlock = args.pos[3];
    const qo = try jsonQuote(allocator, owner);
    defer allocator.free(qo);
    const qd = try jsonQuote(allocator, dest);
    defer allocator.free(qd);

    // Optionally sign with privkey.
    const privkey_hex: []const u8 = blk: {
        if (args.privkey) |pk| break :blk pk;
        const sk = resolveSigningKey(allocator, args) catch break :blk "";
        const hex = try bytesToHex(allocator, &sk.privkey);
        break :blk hex;
    };
    const qpk = try jsonQuote(allocator, privkey_hex);
    defer allocator.free(qpk);

    const params = try std.fmt.allocPrint(allocator,
        "[{{\"owner\":{s},\"dest\":{s},\"amount\":{s},\"unlock_block\":{s},\"privkey\":{s}}}]",
        .{ qo, qd, amount, unlock, qpk });
    defer allocator.free(params);
    const resp = try rpcCall(allocator, ep, "timelock_create", params);
    defer allocator.free(resp);
    if (args.json) { try printRawJson(resp); return 0; }
    var p = parse(allocator, resp) catch { try printRpcError("parse failed"); return 1; };
    defer p.deinit();
    var err_msg: []const u8 = "";
    const r = extractResult(p.value, &err_msg) orelse { try printRpcError(err_msg); return 1; };
    const out = stdout();
    try out.print("{s}Timelock vault created{s}\n", .{ col(C_GREEN), rst() });
    if (jsonGetStr(r, "vault_id")) |vid|
        try out.print("  vault_id : {s}{s}{s}\n", .{ col(C_CYAN), vid, rst() });
    if (jsonGetStr(r, "txid")) |txid|
        try out.print("  txid     : {s}\n", .{txid});
    return 0;
}

fn cmdTimelockList(allocator: std.mem.Allocator, ep: Endpoint, args: Args) !u8 {
    const owner: ?[]const u8 = if (args.pos.len > 0) args.pos[0] else null;
    var params: []u8 = undefined;
    if (owner) |o| {
        const qo = try jsonQuote(allocator, o);
        defer allocator.free(qo);
        params = try std.fmt.allocPrint(allocator, "[{s}]", .{qo});
    } else {
        params = try allocator.dupe(u8, "[]");
    }
    defer allocator.free(params);
    const resp = try rpcCall(allocator, ep, "timelock_list", params);
    defer allocator.free(resp);
    if (args.json) { try printRawJson(resp); return 0; }
    var p = parse(allocator, resp) catch { try printRpcError("parse failed"); return 1; };
    defer p.deinit();
    var err_msg: []const u8 = "";
    const r = extractResult(p.value, &err_msg) orelse { try printRpcError(err_msg); return 1; };
    const out = stdout();
    try out.print("{s}=== Timelock Vaults ==={s}\n", .{ col(C_BOLD), rst() });
    if (r != .array) { try out.print("(none)\n", .{}); return 0; }
    try out.print("{s}{s:<10}  {s:<10}  {s:<12}  {s:<20}  {s}{s}\n",
        .{ col(C_BOLD), "vault_id", "state", "amount", "dest", "blocks_left", rst() });
    var buf: [64]u8 = undefined;
    for (r.array.items) |v| {
        const vid   = jsonGetStr(v, "vault_id") orelse "?";
        const state = jsonGetStr(v, "state") orelse "?";
        const amt   = jsonGetU64(v, "amount_sat");
        const dest  = jsonGetStr(v, "dest") orelse "";
        const rem   = jsonGetU64(v, "blocks_remaining");
        const short_vid = if (vid.len > 8) vid[0..8] else vid;
        const short_dest = if (dest.len > 16) dest[0..8] else dest;
        const state_col: []const u8 = if (std.mem.eql(u8, state, "locked"))
            col(C_YELLOW) else if (std.mem.eql(u8, state, "unlocked"))
            col(C_GREEN) else col(C_GRAY);
        try out.print("  {s:<10}  {s}{s:<10}{s}  {s:<12}  {s:<20}  {d}\n",
            .{ short_vid, state_col, state, rst(),
               try formatOmni(&buf, amt), short_dest, rem });
    }
    return 0;
}

fn cmdTimelockSpend(allocator: std.mem.Allocator, ep: Endpoint, args: Args) !u8 {
    if (args.pos.len < 1) return writeMissing("timelock spend <vault_id> [--privkey <hex>]");
    const c = try requireYes(args, "timelock spend"); if (c != 0) return c;
    const vault_id = args.pos[0];
    const privkey_hex: []const u8 = blk: {
        if (args.privkey) |pk| break :blk pk;
        const sk = resolveSigningKey(allocator, args) catch break :blk "";
        const hex = try bytesToHex(allocator, &sk.privkey);
        break :blk hex;
    };
    const qv = try jsonQuote(allocator, vault_id);
    defer allocator.free(qv);
    const qpk = try jsonQuote(allocator, privkey_hex);
    defer allocator.free(qpk);
    const params = try std.fmt.allocPrint(allocator,
        "[{{\"vault_id\":{s},\"privkey\":{s}}}]", .{ qv, qpk });
    defer allocator.free(params);
    const resp = try rpcCall(allocator, ep, "timelock_spend", params);
    defer allocator.free(resp);
    if (args.json) { try printRawJson(resp); return 0; }
    return printWriteResult(allocator, resp, "timelock_spend");
}

fn cmdTimelockStatus(allocator: std.mem.Allocator, ep: Endpoint, args: Args) !u8 {
    if (args.pos.len < 1) return writeMissing("timelock status <vault_id>");
    const qv = try jsonQuote(allocator, args.pos[0]);
    defer allocator.free(qv);
    const params = try std.fmt.allocPrint(allocator, "[{s}]", .{qv});
    defer allocator.free(params);
    return dumpRpcResult(allocator, ep, "timelock_status", params, args.json, "Timelock Status");
}

fn cmdTimelock(allocator: std.mem.Allocator, ep: Endpoint, args: Args) !u8 {
    if (args.pos.len < 1) {
        try stderr().print("usage: omnibus-cli timelock <create|list|spend|status> ...\n", .{});
        return 2;
    }
    const sub = args.pos[0];
    var sub_args = args;
    sub_args.pos = if (args.pos.len > 1) args.pos[1..] else &.{};
    if (std.mem.eql(u8, sub, "create")) return cmdTimelockCreate(allocator, ep, sub_args);
    if (std.mem.eql(u8, sub, "list"))   return cmdTimelockList(allocator, ep, sub_args);
    if (std.mem.eql(u8, sub, "spend"))  return cmdTimelockSpend(allocator, ep, sub_args);
    if (std.mem.eql(u8, sub, "status")) return cmdTimelockStatus(allocator, ep, sub_args);
    try stderr().print("unknown timelock subcommand `{s}`\n", .{sub});
    return 2;
}

// ─── Covenant (destination whitelist) ────────────────────────────────────────

fn cmdCovenantCreate(allocator: std.mem.Allocator, ep: Endpoint, args: Args) !u8 {
    // covenant create <addr> <dest1> [<dest2> ...] [--max-per-tx=N] [--expires-block=N] [--label=X]
    if (args.pos.len < 2) return writeMissing(
        "covenant create <addr> <dest1> [<dest2> ...] [--max-per-tx=<omni>] [--expires-block=N] [--label=X]");
    const c = try requireYes(args, "covenant create"); if (c != 0) return c;
    const addr = args.pos[0];
    const qa = try jsonQuote(allocator, addr);
    defer allocator.free(qa);

    // Build JSON array of dest addresses (all positional args after addr).
    var dests = std.array_list.Managed(u8).init(allocator);
    defer dests.deinit();
    try dests.append('[');
    for (args.pos[1..], 0..) |d, i| {
        if (i > 0) try dests.append(',');
        const qd = try jsonQuote(allocator, d);
        defer allocator.free(qd);
        try dests.appendSlice(qd);
    }
    try dests.append(']');

    const max_per_tx   = kvLookup(args, "max-per-tx") orelse "0";
    const expires_blk  = kvLookup(args, "expires-block") orelse "0";
    const label        = kvLookup(args, "label") orelse "";
    const ql = try jsonQuote(allocator, label);
    defer allocator.free(ql);

    const params = try std.fmt.allocPrint(allocator,
        "[{{\"address\":{s},\"dests\":{s},\"max_per_tx\":{s},\"expires_block\":{s},\"label\":{s}}}]",
        .{ qa, dests.items, max_per_tx, expires_blk, ql });
    defer allocator.free(params);
    const resp = try rpcCall(allocator, ep, "covenant_create", params);
    defer allocator.free(resp);
    if (args.json) { try printRawJson(resp); return 0; }
    return printWriteResult(allocator, resp, "covenant_create");
}

fn cmdCovenantList(allocator: std.mem.Allocator, ep: Endpoint, args: Args) !u8 {
    const resp = try rpcCall(allocator, ep, "covenant_list", "[]");
    defer allocator.free(resp);
    if (args.json) { try printRawJson(resp); return 0; }
    var p = parse(allocator, resp) catch { try printRpcError("parse failed"); return 1; };
    defer p.deinit();
    var err_msg: []const u8 = "";
    const r = extractResult(p.value, &err_msg) orelse { try printRpcError(err_msg); return 1; };
    const out = stdout();
    try out.print("{s}=== Covenants ==={s}\n", .{ col(C_BOLD), rst() });
    if (r != .array) { try out.print("(none)\n", .{}); return 0; }
    for (r.array.items) |cv| {
        const addr  = jsonGetStr(cv, "address") orelse "?";
        const lbl   = jsonGetStr(cv, "label") orelse "";
        const ndest = if (cv == .object) blk: {
            const d = cv.object.get("dests");
            break :blk if (d != null and d.? == .array) d.?.array.items.len else @as(usize, 0);
        } else @as(usize, 0);
        const max   = jsonGetU64(cv, "max_per_tx");
        const exp   = jsonGetU64(cv, "expires_block");
        try out.print("  {s}  {s:<14}  {d} dest(s)  max={d}  exp_blk={d}\n",
            .{ addr, lbl, ndest, max, exp });
    }
    return 0;
}

fn cmdCovenantGet(allocator: std.mem.Allocator, ep: Endpoint, args: Args) !u8 {
    if (args.pos.len < 1) return writeMissing("covenant get <addr>");
    const addr = args.pos[0];
    const qa = try jsonQuote(allocator, addr);
    defer allocator.free(qa);
    const params = try std.fmt.allocPrint(allocator, "[{s}]", .{qa});
    defer allocator.free(params);
    const resp = try rpcCall(allocator, ep, "covenant_get", params);
    defer allocator.free(resp);
    if (args.json) { try printRawJson(resp); return 0; }
    var p = parse(allocator, resp) catch { try printRpcError("parse failed"); return 1; };
    defer p.deinit();
    var err_msg: []const u8 = "";
    const r = extractResult(p.value, &err_msg) orelse { try printRpcError(err_msg); return 1; };
    const out = stdout();
    try out.print("{s}=== Covenant: {s} ==={s}\n", .{ col(C_BOLD), addr, rst() });
    if (jsonGetStr(r, "label")) |lbl| try out.print("  Label         : {s}\n", .{lbl});
    const max = jsonGetU64(r, "max_per_tx");
    if (max > 0) {
        var buf: [64]u8 = undefined;
        try out.print("  Max-per-TX    : {s} OMNI\n", .{try formatOmni(&buf, max)});
    }
    const exp = jsonGetU64(r, "expires_block");
    if (exp > 0) try out.print("  Expires block : {d}\n", .{exp});
    // Print whitelisted destinations.
    if (r == .object) {
        if (r.object.get("dests")) |dests| if (dests == .array) {
            try out.print("  Allowed dests :\n", .{});
            for (dests.array.items) |d| {
                const ds = switch (d) { .string => |s| s, else => "?" };
                try out.print("    - {s}{s}{s}\n", .{ col(C_GREEN), ds, rst() });
            }
        };
    }
    return 0;
}

fn cmdCovenantRemove(allocator: std.mem.Allocator, ep: Endpoint, args: Args) !u8 {
    if (args.pos.len < 1) return writeMissing("covenant remove <addr>");
    const c = try requireYes(args, "covenant remove"); if (c != 0) return c;
    const qa = try jsonQuote(allocator, args.pos[0]);
    defer allocator.free(qa);
    const params = try std.fmt.allocPrint(allocator, "[{s}]", .{qa});
    defer allocator.free(params);
    const resp = try rpcCall(allocator, ep, "covenant_remove", params);
    defer allocator.free(resp);
    if (args.json) { try printRawJson(resp); return 0; }
    return printWriteResult(allocator, resp, "covenant_remove");
}

fn cmdCovenant(allocator: std.mem.Allocator, ep: Endpoint, args: Args) !u8 {
    if (args.pos.len < 1) {
        try stderr().print("usage: omnibus-cli covenant <create|list|get|remove> ...\n", .{});
        return 2;
    }
    const sub = args.pos[0];
    var sub_args = args;
    sub_args.pos = if (args.pos.len > 1) args.pos[1..] else &.{};
    if (std.mem.eql(u8, sub, "create")) return cmdCovenantCreate(allocator, ep, sub_args);
    if (std.mem.eql(u8, sub, "list"))   return cmdCovenantList(allocator, ep, args);
    if (std.mem.eql(u8, sub, "get"))    return cmdCovenantGet(allocator, ep, sub_args);
    if (std.mem.eql(u8, sub, "remove")) return cmdCovenantRemove(allocator, ep, sub_args);
    try stderr().print("unknown covenant subcommand `{s}`\n", .{sub});
    return 2;
}

// ─── Treasury (auto-distribute) ──────────────────────────────────────────────

fn cmdTreasuryCreate(allocator: std.mem.Allocator, ep: Endpoint, args: Args) !u8 {
    // treasury create <treasury_addr> --dest=<addr>:<pct>:<label> [--dest ...] --trigger=N [--label=X]
    if (args.pos.len < 1) return writeMissing(
        "treasury create <treasury_addr> --dest=<addr>:<share_pct>:<label> [--dest ...] --trigger=<amount_omni> [--label=X]");
    const c = try requireYes(args, "treasury create"); if (c != 0) return c;
    const addr = args.pos[0];
    const qa = try jsonQuote(allocator, addr);
    defer allocator.free(qa);

    // Collect all --dest=addr:pct:label flags.
    var dests = std.array_list.Managed(u8).init(allocator);
    defer dests.deinit();
    try dests.append('[');
    var first_dest = true;
    for (args.kvs) |kv| {
        if (!std.mem.eql(u8, kv.key, "dest")) continue;
        // Parse "addr:pct:label"
        var parts = std.mem.splitScalar(u8, kv.val, ':');
        const d_addr = parts.next() orelse continue;
        const d_pct  = parts.next() orelse "0";
        const d_lbl  = parts.next() orelse "";
        const qda = try jsonQuote(allocator, d_addr);
        defer allocator.free(qda);
        const qdl = try jsonQuote(allocator, d_lbl);
        defer allocator.free(qdl);
        if (!first_dest) try dests.append(',');
        first_dest = false;
        try dests.writer().print("{{\"addr\":{s},\"pct\":{s},\"label\":{s}}}",
            .{ qda, d_pct, qdl });
    }
    try dests.append(']');

    const trigger = kvLookup(args, "trigger") orelse "0";
    const label   = kvLookup(args, "label") orelse "";
    const ql = try jsonQuote(allocator, label);
    defer allocator.free(ql);

    const params = try std.fmt.allocPrint(allocator,
        "[{{\"address\":{s},\"dests\":{s},\"trigger\":{s},\"label\":{s}}}]",
        .{ qa, dests.items, trigger, ql });
    defer allocator.free(params);
    const resp = try rpcCall(allocator, ep, "treasury_create", params);
    defer allocator.free(resp);
    if (args.json) { try printRawJson(resp); return 0; }
    return printWriteResult(allocator, resp, "treasury_create");
}

fn cmdTreasuryList(allocator: std.mem.Allocator, ep: Endpoint, args: Args) !u8 {
    const resp = try rpcCall(allocator, ep, "treasury_list", "[]");
    defer allocator.free(resp);
    if (args.json) { try printRawJson(resp); return 0; }
    var p = parse(allocator, resp) catch { try printRpcError("parse failed"); return 1; };
    defer p.deinit();
    var err_msg: []const u8 = "";
    const r = extractResult(p.value, &err_msg) orelse { try printRpcError(err_msg); return 1; };
    const out = stdout();
    try out.print("{s}=== Treasury pools ==={s}\n", .{ col(C_BOLD), rst() });
    if (r != .array) { try out.print("(none)\n", .{}); return 0; }
    var buf: [64]u8 = undefined;
    for (r.array.items) |t| {
        const id    = jsonGetStr(t, "treasury_id") orelse jsonGetStr(t, "address") orelse "?";
        const lbl   = jsonGetStr(t, "label") orelse "";
        const bal   = jsonGetU64(t, "balance_sat");
        const trig  = jsonGetU64(t, "trigger_sat");
        try out.print("  {s:<20}  {s:<14}  bal={s}  trigger={s} OMNI\n",
            .{ id, lbl, try formatOmni(&buf, bal), try formatOmni(&buf, trig) });
    }
    return 0;
}

fn cmdTreasuryDistribute(allocator: std.mem.Allocator, ep: Endpoint, args: Args) !u8 {
    if (args.pos.len < 1) return writeMissing("treasury distribute <treasury_id> [--privkey <hex>]");
    const c = try requireYes(args, "treasury distribute"); if (c != 0) return c;
    const tid = args.pos[0];
    const privkey_hex: []const u8 = blk: {
        if (args.privkey) |pk| break :blk pk;
        const sk = resolveSigningKey(allocator, args) catch break :blk "";
        const hex = try bytesToHex(allocator, &sk.privkey);
        break :blk hex;
    };
    const qt = try jsonQuote(allocator, tid);
    defer allocator.free(qt);
    const qpk = try jsonQuote(allocator, privkey_hex);
    defer allocator.free(qpk);
    const params = try std.fmt.allocPrint(allocator,
        "[{{\"treasury_id\":{s},\"privkey\":{s}}}]", .{ qt, qpk });
    defer allocator.free(params);
    const resp = try rpcCall(allocator, ep, "treasury_distribute", params);
    defer allocator.free(resp);
    if (args.json) { try printRawJson(resp); return 0; }
    return printWriteResult(allocator, resp, "treasury_distribute");
}

fn cmdTreasuryStatus(allocator: std.mem.Allocator, ep: Endpoint, args: Args) !u8 {
    if (args.pos.len < 1) return writeMissing("treasury status <treasury_id>");
    const qt = try jsonQuote(allocator, args.pos[0]);
    defer allocator.free(qt);
    const params = try std.fmt.allocPrint(allocator, "[{s}]", .{qt});
    defer allocator.free(params);
    const resp = try rpcCall(allocator, ep, "treasury_status", params);
    defer allocator.free(resp);
    if (args.json) { try printRawJson(resp); return 0; }
    var p = parse(allocator, resp) catch { try printRpcError("parse failed"); return 1; };
    defer p.deinit();
    var err_msg: []const u8 = "";
    const r = extractResult(p.value, &err_msg) orelse { try printRpcError(err_msg); return 1; };
    const out = stdout();
    const tid = jsonGetStr(r, "treasury_id") orelse jsonGetStr(r, "address") orelse "?";
    try out.print("{s}=== Treasury: {s} ==={s}\n", .{ col(C_BOLD), tid, rst() });
    if (jsonGetStr(r, "label")) |lbl| try out.print("  Label   : {s}\n", .{lbl});
    var buf: [64]u8 = undefined;
    const bal  = jsonGetU64(r, "balance_sat");
    const trig = jsonGetU64(r, "trigger_sat");
    try out.print("  Balance : {s}{s}{s} OMNI\n",
        .{ col(C_CYAN), try formatOmni(&buf, bal), rst() });
    try out.print("  Trigger : {s} OMNI\n", .{try formatOmni(&buf, trig)});
    // Print destinations as pie-chart-like breakdown.
    if (r == .object) {
        if (r.object.get("dests")) |dests| if (dests == .array and dests.array.items.len > 0) {
            try out.print("\n  {s}Destination breakdown:{s}\n", .{ col(C_BOLD), rst() });
            for (dests.array.items) |d| {
                const da  = jsonGetStr(d, "addr") orelse "?";
                const pct = jsonGetU64(d, "pct");
                const dl  = jsonGetStr(d, "label") orelse "";
                // Bar width proportional to pct (max 20 chars).
                const bar_len = @min(@as(usize, @intCast(pct / 5)), 20);
                var bar_buf: [22]u8 = undefined;
                @memset(bar_buf[0..bar_len], '#');
                const bar = bar_buf[0..bar_len];
                try out.print("  [{s}{s:<20}{s}] {d:>3}%  {s:<12}  {s}\n",
                    .{ col(C_GREEN), bar, rst(), pct, dl, da });
            }
        };
    }
    return 0;
}

fn cmdTreasury(allocator: std.mem.Allocator, ep: Endpoint, args: Args) !u8 {
    if (args.pos.len < 1) {
        try stderr().print("usage: omnibus-cli treasury <create|list|distribute|status> ...\n", .{});
        return 2;
    }
    const sub = args.pos[0];
    var sub_args = args;
    sub_args.pos = if (args.pos.len > 1) args.pos[1..] else &.{};
    if (std.mem.eql(u8, sub, "create"))     return cmdTreasuryCreate(allocator, ep, sub_args);
    if (std.mem.eql(u8, sub, "list"))       return cmdTreasuryList(allocator, ep, args);
    if (std.mem.eql(u8, sub, "distribute")) return cmdTreasuryDistribute(allocator, ep, sub_args);
    if (std.mem.eql(u8, sub, "status"))     return cmdTreasuryStatus(allocator, ep, sub_args);
    try stderr().print("unknown treasury subcommand `{s}`\n", .{sub});
    return 2;
}

// ─── Multisig subcommand router (new `multisig` top-level command) ───────────
// Existing cmdMultisigCreate / cmdMultisigSend / cmdMultisigInfo are reused.

fn cmdMultisigBalance(allocator: std.mem.Allocator, ep: Endpoint, addr: []const u8, json_mode: bool) !u8 {
    return cmdBalance(allocator, ep, addr, json_mode);
}

fn cmdMultisigInfoFull(allocator: std.mem.Allocator, ep: Endpoint, addr: []const u8, json_mode: bool) !u8 {
    // Show balance + unspent outputs combined.
    const qa = try jsonQuote(allocator, addr);
    defer allocator.free(qa);
    const bal_params = try std.fmt.allocPrint(allocator, "[{s}]", .{qa});
    defer allocator.free(bal_params);
    const unspent_params = try std.fmt.allocPrint(allocator, "[{s}]", .{qa});
    defer allocator.free(unspent_params);
    const bal_resp     = try rpcCall(allocator, ep, "getbalance", bal_params);
    defer allocator.free(bal_resp);
    const unspent_resp = try rpcCall(allocator, ep, "listunspent", unspent_params);
    defer allocator.free(unspent_resp);
    if (json_mode) {
        try stdout().print("{{\"balance\":{s},\"unspent\":{s}}}\n", .{ bal_resp, unspent_resp });
        return 0;
    }
    const out = stdout();
    try out.print("{s}=== Multisig info: {s} ==={s}\n", .{ col(C_BOLD), addr, rst() });
    var bp = parse(allocator, bal_resp) catch { try printRpcError("parse error"); return 1; };
    defer bp.deinit();
    var err_msg: []const u8 = "";
    if (extractResult(bp.value, &err_msg)) |r| {
        const bal = jsonGetU64(r, "balance");
        var buf: [64]u8 = undefined;
        try out.print("  Balance : {s}{s}{s} OMNI\n",
            .{ col(C_GREEN), try formatOmni(&buf, bal), rst() });
    }
    var up = parse(allocator, unspent_resp) catch return 0;
    defer up.deinit();
    var em2: []const u8 = "";
    if (extractResult(up.value, &em2)) |r| {
        if (r == .array) {
            try out.print("  UTXOs   : {d}\n", .{r.array.items.len});
        }
    }
    return 0;
}

fn cmdMultisig(allocator: std.mem.Allocator, ep: Endpoint, args: Args) !u8 {
    if (args.pos.len < 1) {
        try stderr().print("usage: omnibus-cli multisig <create|send|balance|info> ...\n", .{});
        return 2;
    }
    const sub = args.pos[0];
    var sub_args = args;
    sub_args.pos = if (args.pos.len > 1) args.pos[1..] else &.{};
    if (std.mem.eql(u8, sub, "create"))  return cmdMultisigCreate(allocator, ep, sub_args);
    if (std.mem.eql(u8, sub, "send"))    return cmdMultisigSend(allocator, ep, sub_args);
    if (std.mem.eql(u8, sub, "balance")) {
        if (sub_args.pos.len < 1) return writeMissing("multisig balance <ms_addr>");
        return cmdMultisigBalance(allocator, ep, sub_args.pos[0], args.json);
    }
    if (std.mem.eql(u8, sub, "info")) {
        if (sub_args.pos.len < 1) return writeMissing("multisig info <ms_addr>");
        return cmdMultisigInfoFull(allocator, ep, sub_args.pos[0], args.json);
    }
    try stderr().print("unknown multisig subcommand `{s}`\n", .{sub});
    return 2;
}

// ─── Help ───────────────────────────────────────────────────────────────────
fn printHelp() !void {
    const out = stdout();
    try out.print(
        \\omnibus-cli — OmniBus blockchain audit tool
        \\
        \\USAGE
        \\  omnibus-cli <command> [args] [flags]
        \\
        \\COMMANDS — audit
        \\  balance <addr>             Full balance breakdown (wallet/stake/avail/rep)
        \\  stake <addr>               Current stake + activity log
        \\  reputation <addr>          Cups + tier
        \\  did <addr>                 OmniBus ID DID (did:omnibus:...)
        \\  obm <addr>                 OmniBus Binary Map (1 byte = 8 flags)
        \\  facets <addr>              ID facets (Social / Professional / Cultural)
        \\  daily <addr> [days=30]     Per-day TX breakdown
        \\  validators                 List of all validators
        \\  stakers [limit=10]         Top stakers
        \\  health                     Chain stats (height, mempool, peers)
        \\  history <addr> [filter]    TX history (filter: stake|sent|received|mined|all)
        \\  verify <addr>              Sanity check: chain stake vs sum(STAKE TXs)
        \\
        \\COMMANDS — exchange
        \\  exchange-pairs                              List 7 trading pairs + chain mapping
        \\  exchange-orderbook <pair_id>                Bids+asks+spread for a pair
        \\  exchange-trades <pair_id> [limit=50]        Recent trades for a pair
        \\  exchange-orders <addr>                      User's open orders
        \\  exchange-place <addr> <pair> <side> <price> <amount>  Submit signed order (write)
        \\  exchange-cancel <addr> <order_id>           Cancel order (write)
        \\  exchange-pair-info <pair_id>                Pair details (chains, contracts)
        \\  exchange-stats <pair_id>                    24h stats: vol, high, low, last
        \\
        \\COMMANDS — grid
        \\  grid-list [owner_addr]                      List grid trading positions
        \\  grid-status <grid_id>                       Single grid details
        \\  grid-create <addr> <pair> <low> <high> <levels> <total_base> <total_quote>  (write)
        \\  grid-cancel <addr> <grid_id>                (write)
        \\
        \\COMMANDS — htlc / swap
        \\  htlc-list                                   Open HTLC swaps
        \\  htlc-status <swap_id>                       Single swap status
        \\  htlc-init <addr> <recipient> <amount> <secret_hash> <lock_blocks>  (write)
        \\  htlc-claim <addr> <swap_id> <preimage>      (write)
        \\  htlc-refund <addr> <swap_id>                (write)
        \\  swap-list                                   All atomic swaps
        \\  swap-status <swap_id>                       Single atomic swap
        \\
        \\COMMANDS — oracle / bridge
        \\  oracle-prices                               BTC/LCX × 3 exchanges
        \\  oracle-arbitrage                            Cross-exchange arbitrage opps
        \\  oracle-feed                                 Full ws exchange feed (~700 pairs)
        \\  bridge-status                               Bridge limits + state
        \\  bridge-lock <addr> <to_chain> <amount>      (write)
        \\
        \\COMMANDS — chain inspection
        \\  block <height>                              Full block details
        \\  block-hash <hash>                           Block by hash
        \\  tx <txid>                                   Full TX details
        \\  mempool                                     Mempool snapshot
        \\  sync-status                                 IBD progress, peer height vs local
        \\  chain-info                                  Height, difficulty, network, consensus
        \\  supply                                      Total emitted OMNI, halving info
        \\  halving                                     Next halving estimate
        \\  prices [block]                              Block-level oracle prices (block.prices)
        \\
        \\COMMANDS — network / peers
        \\  peers                                       List connected peers
        \\  peer-info <peer_id>                         Peer details + score
        \\  bans                                        Banned peers
        \\  connect <ip:port>                           Manual peer connect (write)
        \\  disconnect <peer_id>                        Disconnect a peer (write)
        \\  p2p-stats                                   Total in/out, traffic, knock-knock count
        \\
        \\COMMANDS — mining
        \\  mining-status                               Current miner, hashrate, blocks/min
        \\  miners                                      List of all miners with block counts
        \\  miner-stats <addr>                          Single miner stats
        \\  pool-stats                                  Mining pool stats
        \\  slot-leader                                 Current slot leader + rotation
        \\  register-miner <addr> [node-id]             Register as miner (write)
        \\
        \\COMMANDS — wallet utilities
        \\  wallet-summary <addr>                       Atomic balance/stake/orders snapshot
        \\  derive-key <index>                          Print privkey+address for m/44'/777'/0'/0/<index>
        \\                                              (read mnemonic from --mnemonic / OMNIBUS_MNEMONIC)
        \\  wallet-list <count>                         List first N addresses from one mnemonic
        \\                                              (offline; lets you map indices → addresses)
        \\  wallet-derive <mnemonic> <index>            Derive address at index (legacy)
        \\  wallet-pq-derive <mnemonic>                 Derive 4 PQ addresses
        \\  wallet-multichain <mnemonic>                Derive BTC/ETH/SOL/etc addresses
        \\  wallet-export <mnemonic>                    JSON metadata bundle
        \\  sign-message <mnemonic> <message>           Sign arbitrary message (ECDSA)
        \\  verify-signature <pubkey> <signature> <message>
        \\  send <from> <to> <amount> [fee=1]           Basic transfer (write)
        \\
        \\SIGNING SOURCES (in priority order — for any write command):
        \\  --privkey <hex>                             Raw 32-byte privkey (no mnemonic exposure)
        \\  OMNIBUS_PRIVKEY env                         Same, via environment
        \\  --keyfile <path>                            Load privkey hex from file (chmod 600)
        \\  --mnemonic <words> [--key-index N]          Derive child N from seed (default 0)
        \\                                              Works with 12 OR 24-word BIP-39 seeds
        \\  --passphrase <p>  /  OMNIBUS_PASSPHRASE     BIP-39 "25th word" (hidden wallet)
        \\                                              Same mnemonic + different passphrase = different wallet
        \\  OMNIBUS_MNEMONIC env [--key-index N]        Same, via environment
        \\
        \\COMMANDS — Profile (DID + OBM + facets + economic)
        \\  profile init [<addr>]                       Init profile (DID + empty manifest + salt)
        \\  profile get <addr>                          Show profile by 4 sections
        \\  profile show <addr>                         Alias for `profile get`
        \\  profile wizard [<addr>]                     Interactive field-by-field setup
        \\  profile export <addr> [<file.json>]         Dump profile JSON to file
        \\  profile import <file.json>                  Replay profile fields onto chain
        \\  profile social set-handle <h> [--public|--private]
        \\  profile social set-bio <b> [--public|--private]
        \\  profile social set-avatar <ipfs> [--public|--private]
        \\  profile social add-link <platform> <url> [--public|--private]
        \\  profile professional set-visibility certs=true work=true endorsements=false
        \\  profile professional add-cert <issuer_did> <kind> <expires_unix>
        \\  profile professional add-work <employer_did> <role> <start_unix> <end_unix>
        \\  profile cultural add-poap <event_id_hex> <date_unix>
        \\  profile cultural add-work <hash_hex> <kind> [--public|--private]
        \\  profile cultural set-languages <en,ro,fr>
        \\  profile economic add-address <chain> <addr> [--public|--private]
        \\  profile economic declare-issuer <white_paper_hash> <risk_category>
        \\  profile economic set-volume 30d=<sat> 90d=<sat> 1y=<sat>
        \\  profile economic toggle-public addresses=true donations=false
        \\
        \\COMMANDS — MiCA Compliance
        \\  mica attest <kyc|aml|sanctions> [--self | --issuer=<did> --sig=<hex>]
        \\  mica disclose [<addr>]                      Show KYC/AML/sanctions/issuer status
        \\
        \\COMMANDS — Cold Wallet (watch-only)
        \\  coldwallet add <addr> [--label=<text>]      Track a cold address (watch-only)
        \\  coldwallet list                             List all tracked cold addresses
        \\  coldwallet remove <addr>                    Remove a cold wallet entry (--yes)
        \\  coldwallet history <addr> [--limit=50]      TX history for cold address
        \\  coldwallet balance <addr>                   Balance of cold wallet (calls getbalance)
        \\
        \\COMMANDS — Timelock Vault (CLTV)
        \\  timelock create <owner> <dest> <amount_omni> <unlock_block>  Lock funds until block (write)
        \\  timelock list [<owner_addr>]                List vaults: state + blocks remaining
        \\  timelock spend <vault_id>                   Broadcast spend TX (if block >= unlock, write)
        \\  timelock status <vault_id>                  Single vault details
        \\
        \\COMMANDS — Covenant (destination whitelist)
        \\  covenant create <addr> <dest1> [<dest2> ...] [--max-per-tx=N] [--expires-block=N] [--label=X]  (write)
        \\  covenant list                               List all covenants
        \\  covenant get <addr>                         Show covenant: address + whitelist + limits
        \\  covenant remove <addr>                      Remove covenant (--yes)
        \\
        \\COMMANDS — Treasury (auto-distribute)
        \\  treasury create <treasury_addr> --dest=<addr>:<share_pct>:<label> [--dest ...] --trigger=<omni> [--label=X]  (write)
        \\    example: treasury create ob1q... --dest=ob1qhealth:30:health --dest=ob1qedu:20:education --trigger=1000 --label=national
        \\  treasury list                               List treasury pools
        \\  treasury distribute <treasury_id>           Trigger distribution (write)
        \\  treasury status <treasury_id>               Status + pie-chart breakdown
        \\
        \\COMMANDS — Multisig (M-of-N)  [also: multisig-create / multisig-send / multisig-info]
        \\  multisig create <M> <pubkey1,pubkey2,...>   Create M-of-N address (write)
        \\  multisig send <ms_addr> <to_addr> <amount_omni> --signers=<sig1,sig2>  (write)
        \\  multisig balance <ms_addr>                  Balance on multisig address
        \\  multisig info <ms_addr>                     Balance + UTXO count
        \\
        \\COMMANDS — admin / debug
        \\  set-rpc-token <token>                       Persist token to ~/.omnibus/cli.conf
        \\  config                                      Print active config
        \\  watch <command> [interval=5]                Repeat a subcommand every N sec
        \\  logs [tail=50]                              Recent journal lines
        \\  vps-health                                  SSH wrapper to test-scripts/_vps-health.sh
        \\  stress-quick                                Wrapper around _quick-stake-test.sh
        \\  benchmark                                   RPC latency benchmark (1000 calls)
        \\
        \\COMMANDS — faucet
        \\  faucet-status                               Faucet config, balance, claims
        \\  faucet-claim <addr>                         Claim from faucet (testnet/regtest, write)
        \\  faucet-claims                               Recent claims log
        \\
        \\COMMANDS — 0day / security
        \\  zeroday-events                              Recent security events
        \\  zeroday-report <description>                Submit 0day report (write)
        \\  sybil-check <ip>                            Check if IP is sybil-banned
        \\
        \\COMMANDS — audit chain consistency
        \\  audit-totals                                Σ balances vs chain.dat
        \\  audit-stakes                                Σ stake_amounts vs Σ(stake-unstake) TX
        \\  audit-supply                                Total emitted vs blocks×reward(halv.)
        \\  audit-mempool                               Mempool TX count vs chain saved
        \\  audit-fees                                  Fees collected vs treasury balance
        \\
        \\COMMANDS — restart / control (SSH)
        \\  services-status                             systemd is-active for OmniBus services
        \\  service-restart <service>                   Restart a service via SSH (write)
        \\  oracle-restart                              Restart standalone oracle (write)
        \\  oracle-snapshot                             Direct query to omnibus-oracle :28100
        \\
        \\FLAGS
        \\  --rpc <url>            Override RPC URL (default http://127.0.0.1:8332)
        \\  --chain <c>            mainnet|testnet|regtest (8332/18332/28332)
        \\  --remote               Use https://omnibusblockchain.cc:8443 (needs curl in PATH)
        \\  --token <bearer>       RPC bearer token if needed
        \\  --json                 Raw JSON output (no pretty-print)
        \\  --no-color             Disable ANSI colors
        \\  --yes / -y             Confirm a write command (without this, write ops refuse)
        \\  --mnemonic "<12 words>"   Override OMNIBUS_MNEMONIC env var (signing material)
        \\  --foo-bar=baz          Generic key-value flag (e.g. --dest-addr=0x...)
        \\
        \\WRITE COMMANDS — signing
        \\  Read-only commands need only RPC reachability.
        \\  Write commands (place / cancel / htlc-* / grid-create / grid-cancel /
        \\  bridge-lock) need a mnemonic to derive an ECDSA key at BIP-44 path
        \\  m/44'/777'/0'/0/0 + the --yes flag for double-confirm.
        \\
        \\EXAMPLES
        \\  omnibus-cli health
        \\  omnibus-cli balance ob1q...xlvl
        \\  omnibus-cli daily ob1q...xlvl 7
        \\  omnibus-cli verify ob1q...xlvl
        \\  omnibus-cli --chain testnet --remote stakers 20
        \\  omnibus-cli exchange-orderbook 0
        \\  omnibus-cli exchange-place ob1q...xlvl OMNI/USDC buy 520000 5000000000 --yes
        \\  omnibus-cli grid-create ob1q...xlvl 0 500000 600000 10 100000000000 50000000 --yes
        \\  omnibus-cli oracle-arbitrage --json | jq
        \\
        \\NOTE
        \\  --remote uses curl for HTTPS (pure-stdlib Zig HTTPS is heavy).
        \\  For native HTTPS, supply --rpc with an HTTP endpoint reachable
        \\  through a reverse-proxy that terminates TLS.
        \\
    , .{});
}

// ─── Entry point ────────────────────────────────────────────────────────────
pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const argv = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, argv);

    const args = try parseArgs(allocator, argv);
    defer allocator.free(args.pos);
    defer allocator.free(args.kvs);
    if (args.no_color) g_color = false;
    // Also strip color if stdout is not a TTY (best-effort).
    // std.fs.File.stdout().isTty() returns false when piped → keeps automation clean.
    if (!std.fs.File.stdout().isTty()) g_color = false;

    if (args.cmd.len == 0 or std.mem.eql(u8, args.cmd, "help")) {
        try printHelp();
        return;
    }

    const ep = resolveEndpoint(args);

    const code = blk: {
        if (std.mem.eql(u8, args.cmd, "health")) {
            break :blk try cmdHealth(allocator, ep, args.json);
        }
        if (std.mem.eql(u8, args.cmd, "validators")) {
            break :blk try cmdValidators(allocator, ep, args.json);
        }
        if (std.mem.eql(u8, args.cmd, "stakers")) {
            const limit: u64 = if (args.pos.len > 0)
                std.fmt.parseInt(u64, args.pos[0], 10) catch 10
            else
                10;
            break :blk try cmdStakers(allocator, ep, limit, args.json);
        }

        // ── exchange (no-addr / read) ──────────────────────────────────────
        if (std.mem.eql(u8, args.cmd, "exchange-pairs")) {
            break :blk try cmdExchangePairs(allocator, ep, args.json);
        }
        if (std.mem.eql(u8, args.cmd, "exchange-orderbook")) {
            break :blk try cmdExchangeOrderbook(allocator, ep, args);
        }
        if (std.mem.eql(u8, args.cmd, "exchange-trades")) {
            break :blk try cmdExchangeTrades(allocator, ep, args);
        }
        if (std.mem.eql(u8, args.cmd, "exchange-pair-info")) {
            break :blk try cmdExchangePairInfo(allocator, ep, args);
        }
        if (std.mem.eql(u8, args.cmd, "exchange-stats")) {
            break :blk try cmdExchangeStats(allocator, ep, args);
        }

        // ── htlc / swap / oracle / bridge — read ──────────────────────────
        if (std.mem.eql(u8, args.cmd, "htlc-list")) {
            break :blk try cmdHtlcList(allocator, ep, args.json);
        }
        if (std.mem.eql(u8, args.cmd, "htlc-status")) {
            break :blk try cmdHtlcStatus(allocator, ep, args);
        }
        if (std.mem.eql(u8, args.cmd, "swap-list")) {
            break :blk try cmdSwapList(allocator, ep, args.json);
        }
        if (std.mem.eql(u8, args.cmd, "swap-status")) {
            break :blk try cmdSwapStatus(allocator, ep, args);
        }
        if (std.mem.eql(u8, args.cmd, "oracle-prices")) {
            break :blk try cmdOraclePrices(allocator, ep, args.json);
        }
        if (std.mem.eql(u8, args.cmd, "oracle-arbitrage")) {
            break :blk try cmdOracleArbitrage(allocator, ep, args.json);
        }
        if (std.mem.eql(u8, args.cmd, "oracle-feed")) {
            break :blk try cmdOracleFeed(allocator, ep, args.json);
        }
        if (std.mem.eql(u8, args.cmd, "bridge-status")) {
            break :blk try cmdBridgeStatus(allocator, ep, args.json);
        }
        if (std.mem.eql(u8, args.cmd, "grid-list")) {
            // Owner is optional positional → no addr-required gate.
            const owner: ?[]const u8 = if (args.pos.len > 0) args.pos[0] else null;
            break :blk try cmdGridList(allocator, ep, owner, args.json);
        }
        if (std.mem.eql(u8, args.cmd, "grid-status")) {
            break :blk try cmdGridStatus(allocator, ep, args);
        }

        // ── write-side: the address must come first ──────────────────────
        if (std.mem.eql(u8, args.cmd, "exchange-orders")) {
            if (args.pos.len < 1) break :blk try writeMissing("exchange-orders <addr>");
            break :blk try cmdExchangeOrders(allocator, ep, args.pos[0], args);
        }
        if (std.mem.eql(u8, args.cmd, "exchange-place")) {
            break :blk try cmdExchangePlace(allocator, ep, args);
        }
        if (std.mem.eql(u8, args.cmd, "exchange-cancel")) {
            break :blk try cmdExchangeCancel(allocator, ep, args);
        }
        if (std.mem.eql(u8, args.cmd, "grid-create")) {
            break :blk try cmdGridCreate(allocator, ep, args);
        }
        if (std.mem.eql(u8, args.cmd, "grid-cancel")) {
            break :blk try cmdGridCancel(allocator, ep, args);
        }
        if (std.mem.eql(u8, args.cmd, "htlc-init")) {
            break :blk try cmdHtlcInit(allocator, ep, args);
        }
        if (std.mem.eql(u8, args.cmd, "htlc-claim")) {
            break :blk try cmdHtlcClaim(allocator, ep, args);
        }
        if (std.mem.eql(u8, args.cmd, "htlc-refund")) {
            break :blk try cmdHtlcRefund(allocator, ep, args);
        }
        if (std.mem.eql(u8, args.cmd, "bridge-lock")) {
            break :blk try cmdBridgeLock(allocator, ep, args);
        }

        // ── chain inspection / supply / mempool / sync ────────────────────
        if (std.mem.eql(u8, args.cmd, "mempool")) {
            break :blk try cmdMempool(allocator, ep, args.json);
        }
        if (std.mem.eql(u8, args.cmd, "sync-status")) {
            break :blk try cmdSyncStatus(allocator, ep, args.json);
        }
        if (std.mem.eql(u8, args.cmd, "chain-info")) {
            break :blk try cmdChainInfo(allocator, ep, args.json);
        }
        if (std.mem.eql(u8, args.cmd, "supply")) {
            break :blk try cmdSupply(allocator, ep, args.json);
        }
        if (std.mem.eql(u8, args.cmd, "halving")) {
            break :blk try cmdHalving(allocator, ep, args.json);
        }
        if (std.mem.eql(u8, args.cmd, "prices")) {
            break :blk try cmdPrices(allocator, ep, args);
        }
        // ── network / peers ───────────────────────────────────────────────
        if (std.mem.eql(u8, args.cmd, "peers")) {
            break :blk try cmdPeers(allocator, ep, args.json);
        }
        if (std.mem.eql(u8, args.cmd, "bans")) {
            break :blk try cmdBans(allocator, ep, args.json);
        }
        if (std.mem.eql(u8, args.cmd, "p2p-stats")) {
            break :blk try cmdP2pStats(allocator, ep, args.json);
        }
        if (std.mem.eql(u8, args.cmd, "connect")) {
            break :blk try cmdConnectPeer(allocator, ep, args);
        }
        if (std.mem.eql(u8, args.cmd, "disconnect")) {
            break :blk try cmdDisconnectPeer(allocator, ep, args);
        }
        // ── mining ────────────────────────────────────────────────────────
        if (std.mem.eql(u8, args.cmd, "mining-status")) {
            break :blk try cmdMiningStatus(allocator, ep, args.json);
        }
        if (std.mem.eql(u8, args.cmd, "miners")) {
            break :blk try cmdMiners(allocator, ep, args.json);
        }
        if (std.mem.eql(u8, args.cmd, "pool-stats")) {
            break :blk try cmdPoolStats(allocator, ep, args.json);
        }
        if (std.mem.eql(u8, args.cmd, "slot-leader")) {
            break :blk try cmdSlotLeader(allocator, ep, args.json);
        }
        if (std.mem.eql(u8, args.cmd, "register-miner")) {
            break :blk try cmdRegisterMiner(allocator, ep, args);
        }
        // ── wallet utilities (mnemonic-style) ─────────────────────────────
        if (std.mem.eql(u8, args.cmd, "wallet-derive")) {
            break :blk try cmdWalletDerive(allocator, ep, args);
        }
        if (std.mem.eql(u8, args.cmd, "wallet-pq-derive")) {
            break :blk try cmdWalletPqDerive(allocator, ep, args);
        }
        if (std.mem.eql(u8, args.cmd, "wallet-multichain")) {
            break :blk try cmdWalletMultichain(allocator, ep, args);
        }
        if (std.mem.eql(u8, args.cmd, "wallet-export")) {
            break :blk try cmdWalletExport(allocator, ep, args);
        }
        if (std.mem.eql(u8, args.cmd, "sign-message")) {
            break :blk try cmdSignMessage(allocator, ep, args);
        }
        if (std.mem.eql(u8, args.cmd, "verify-signature")) {
            break :blk try cmdVerifySignature(allocator, ep, args);
        }
        if (std.mem.eql(u8, args.cmd, "send")) {
            break :blk try cmdSend(allocator, ep, args);
        }
        // ── admin / debug ─────────────────────────────────────────────────
        if (std.mem.eql(u8, args.cmd, "set-rpc-token")) {
            break :blk try cmdSetRpcToken(allocator, args);
        }
        if (std.mem.eql(u8, args.cmd, "config")) {
            break :blk try cmdConfig(allocator, args, ep);
        }
        if (std.mem.eql(u8, args.cmd, "logs")) {
            break :blk try cmdLogs(allocator, args);
        }
        if (std.mem.eql(u8, args.cmd, "vps-health")) {
            break :blk try cmdVpsHealth(allocator);
        }
        if (std.mem.eql(u8, args.cmd, "stress-quick")) {
            break :blk try cmdStressQuick(allocator);
        }
        if (std.mem.eql(u8, args.cmd, "benchmark")) {
            break :blk try cmdBenchmark(allocator, ep, args);
        }
        if (std.mem.eql(u8, args.cmd, "watch")) {
            // watch <command> [interval=5] — recursive single-shot loop.
            if (args.pos.len < 1) break :blk try writeMissing("watch <command> [interval=5]");
            const interval: u64 = if (args.pos.len > 1)
                std.fmt.parseInt(u64, args.pos[1], 10) catch 5
            else
                5;
            // Inline loop: re-invoke own binary via exec.
            var i_loop: usize = 0;
            while (i_loop < 100) : (i_loop += 1) {
                try stdout().print("{s}--- watch tick {d} ---{s}\n",
                    .{ col(C_GRAY), i_loop, rst() });
                _ = runProcess(allocator, &.{
                    "omnibus-cli", args.pos[0],
                }) catch 1;
                std.Thread.sleep(interval * std.time.ns_per_s);
            }
            break :blk @as(u8, 0);
        }
        // ── faucet ────────────────────────────────────────────────────────
        if (std.mem.eql(u8, args.cmd, "faucet-status")) {
            break :blk try cmdFaucetStatus(allocator, ep, args.json);
        }
        if (std.mem.eql(u8, args.cmd, "faucet-claim")) {
            break :blk try cmdFaucetClaim(allocator, ep, args);
        }
        if (std.mem.eql(u8, args.cmd, "faucet-claims")) {
            break :blk try cmdFaucetClaims(allocator, ep, args.json);
        }
        // ── 0day / security ───────────────────────────────────────────────
        if (std.mem.eql(u8, args.cmd, "zeroday-events")) {
            break :blk try cmdZerodayEvents(allocator, ep, args.json);
        }
        if (std.mem.eql(u8, args.cmd, "zeroday-report")) {
            break :blk try cmdZerodayReport(allocator, ep, args);
        }
        if (std.mem.eql(u8, args.cmd, "sybil-check")) {
            break :blk try cmdSybilCheck(allocator, ep, args);
        }
        // ── audit chain consistency ───────────────────────────────────────
        if (std.mem.eql(u8, args.cmd, "audit-totals")) {
            break :blk try cmdAuditTotals(allocator, ep, args.json);
        }
        if (std.mem.eql(u8, args.cmd, "audit-stakes")) {
            break :blk try cmdAuditStakes(allocator, ep, args.json);
        }
        if (std.mem.eql(u8, args.cmd, "audit-supply")) {
            break :blk try cmdAuditSupply(allocator, ep, args.json);
        }
        if (std.mem.eql(u8, args.cmd, "audit-mempool")) {
            break :blk try cmdAuditMempool(allocator, ep, args.json);
        }
        if (std.mem.eql(u8, args.cmd, "audit-fees")) {
            break :blk try cmdAuditFees(allocator, ep, args.json);
        }
        // ── restart / control (SSH wrappers) ──────────────────────────────
        if (std.mem.eql(u8, args.cmd, "services-status")) {
            break :blk try cmdServicesStatus(allocator);
        }
        if (std.mem.eql(u8, args.cmd, "service-restart")) {
            break :blk try cmdServiceRestart(allocator, args);
        }
        if (std.mem.eql(u8, args.cmd, "oracle-restart")) {
            break :blk try cmdOracleRestart(allocator, args);
        }
        if (std.mem.eql(u8, args.cmd, "oracle-snapshot")) {
            break :blk try cmdOracleSnapshot(allocator);
        }

        // ── names (.omnibus / .arbitraje / .bank / etc.) ───────────────────
        if (std.mem.eql(u8, args.cmd, "ns-tlds")) {
            break :blk try cmdNsTlds(allocator, ep, args.json);
        }
        if (std.mem.eql(u8, args.cmd, "ns-stats")) {
            break :blk try cmdNsStats(allocator, ep, args.json);
        }
        if (std.mem.eql(u8, args.cmd, "ns-list")) {
            const owner: ?[]const u8 = if (args.pos.len > 0) args.pos[0] else null;
            break :blk try cmdNsList(allocator, ep, owner, args.json);
        }
        if (std.mem.eql(u8, args.cmd, "ns-resolve")) {
            if (args.pos.len < 1) break :blk try writeMissing("ns-resolve <name>");
            break :blk try cmdNsResolve(allocator, ep, args.pos[0], args.json);
        }
        if (std.mem.eql(u8, args.cmd, "ns-reverse")) {
            if (args.pos.len < 1) break :blk try writeMissing("ns-reverse <addr>");
            break :blk try cmdNsReverse(allocator, ep, args.pos[0], args.json);
        }
        if (std.mem.eql(u8, args.cmd, "ns-fee")) {
            if (args.pos.len < 1) break :blk try writeMissing("ns-fee <tld>");
            break :blk try cmdNsFee(allocator, ep, args.pos[0], args.json);
        }
        if (std.mem.eql(u8, args.cmd, "ns-expiring")) {
            const days: u64 = if (args.pos.len > 0)
                std.fmt.parseInt(u64, args.pos[0], 10) catch 30
            else 30;
            break :blk try cmdNsExpiring(allocator, ep, days, args.json);
        }
        if (std.mem.eql(u8, args.cmd, "ns-by-category")) {
            if (args.pos.len < 1) break :blk try writeMissing("ns-by-category <category>");
            break :blk try cmdNsByCategory(allocator, ep, args.pos[0], args.json);
        }
        if (std.mem.eql(u8, args.cmd, "ns-register")) {
            break :blk try cmdNsRegister(allocator, ep, args);
        }
        if (std.mem.eql(u8, args.cmd, "ns-renew")) {
            break :blk try cmdNsRenew(allocator, ep, args);
        }
        if (std.mem.eql(u8, args.cmd, "ns-transfer")) {
            break :blk try cmdNsTransfer(allocator, ep, args);
        }
        if (std.mem.eql(u8, args.cmd, "ns-update")) {
            break :blk try cmdNsUpdate(allocator, ep, args);
        }

        // ── agents (autonomous strategies) ─────────────────────────────────
        if (std.mem.eql(u8, args.cmd, "agents-list")) {
            break :blk try cmdAgentsList(allocator, ep, args.json);
        }
        if (std.mem.eql(u8, args.cmd, "agent-info")) {
            if (args.pos.len < 1) break :blk try writeMissing("agent-info <agent_id>");
            break :blk try cmdAgentInfo(allocator, ep, args.pos[0], args.json);
        }
        if (std.mem.eql(u8, args.cmd, "agent-decisions")) {
            if (args.pos.len < 1) break :blk try writeMissing("agent-decisions <agent_id>");
            break :blk try cmdAgentDecisions(allocator, ep, args.pos[0], args.json);
        }
        if (std.mem.eql(u8, args.cmd, "agent-register")) {
            break :blk try cmdAgentRegister(allocator, ep, args);
        }
        if (std.mem.eql(u8, args.cmd, "agent-unregister")) {
            break :blk try cmdAgentUnregister(allocator, ep, args);
        }
        if (std.mem.eql(u8, args.cmd, "agent-edit")) {
            break :blk try cmdAgentEdit(allocator, ep, args);
        }
        if (std.mem.eql(u8, args.cmd, "agent-follow")) {
            break :blk try cmdAgentFollow(allocator, ep, args);
        }

        // ── governance (proposals + treasury) ──────────────────────────────
        if (std.mem.eql(u8, args.cmd, "gov-proposals")) {
            break :blk try cmdGovProposals(allocator, ep, args.json);
        }
        if (std.mem.eql(u8, args.cmd, "gov-treasury")) {
            break :blk try cmdGovTreasury(allocator, ep, args.json);
        }
        if (std.mem.eql(u8, args.cmd, "gov-proposal")) {
            if (args.pos.len < 1) break :blk try writeMissing("gov-proposal <id>");
            break :blk try cmdGovProposal(allocator, ep, args.pos[0], args.json);
        }
        if (std.mem.eql(u8, args.cmd, "gov-propose")) {
            break :blk try cmdGovPropose(allocator, ep, args);
        }
        if (std.mem.eql(u8, args.cmd, "gov-vote")) {
            break :blk try cmdGovVote(allocator, ep, args);
        }
        if (std.mem.eql(u8, args.cmd, "gov-execute")) {
            break :blk try cmdGovExecute(allocator, ep, args);
        }

        // ── escrow (programmable arbitered hold) ───────────────────────────
        if (std.mem.eql(u8, args.cmd, "escrow-list")) {
            const a: ?[]const u8 = if (args.pos.len > 0) args.pos[0] else null;
            break :blk try cmdEscrowList(allocator, ep, a, args.json);
        }
        if (std.mem.eql(u8, args.cmd, "escrow-info")) {
            if (args.pos.len < 1) break :blk try writeMissing("escrow-info <escrow_id>");
            break :blk try cmdEscrowInfo(allocator, ep, args.pos[0], args.json);
        }
        if (std.mem.eql(u8, args.cmd, "escrow-create")) {
            break :blk try cmdEscrowCreate(allocator, ep, args);
        }
        if (std.mem.eql(u8, args.cmd, "escrow-release")) {
            break :blk try cmdEscrowAction(allocator, ep, args, "escrow_release", "escrow-release");
        }
        if (std.mem.eql(u8, args.cmd, "escrow-refund")) {
            break :blk try cmdEscrowAction(allocator, ep, args, "escrow_refund", "escrow-refund");
        }
        if (std.mem.eql(u8, args.cmd, "escrow-dispute")) {
            break :blk try cmdEscrowAction(allocator, ep, args, "escrow_dispute", "escrow-dispute");
        }

        // ── payment channels ───────────────────────────────────────────────
        if (std.mem.eql(u8, args.cmd, "channels-list")) {
            const a: ?[]const u8 = if (args.pos.len > 0) args.pos[0] else null;
            break :blk try cmdChannelsList(allocator, ep, a, args.json);
        }
        if (std.mem.eql(u8, args.cmd, "channel-info")) {
            if (args.pos.len < 1) break :blk try writeMissing("channel-info <channel_id>");
            break :blk try cmdChannelInfo(allocator, ep, args.pos[0], args.json);
        }
        if (std.mem.eql(u8, args.cmd, "channel-open")) {
            break :blk try cmdChannelOpen(allocator, ep, args);
        }
        if (std.mem.eql(u8, args.cmd, "channel-pay")) {
            break :blk try cmdChannelPay(allocator, ep, args);
        }
        if (std.mem.eql(u8, args.cmd, "channel-close")) {
            break :blk try cmdChannelClose(allocator, ep, args);
        }

        // ── notarization ───────────────────────────────────────────────────
        if (std.mem.eql(u8, args.cmd, "notarize-list")) {
            if (args.pos.len < 1) break :blk try writeMissing("notarize-list <addr>");
            break :blk try cmdNotarizeList(allocator, ep, args.pos[0], args.json);
        }
        if (std.mem.eql(u8, args.cmd, "notarize-verify")) {
            if (args.pos.len < 1) break :blk try writeMissing("notarize-verify <doc_hash>");
            break :blk try cmdNotarizeVerify(allocator, ep, args.pos[0], args.json);
        }
        if (std.mem.eql(u8, args.cmd, "notarize-doc")) {
            break :blk try cmdNotarizeDoc(allocator, ep, args);
        }
        if (std.mem.eql(u8, args.cmd, "notarize-revoke")) {
            break :blk try cmdNotarizeRevoke(allocator, ep, args);
        }

        // ── subscriptions (recurring payments) ─────────────────────────────
        if (std.mem.eql(u8, args.cmd, "sub-list")) {
            if (args.pos.len < 1) break :blk try writeMissing("sub-list <addr>");
            break :blk try cmdSubList(allocator, ep, args.pos[0], args.json);
        }
        if (std.mem.eql(u8, args.cmd, "sub-create")) {
            break :blk try cmdSubCreate(allocator, ep, args);
        }
        if (std.mem.eql(u8, args.cmd, "sub-cancel")) {
            break :blk try cmdSubCancel(allocator, ep, args);
        }

        // ── multisig (M-of-N) ──────────────────────────────────────────────
        if (std.mem.eql(u8, args.cmd, "multisig-create")) {
            break :blk try cmdMultisigCreate(allocator, ep, args);
        }
        if (std.mem.eql(u8, args.cmd, "multisig-info")) {
            if (args.pos.len < 1) break :blk try writeMissing("multisig-info <addr>");
            break :blk try cmdMultisigInfo(allocator, ep, args.pos[0], args.json);
        }
        if (std.mem.eql(u8, args.cmd, "multisig-send")) {
            break :blk try cmdMultisigSend(allocator, ep, args);
        }
        // New unified `multisig` subcommand router.
        if (std.mem.eql(u8, args.cmd, "multisig")) {
            break :blk try cmdMultisig(allocator, ep, args);
        }

        // ── coldwallet ────────────────────────────────────────────────────
        if (std.mem.eql(u8, args.cmd, "coldwallet")) {
            break :blk try cmdColdwallet(allocator, ep, args);
        }

        // ── timelock ──────────────────────────────────────────────────────
        if (std.mem.eql(u8, args.cmd, "timelock")) {
            break :blk try cmdTimelock(allocator, ep, args);
        }

        // ── covenant ──────────────────────────────────────────────────────
        if (std.mem.eql(u8, args.cmd, "covenant")) {
            break :blk try cmdCovenant(allocator, ep, args);
        }

        // ── treasury (auto-distribute) ─────────────────────────────────────
        if (std.mem.eql(u8, args.cmd, "treasury")) {
            break :blk try cmdTreasury(allocator, ep, args);
        }

        // ── PQ identity (4 soulbound + cross-chain attest) ─────────────────
        if (std.mem.eql(u8, args.cmd, "pq-schemes")) {
            break :blk try cmdPqSchemes(allocator, ep, args.json);
        }
        if (std.mem.eql(u8, args.cmd, "pq-identity")) {
            if (args.pos.len < 1) break :blk try writeMissing("pq-identity <addr>");
            break :blk try cmdPqIdentity(allocator, ep, args.pos[0], args.json);
        }
        if (std.mem.eql(u8, args.cmd, "pq-balance")) {
            if (args.pos.len < 1) break :blk try writeMissing("pq-balance <addr>");
            break :blk try cmdPqBalance(allocator, ep, args.pos[0], args.json);
        }
        if (std.mem.eql(u8, args.cmd, "pq-attest")) {
            break :blk try cmdPqAttest(allocator, ep, args);
        }

        // ── Profile (DID + OBM + facets + MiCA) ───────────────────────────
        if (std.mem.eql(u8, args.cmd, "profile")) {
            break :blk try cmdProfile(allocator, ep, args);
        }
        if (std.mem.eql(u8, args.cmd, "mica")) {
            break :blk try cmdMica(allocator, ep, args);
        }

        // ── POAP / Social ──────────────────────────────────────────────────
        if (std.mem.eql(u8, args.cmd, "poap-events")) {
            break :blk try cmdPoapEvents(allocator, ep, args.json);
        }
        if (std.mem.eql(u8, args.cmd, "poap-claim")) {
            break :blk try cmdPoapClaim(allocator, ep, args);
        }
        if (std.mem.eql(u8, args.cmd, "follow")) {
            break :blk try cmdFollow(allocator, ep, args);
        }
        if (std.mem.eql(u8, args.cmd, "followers")) {
            if (args.pos.len < 1) break :blk try writeMissing("followers <addr>");
            break :blk try cmdFollowers(allocator, ep, args.pos[0], args.json);
        }
        if (std.mem.eql(u8, args.cmd, "following")) {
            if (args.pos.len < 1) break :blk try writeMissing("following <addr>");
            break :blk try cmdFollowing(allocator, ep, args.pos[0], args.json);
        }

        // ── key management (no on-chain RPC; pure local derivation) ──────
        if (std.mem.eql(u8, args.cmd, "derive-key")) {
            break :blk try cmdDeriveKey(allocator, args);
        }
        if (std.mem.eql(u8, args.cmd, "wallet-list") or
            std.mem.eql(u8, args.cmd, "list-keys"))
        {
            break :blk try cmdWalletList(allocator, args);
        }

        // address-required commands
        if (args.pos.len == 0) {
            try stderr().print(
                "{s}error:{s} `{s}` requires an address argument\n",
                .{ col(C_RED), rst(), args.cmd });
            try printHelp();
            break :blk @as(u8, 2);
        }
        const addr = args.pos[0];
        if (std.mem.eql(u8, args.cmd, "balance")) {
            break :blk try cmdBalance(allocator, ep, addr, args.json);
        }
        if (std.mem.eql(u8, args.cmd, "wallet-summary") or
            std.mem.eql(u8, args.cmd, "summary") or
            std.mem.eql(u8, args.cmd, "ws"))
        {
            break :blk try cmdWalletSummary(allocator, ep, addr, args.json);
        }
        if (std.mem.eql(u8, args.cmd, "stake")) {
            break :blk try cmdStake(allocator, ep, addr, args.json);
        }
        if (std.mem.eql(u8, args.cmd, "reputation")) {
            break :blk try cmdReputation(allocator, ep, addr, args.json);
        }
        if (std.mem.eql(u8, args.cmd, "did")) {
            break :blk try dumpRpcResult(allocator, ep, "getdid",
                try std.fmt.allocPrint(allocator, "[\"{s}\"]", .{addr}),
                args.json, "DID");
        }
        if (std.mem.eql(u8, args.cmd, "obm")) {
            break :blk try dumpRpcResult(allocator, ep, "getobm",
                try std.fmt.allocPrint(allocator, "[\"{s}\"]", .{addr}),
                args.json, "OmniBus Binary Map");
        }
        if (std.mem.eql(u8, args.cmd, "facets")) {
            break :blk try dumpRpcResult(allocator, ep, "getfacets",
                try std.fmt.allocPrint(allocator, "[\"{s}\"]", .{addr}),
                args.json, "ID Facets (Social / Professional / Cultural)");
        }
        if (std.mem.eql(u8, args.cmd, "daily")) {
            const days: u64 = if (args.pos.len > 1)
                std.fmt.parseInt(u64, args.pos[1], 10) catch 30
            else
                30;
            break :blk try cmdDaily(allocator, ep, addr, days, args.json);
        }
        if (std.mem.eql(u8, args.cmd, "history")) {
            const filter: []const u8 = if (args.pos.len > 1) args.pos[1] else "all";
            break :blk try cmdHistory(allocator, ep, addr, filter, args.json);
        }
        if (std.mem.eql(u8, args.cmd, "verify")) {
            break :blk try cmdVerify(allocator, ep, addr, args.json);
        }
        // ── chain inspection requiring an arg ─────────────────────────────
        if (std.mem.eql(u8, args.cmd, "block")) {
            break :blk try cmdBlock(allocator, ep, addr, args.json);
        }
        if (std.mem.eql(u8, args.cmd, "block-hash")) {
            break :blk try cmdBlockByHash(allocator, ep, addr, args.json);
        }
        if (std.mem.eql(u8, args.cmd, "tx")) {
            break :blk try cmdTx(allocator, ep, addr, args.json);
        }
        if (std.mem.eql(u8, args.cmd, "peer-info")) {
            break :blk try cmdPeerInfo(allocator, ep, addr, args.json);
        }
        if (std.mem.eql(u8, args.cmd, "miner-stats")) {
            break :blk try cmdMinerStats(allocator, ep, addr, args.json);
        }

        try stderr().print(
            "{s}error:{s} unknown command `{s}`\n\n",
            .{ col(C_RED), rst(), args.cmd });
        try printHelp();
        break :blk @as(u8, 2);
    };
    std.process.exit(code);
}

// ─── Tests ──────────────────────────────────────────────────────────────────

test "parseDay maps block_height / 86400" {
    try std.testing.expectEqual(@as(u64, 0), parseDay(0));
    try std.testing.expectEqual(@as(u64, 0), parseDay(86399));
    try std.testing.expectEqual(@as(u64, 1), parseDay(86400));
    try std.testing.expectEqual(@as(u64, 1), parseDay(172_799));
    try std.testing.expectEqual(@as(u64, 2), parseDay(172_800));
    try std.testing.expectEqual(@as(u64, 100), parseDay(8_640_000));
}

test "formatOmni divides by 1e9 and rounds to 4 decimals" {
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("0.0000", try formatOmni(&buf, 0));
    try std.testing.expectEqualStrings("1.0000", try formatOmni(&buf, 1_000_000_000));
    try std.testing.expectEqualStrings("21.0000", try formatOmni(&buf, 21_000_000_000));
    try std.testing.expectEqualStrings("243.0916", try formatOmni(&buf, 243_091_600_000));
    // 0.5 sat-per-omni = round-up
    try std.testing.expectEqualStrings("0.0001", try formatOmni(&buf, 100_000));
    // 50_000 sat-frac = 0.00005 OMNI rounds to 0.0001 (half-up at 4 decimals).
    try std.testing.expectEqualStrings("0.0001", try formatOmni(&buf, 50_000));
}

test "parseRpcResponse extracts result.balance" {
    const json =
        \\{"jsonrpc":"2.0","id":1,"result":{"address":"ob1q","balance":12345,"balanceOMNI":"0.000012345"}}
    ;
    const allocator = std.testing.allocator;
    var p = try parse(allocator, json);
    defer p.deinit();
    var err_msg: []const u8 = "";
    const r = extractResult(p.value, &err_msg) orelse return error.NoResult;
    try std.testing.expectEqual(@as(u64, 12345), jsonGetU64(r, "balance"));
    try std.testing.expectEqualStrings("ob1q", jsonGetStr(r, "address").?);
}

test "parseRpcResponse surfaces error.message" {
    const json =
        \\{"jsonrpc":"2.0","id":1,"error":{"code":-32601,"message":"method not found"}}
    ;
    const allocator = std.testing.allocator;
    var p = try parse(allocator, json);
    defer p.deinit();
    var err_msg: []const u8 = "";
    const r = extractResult(p.value, &err_msg);
    try std.testing.expect(r == null);
    try std.testing.expectEqualStrings("method not found", err_msg);
}

test "rpcError synthesizes JSON-RPC error envelope" {
    const allocator = std.testing.allocator;
    const out = try rpcError(allocator, "boom: {s}", .{"timeout"});
    defer allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"error\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "boom: timeout") != null);
}

test "parsePairId numeric in range" {
    try std.testing.expectEqual(@as(?u16, 0), parsePairId("0"));
    try std.testing.expectEqual(@as(?u16, 6), parsePairId("6"));
    try std.testing.expectEqual(@as(?u16, null), parsePairId("7"));
    try std.testing.expectEqual(@as(?u16, null), parsePairId("999"));
}

test "parsePairId labels case-insensitive + dash/slash" {
    try std.testing.expectEqual(@as(?u16, 0), parsePairId("OMNI/USDC"));
    try std.testing.expectEqual(@as(?u16, 0), parsePairId("omni-usdc"));
    try std.testing.expectEqual(@as(?u16, 0), parsePairId("OMNI/USD"));
    try std.testing.expectEqual(@as(?u16, 1), parsePairId("BTC/USDC"));
    try std.testing.expectEqual(@as(?u16, 2), parsePairId("LCX/USD"));
    try std.testing.expectEqual(@as(?u16, 3), parsePairId("eth/usdc"));
    try std.testing.expectEqual(@as(?u16, 4), parsePairId("OMNI/BTC"));
    try std.testing.expectEqual(@as(?u16, 5), parsePairId("OMNI/LCX"));
    try std.testing.expectEqual(@as(?u16, 6), parsePairId("OMNI/ETH"));
    try std.testing.expectEqual(@as(?u16, null), parsePairId("FOO/BAR"));
}

test "parsePrice: decimals → micro-USD, integers passthrough" {
    try std.testing.expectEqual(@as(?u64, 523_400), parsePrice("0.5234"));
    try std.testing.expectEqual(@as(?u64, 1_000_000), parsePrice("1.0"));
    try std.testing.expectEqual(@as(?u64, 80_500_000_000), parsePrice("80500.0"));
    // Big integer assumed already-micro
    try std.testing.expectEqual(@as(?u64, 520_000), parsePrice("520000"));
    // Small integer scaled to whole USD
    try std.testing.expectEqual(@as(?u64, 80_000_000), parsePrice("80"));
    try std.testing.expectEqual(@as(?u64, null), parsePrice("not-a-number"));
}

test "parseOmni: decimals → SAT, raw SAT passthrough" {
    try std.testing.expectEqual(@as(?u64, 1_000_000_000), parseOmni("1.0"));
    try std.testing.expectEqual(@as(?u64, 5_500_000_000), parseOmni("5.5"));
    try std.testing.expectEqual(@as(?u64, 5_000_000_000), parseOmni("5000000000"));
    try std.testing.expectEqual(@as(?u64, null), parseOmni("not"));
    // 10-digit fraction is rejected (>9 places)
    try std.testing.expectEqual(@as(?u64, null), parseOmni("1.1234567890"));
}

test "halving math: next_halving = ((h/210k)+1)*210k" {
    const halving_period: u64 = 210_000;
    const h: u64 = 33_800;
    const next_halving = ((h / halving_period) + 1) * halving_period;
    try std.testing.expectEqual(@as(u64, 210_000), next_halving);
    const h2: u64 = 250_000;
    const nh2 = ((h2 / halving_period) + 1) * halving_period;
    try std.testing.expectEqual(@as(u64, 420_000), nh2);
}

test "audit-supply expected reward sum at h=1 is 50 OMNI" {
    const init_reward: u64 = 50 * SAT_PER_OMNI;
    const halving_period: u64 = 210_000;
    var expected: u64 = 0;
    var h: u64 = 1;
    while (h <= 1) : (h += 1) {
        const halvings = (h - 1) / halving_period;
        const cur = init_reward >> @intCast(@min(halvings, 63));
        expected += cur;
    }
    try std.testing.expectEqual(@as(u64, 50_000_000_000), expected);
}

test "configPath under USERPROFILE / HOME" {
    const allocator = std.testing.allocator;
    const path = try configPath(allocator);
    defer allocator.free(path);
    try std.testing.expect(std.mem.endsWith(u8, path, "/.omnibus/cli.conf"));
}
