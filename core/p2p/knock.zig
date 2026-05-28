// "Knock-knock" UDP broadcast for anti-Sybil duplicate-host detection.
//
// At startup each miner broadcasts `OMNI:we are here:<node_id>:<height>` on
// UDP port 9333 (255.255.255.255), then listens for ~3s. If another packet
// arrives from a different node_id, the LAN already has a miner — this node
// transitions to IDLE state to enforce "1 miner per public IP" (memory
// project_omnibus_anti_sybil).
//
// The actual transition decision lives in P2PNode.knockKnock (still in
// core/p2p.zig) — this file owns only the wire send/listen primitives.

const std = @import("std");

/// Outcome of a knock-knock round-trip.
pub const KnockResult = enum {
    /// Primul miner pe acest IP — poate mina
    alone,
    /// Alt miner detectat pe acelasi IP — sta IDLE
    duplicate_ip,
    /// Broadcast esuat (firewall, VPN, etc.) — continua cu avertizare
    broadcast_failed,
};

/// Rezultat intern listen (cu IP sursa pentru duplicate_ip).
pub const ListenResult = union(KnockResult) {
    alone:            void,
    duplicate_ip:     [4]u8,  // IP-ul care a trimis duplicat
    broadcast_failed: void,
};

/// Trimite un pachet UDP broadcast pe portul specificat (255.255.255.255).
pub fn knockUDP(msg: []const u8, port: u16) !void {
    const sock = try std.posix.socket(
        std.posix.AF.INET,
        std.posix.SOCK.DGRAM,
        std.posix.IPPROTO.UDP,
    );
    defer std.posix.close(sock);

    // SO_BROADCAST necesar pentru 255.255.255.255
    const opt_val: i32 = 1;
    try std.posix.setsockopt(
        sock,
        std.posix.SOL.SOCKET,
        std.posix.SO.BROADCAST,
        std.mem.asBytes(&opt_val),
    );

    // SO_REUSEADDR — permite multiple noduri sa asculte pe acelasi port
    try std.posix.setsockopt(
        sock,
        std.posix.SOL.SOCKET,
        std.posix.SO.REUSEADDR,
        std.mem.asBytes(&opt_val),
    );

    const dest = std.net.Address.initIp4(.{ 255, 255, 255, 255 }, port);
    _ = try std.posix.sendto(sock, msg, 0, &dest.any, dest.getOsSockLen());
}

/// Asculta UDP pe `port` pentru `timeout_ms` milisecunde.
/// Daca primeste "OMNI:we are here:<alt_node_id>:<h>" de pe acelasi IP → duplicate_ip.
/// Propria noastra reflectie (acelasi node_id) e ignorata.
pub fn listenKnockUDP(
    own_node_id: []const u8,
    port:        u16,
    timeout_ms:  u64,
) ListenResult {
    const sock = std.posix.socket(
        std.posix.AF.INET,
        std.posix.SOCK.DGRAM,
        std.posix.IPPROTO.UDP,
    ) catch return .{ .broadcast_failed = {} };
    defer std.posix.close(sock);

    // SO_REUSEADDR + SO_REUSEPORT ca mai multi mineri pe acelasi host sa poata asculta
    const opt_val: i32 = 1;
    std.posix.setsockopt(sock, std.posix.SOL.SOCKET, std.posix.SO.REUSEADDR,
        std.mem.asBytes(&opt_val)) catch {};
    // SO_REUSEPORT disponibil pe Linux/macOS, ignorat pe Windows
    std.posix.setsockopt(sock, std.posix.SOL.SOCKET, 15, // SO_REUSEPORT = 15
        std.mem.asBytes(&opt_val)) catch {};

    // Bind pe 0.0.0.0:port
    const bind_addr = std.net.Address.initIp4(.{ 0, 0, 0, 0 }, port);
    std.posix.bind(sock, &bind_addr.any, bind_addr.getOsSockLen()) catch
        return .{ .broadcast_failed = {} };

    // SO_RCVTIMEO — timeout receive
    const tv_sec  = timeout_ms / 1000;
    const tv_usec = (timeout_ms % 1000) * 1000;
    var timeval_buf: [16]u8 = @splat(0);
    std.mem.writeInt(i64, timeval_buf[0..8],  @intCast(tv_sec),  .little);
    std.mem.writeInt(i64, timeval_buf[8..16], @intCast(tv_usec), .little);
    std.posix.setsockopt(sock, std.posix.SOL.SOCKET, std.posix.SO.RCVTIMEO,
        &timeval_buf) catch {};

    // Asculta pana la timeout
    const deadline = std.time.milliTimestamp() + @as(i64, @intCast(timeout_ms));
    var recv_buf: [512]u8 = undefined;
    var src_addr: std.posix.sockaddr = undefined;
    var src_len: std.posix.socklen_t = @sizeOf(std.posix.sockaddr);

    while (std.time.milliTimestamp() < deadline) {
        const n = std.posix.recvfrom(
            sock, &recv_buf, 0, &src_addr, &src_len,
        ) catch break;

        if (n < 5) continue;
        const pkt = recv_buf[0..n];

        const prefix = "OMNI:we are here:";
        if (!std.mem.startsWith(u8, pkt, prefix)) continue;

        const after_prefix = pkt[prefix.len..];
        const colon_pos = std.mem.indexOfScalar(u8, after_prefix, ':') orelse continue;
        const sender_node_id = after_prefix[0..colon_pos];

        const own_short = own_node_id[0..@min(own_node_id.len, sender_node_id.len)];
        if (std.mem.eql(u8, sender_node_id, own_short)) continue;

        const sa_in: *const std.posix.sockaddr.in = @alignCast(@ptrCast(&src_addr));
        const ip_raw = std.mem.toBytes(sa_in.addr);
        const ip = [4]u8{ ip_raw[0], ip_raw[1], ip_raw[2], ip_raw[3] };

        std.debug.print("[KNOCK] << Raspuns de la {d}.{d}.{d}.{d} — node \"{s}\"\n",
            .{ ip[0], ip[1], ip[2], ip[3], sender_node_id[0..@min(16, sender_node_id.len)] });

        return .{ .duplicate_ip = ip };
    }

    return .{ .alone = {} };
}
