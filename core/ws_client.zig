/// ws_client.zig — Pure-Zig RFC 6455 WebSocket client for OmniBus BlockChainCore.
///
/// Cross-platform (Windows + Linux) using std.net.Stream for TCP, and
/// std.crypto.tls.Client for TLS (wss://). No external dependencies.
///
/// Usage (caller owns reconnect logic):
///
///     var ws = try WsClient.connect(gpa, "stream.example.com", 443, "/ws", true);
///     defer ws.close();
///     try ws.send("{\"op\":\"subscribe\"}");
///
///     var buf: [64 * 1024]u8 = undefined;
///     while (true) {
///         const msg = (try ws.recv(&buf)) orelse continue; // null = control frame handled
///         switch (msg.kind) {
///             .text => {/* ... */},
///             .ping => try ws.sendPong(msg.data),
///             .pong => {},
///             .close => return error.ConnectionClosed,
///         }
///     }
///
/// Notes:
///  - recv() returns `error.ConnectionClosed` on EOF / remote close. Callers
///    should re-establish a new WsClient on errors.
///  - All client→server frames are masked with a 4-byte XOR key as required
///    by RFC 6455 §5.3 (otherwise compliant servers MUST drop the connection).
///  - Only text (0x1), ping (0x9), pong (0xA), close (0x8) opcodes are handled
///    on the read path. Binary frames return error.UnsupportedOpcode (use a
///    different client if you need binary).
///  - Fragmentation: this client supports multi-frame text messages by
///    accumulating continuation frames into the caller-provided buffer.

const std = @import("std");
const builtin = @import("builtin");

const Allocator = std.mem.Allocator;
const Sha1 = std.crypto.hash.Sha1;

// ─── Public types ─────────────────────────────────────────────────────────────

pub const MessageKind = enum { text, ping, pong, close };

pub const Message = struct {
    kind: MessageKind,
    data: []const u8,
};

pub const WsError = error{
    ConnectionClosed,
    HandshakeFailed,
    InvalidUpgrade,
    InvalidAcceptKey,
    InvalidFrame,
    UnsupportedOpcode,
    MessageTooLarge,
    BufferTooSmall,
    OutOfMemory,
};

// ─── Transport abstraction (plain TCP vs TLS over TCP) ────────────────────────
//
// Both branches expose a uniform read/write surface: rawRead, rawWrite, close.
// The TLS branch carries the TLS Client + its read/write buffers (allocated on
// the heap so the reader/writer pointers are stable) plus the underlying
// std.net.Stream Reader/Writer that feed the TLS layer.

const TlsBundle = struct {
    /// Heap-allocated so client.input / client.output pointers stay valid.
    tls_client: *std.crypto.tls.Client,
    /// Underlying TCP reader/writer (the TLS Client borrows pointers into these).
    stream_reader: *std.net.Stream.Reader,
    stream_writer: *std.net.Stream.Writer,
    /// Buffers owned here so destructor can free them.
    tls_read_buf: []u8,
    tls_write_buf: []u8,
    sock_read_buf: []u8,
    sock_write_buf: []u8,
    /// CA bundle (loaded from system roots).
    ca_bundle: std.crypto.Certificate.Bundle,
};

const Transport = union(enum) {
    plain: std.net.Stream,
    tls: TlsBundle,

    fn close(self: *Transport, gpa: Allocator) void {
        switch (self.*) {
            .plain => |s| s.close(),
            .tls => |*t| {
                // Best-effort close_notify — ignore errors, we're tearing down.
                t.tls_client.end() catch {};
                t.stream_writer.interface.flush() catch {};
                // Close underlying TCP socket.
                t.stream_reader.getStream().close();
                // Free bundles.
                t.ca_bundle.deinit(gpa);
                gpa.free(t.tls_read_buf);
                gpa.free(t.tls_write_buf);
                gpa.free(t.sock_read_buf);
                gpa.free(t.sock_write_buf);
                gpa.destroy(t.tls_client);
                gpa.destroy(t.stream_reader);
                gpa.destroy(t.stream_writer);
            },
        }
    }

    /// Write all bytes (no buffering above what the transport already does).
    fn writeAll(self: *Transport, bytes: []const u8) WsError!void {
        switch (self.*) {
            .plain => |s| s.writeAll(bytes) catch return error.ConnectionClosed,
            .tls => |*t| {
                t.tls_client.writer.writeAll(bytes) catch return error.ConnectionClosed;
                t.tls_client.writer.flush() catch return error.ConnectionClosed;
                t.stream_writer.interface.flush() catch return error.ConnectionClosed;
            },
        }
    }

    /// Read exactly `buf.len` bytes or fail with ConnectionClosed.
    fn readExact(self: *Transport, buf: []u8) WsError!void {
        switch (self.*) {
            .plain => |s| {
                var off: usize = 0;
                while (off < buf.len) {
                    const n = s.read(buf[off..]) catch return error.ConnectionClosed;
                    if (n == 0) return error.ConnectionClosed;
                    off += n;
                }
            },
            .tls => |*t| {
                t.tls_client.reader.readSliceAll(buf) catch return error.ConnectionClosed;
            },
        }
    }
};

// ─── Helpers: TCP connect (cross-platform) ────────────────────────────────────

fn tcpConnect(gpa: Allocator, host: []const u8, port: u16) !std.net.Stream {
    // tcpConnectToHost handles DNS + IPv4/IPv6 on both Windows and Linux.
    return std.net.tcpConnectToHost(gpa, host, port);
}

// ─── Helpers: handshake key generation + accept verification ─────────────────

const ws_guid = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";

fn genWsKey(out_b64: *[24]u8) void {
    var raw: [16]u8 = undefined;
    std.crypto.random.bytes(&raw);
    const Encoder = std.base64.standard.Encoder;
    _ = Encoder.encode(out_b64, &raw);
}

fn computeExpectedAccept(client_key: []const u8, out_b64: *[28]u8) void {
    var sha: Sha1 = .init(.{});
    sha.update(client_key);
    sha.update(ws_guid);
    var digest: [20]u8 = undefined;
    sha.final(&digest);
    const Encoder = std.base64.standard.Encoder;
    _ = Encoder.encode(out_b64, &digest);
}

// Case-insensitive containment of `needle` in `hay`.
fn containsCi(hay: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (hay.len < needle.len) return false;
    var i: usize = 0;
    while (i + needle.len <= hay.len) : (i += 1) {
        var match = true;
        var j: usize = 0;
        while (j < needle.len) : (j += 1) {
            const a = std.ascii.toLower(hay[i + j]);
            const b = std.ascii.toLower(needle[j]);
            if (a != b) { match = false; break; }
        }
        if (match) return true;
    }
    return false;
}

// Read HTTP response headers up to and including "\r\n\r\n".
// Returns the raw header bytes (allocated, caller frees).
fn readHttpHeaders(gpa: Allocator, t: *Transport) ![]u8 {
    var list: std.ArrayList(u8) = .{};
    errdefer list.deinit(gpa);

    // Read one byte at a time (handshake is small; simplicity > throughput).
    const max_header_bytes: usize = 16 * 1024;
    while (list.items.len < max_header_bytes) {
        var b: [1]u8 = undefined;
        try t.readExact(&b);
        try list.append(gpa, b[0]);
        if (list.items.len >= 4) {
            const tail = list.items[list.items.len - 4 ..];
            if (std.mem.eql(u8, tail, "\r\n\r\n")) break;
        }
    } else {
        return error.HandshakeFailed;
    }
    return list.toOwnedSlice(gpa);
}

// Parse "Sec-WebSocket-Accept: <value>\r\n" from headers (case-insensitive
// header name). Returns slice into `headers`.
fn parseHeaderValue(headers: []const u8, name_lower: []const u8) ?[]const u8 {
    var line_start: usize = 0;
    var i: usize = 0;
    while (i + 1 < headers.len) : (i += 1) {
        if (headers[i] == '\r' and headers[i + 1] == '\n') {
            const line = headers[line_start..i];
            // Find ':'
            if (std.mem.indexOfScalar(u8, line, ':')) |colon| {
                const hname = line[0..colon];
                if (hname.len == name_lower.len) {
                    var ok = true;
                    var k: usize = 0;
                    while (k < hname.len) : (k += 1) {
                        if (std.ascii.toLower(hname[k]) != name_lower[k]) { ok = false; break; }
                    }
                    if (ok) {
                        var value = line[colon + 1 ..];
                        // Trim leading SP/HTAB
                        while (value.len > 0 and (value[0] == ' ' or value[0] == '\t')) value = value[1..];
                        // Trim trailing
                        while (value.len > 0 and (value[value.len - 1] == ' ' or value[value.len - 1] == '\t'))
                            value = value[0 .. value.len - 1];
                        return value;
                    }
                }
            }
            line_start = i + 2;
            i += 1;
        }
    }
    return null;
}

// ─── WsClient ────────────────────────────────────────────────────────────────

pub const WsClient = struct {
    allocator: Allocator,
    transport: Transport,
    /// Set to true after we observe a close frame from the peer.
    closed: bool = false,

    /// Connect, perform HTTP/1.1 Upgrade handshake, return a heap-allocated
    /// client. Caller owns the pointer and must call `close()` to free.
    pub fn connect(
        allocator: Allocator,
        host: []const u8,
        port: u16,
        path: []const u8,
        tls: bool,
    ) !*WsClient {
        const sock = try tcpConnect(allocator, host, port);
        errdefer sock.close();

        var transport: Transport = blk: {
            if (!tls) break :blk Transport{ .plain = sock };

            // Set up TLS over this socket. We must heap-allocate everything the
            // tls.Client borrows pointers into so they outlive this stack frame.
            const stream_reader = try allocator.create(std.net.Stream.Reader);
            errdefer allocator.destroy(stream_reader);
            const stream_writer = try allocator.create(std.net.Stream.Writer);
            errdefer allocator.destroy(stream_writer);
            const tls_client = try allocator.create(std.crypto.tls.Client);
            errdefer allocator.destroy(tls_client);

            // Buffers — sizes per std.crypto.tls.Client.min_buffer_len recommendation.
            const min_len = std.crypto.tls.Client.min_buffer_len;
            const sock_read_buf = try allocator.alloc(u8, min_len);
            errdefer allocator.free(sock_read_buf);
            const sock_write_buf = try allocator.alloc(u8, min_len);
            errdefer allocator.free(sock_write_buf);
            const tls_read_buf = try allocator.alloc(u8, min_len);
            errdefer allocator.free(tls_read_buf);
            const tls_write_buf = try allocator.alloc(u8, min_len);
            errdefer allocator.free(tls_write_buf);

            stream_reader.* = sock.reader(sock_read_buf);
            stream_writer.* = sock.writer(sock_write_buf);

            var ca_bundle: std.crypto.Certificate.Bundle = .{};
            errdefer ca_bundle.deinit(allocator);
            try ca_bundle.rescan(allocator);

            tls_client.* = try std.crypto.tls.Client.init(
                stream_reader.interface(),
                &stream_writer.interface,
                .{
                    .host = .{ .explicit = host },
                    .ca = .{ .bundle = ca_bundle },
                    .read_buffer = tls_read_buf,
                    .write_buffer = tls_write_buf,
                    // We do our own framing (RFC 6455) so we never let TLS
                    // truncation be silently turned into "EOF". Keep strict.
                    .allow_truncation_attacks = false,
                },
            );

            break :blk Transport{ .tls = .{
                .tls_client = tls_client,
                .stream_reader = stream_reader,
                .stream_writer = stream_writer,
                .tls_read_buf = tls_read_buf,
                .tls_write_buf = tls_write_buf,
                .sock_read_buf = sock_read_buf,
                .sock_write_buf = sock_write_buf,
                .ca_bundle = ca_bundle,
            } };
        };
        errdefer transport.close(allocator);

        // ── HTTP/1.1 Upgrade handshake ──────────────────────────────────
        var key_b64: [24]u8 = undefined;
        genWsKey(&key_b64);

        var req_buf: [1024]u8 = undefined;
        const req = try std.fmt.bufPrint(&req_buf,
            "GET {s} HTTP/1.1\r\n" ++
            "Host: {s}:{d}\r\n" ++
            "Upgrade: websocket\r\n" ++
            "Connection: Upgrade\r\n" ++
            "Sec-WebSocket-Key: {s}\r\n" ++
            "Sec-WebSocket-Version: 13\r\n" ++
            "\r\n",
            .{ path, host, port, key_b64[0..] },
        );
        try transport.writeAll(req);

        // Read response headers.
        const headers = try readHttpHeaders(allocator, &transport);
        defer allocator.free(headers);

        // Status line: must be "HTTP/1.1 101"
        if (headers.len < 12 or !std.mem.startsWith(u8, headers, "HTTP/1.")) {
            return error.HandshakeFailed;
        }
        const sp = std.mem.indexOfScalar(u8, headers, ' ') orelse return error.HandshakeFailed;
        if (sp + 4 > headers.len) return error.HandshakeFailed;
        if (!std.mem.startsWith(u8, headers[sp + 1 ..], "101")) {
            return error.HandshakeFailed;
        }

        // Required headers per RFC 6455 §4.1
        const upgrade_v = parseHeaderValue(headers, "upgrade") orelse return error.InvalidUpgrade;
        if (!containsCi(upgrade_v, "websocket")) return error.InvalidUpgrade;
        const conn_v = parseHeaderValue(headers, "connection") orelse return error.InvalidUpgrade;
        if (!containsCi(conn_v, "upgrade")) return error.InvalidUpgrade;

        // Verify Sec-WebSocket-Accept = base64(SHA1(key + GUID))
        const accept_v = parseHeaderValue(headers, "sec-websocket-accept") orelse
            return error.InvalidAcceptKey;
        var expected: [28]u8 = undefined;
        computeExpectedAccept(&key_b64, &expected);
        if (!std.mem.eql(u8, accept_v, expected[0..])) return error.InvalidAcceptKey;

        // ── All good — wrap & return ────────────────────────────────────
        const self = try allocator.create(WsClient);
        self.* = .{
            .allocator = allocator,
            .transport = transport,
        };
        return self;
    }

    /// Send a text message (opcode 0x1, FIN=1) with proper client masking.
    pub fn send(self: *WsClient, text: []const u8) !void {
        try self.sendFrame(0x1, text);
    }

    /// Send an unsolicited ping (opcode 0x9). Payload ≤ 125 bytes per RFC 6455.
    pub fn sendPing(self: *WsClient, payload: []const u8) !void {
        if (payload.len > 125) return error.MessageTooLarge;
        try self.sendFrame(0x9, payload);
    }

    /// Send pong (opcode 0xA), typically in reply to a peer ping.
    pub fn sendPong(self: *WsClient, payload: []const u8) !void {
        if (payload.len > 125) return error.MessageTooLarge;
        try self.sendFrame(0xA, payload);
    }

    /// Send close (opcode 0x8) and tear down the underlying transport.
    pub fn close(self: *WsClient) void {
        if (!self.closed) {
            // Best-effort close frame with status 1000.
            self.sendFrame(0x8, &[_]u8{ 0x03, 0xE8 }) catch {};
            self.closed = true;
        }
        self.transport.close(self.allocator);
        self.allocator.destroy(self);
    }

    /// Receive the next text/control message into `buf`. Returns:
    ///   - Message{.text, ...}  for a complete (FIN=1) text payload,
    ///   - Message{.ping, ...}  for a ping (caller may sendPong),
    ///   - Message{.pong, ...}  for a pong,
    ///   - Message{.close, ...} for a peer-initiated close,
    ///   - error.ConnectionClosed if the underlying transport ended.
    ///
    /// Multi-frame text messages are reassembled into `buf`. Returns
    /// error.BufferTooSmall if the assembled payload doesn't fit.
    pub fn recv(self: *WsClient, buf: []u8) !?Message {
        var assembled: usize = 0;
        var assembled_kind: ?MessageKind = null;

        while (true) {
            // ── Read 2-byte header ─────────────────────────────────────
            var hdr: [2]u8 = undefined;
            try self.transport.readExact(&hdr);

            const fin = (hdr[0] & 0x80) != 0;
            const rsv = hdr[0] & 0x70;
            if (rsv != 0) return error.InvalidFrame; // no extensions negotiated
            const opcode: u4 = @intCast(hdr[0] & 0x0F);

            const masked = (hdr[1] & 0x80) != 0;
            // Per RFC 6455, server-to-client frames MUST NOT be masked.
            if (masked) return error.InvalidFrame;

            var payload_len: u64 = @intCast(hdr[1] & 0x7F);
            if (payload_len == 126) {
                var ext: [2]u8 = undefined;
                try self.transport.readExact(&ext);
                payload_len = (@as(u64, ext[0]) << 8) | @as(u64, ext[1]);
            } else if (payload_len == 127) {
                var ext: [8]u8 = undefined;
                try self.transport.readExact(&ext);
                payload_len = 0;
                for (ext) |b| payload_len = (payload_len << 8) | @as(u64, b);
            }

            // Sanity cap (16 MiB) to avoid runaway allocations / DoS.
            if (payload_len > 16 * 1024 * 1024) return error.MessageTooLarge;

            switch (opcode) {
                // Continuation frame
                0x0 => {
                    if (assembled_kind == null) return error.InvalidFrame;
                    if (assembled + payload_len > buf.len) return error.BufferTooSmall;
                    if (payload_len > 0) {
                        try self.transport.readExact(buf[assembled .. assembled + @as(usize, @intCast(payload_len))]);
                    }
                    assembled += @intCast(payload_len);
                    if (fin) {
                        return Message{ .kind = assembled_kind.?, .data = buf[0..assembled] };
                    }
                    // else: keep reading the next continuation
                },

                // Text frame
                0x1 => {
                    if (assembled_kind != null) return error.InvalidFrame; // unexpected new data while continuing
                    if (payload_len > buf.len) return error.BufferTooSmall;
                    if (payload_len > 0) {
                        try self.transport.readExact(buf[0..@intCast(payload_len)]);
                    }
                    assembled = @intCast(payload_len);
                    assembled_kind = .text;
                    if (fin) return Message{ .kind = .text, .data = buf[0..assembled] };
                    // else: continuation frames will follow
                },

                // Binary frame — not supported (per spec for this client).
                0x2 => return error.UnsupportedOpcode,

                // Connection close
                0x8 => {
                    // Control frame — must be ≤125 and FIN=1 per RFC 6455 §5.5.
                    if (!fin or payload_len > 125) return error.InvalidFrame;
                    if (payload_len > buf.len) return error.BufferTooSmall;
                    if (payload_len > 0) {
                        try self.transport.readExact(buf[0..@intCast(payload_len)]);
                    }
                    self.closed = true;
                    // Echo close back (best-effort).
                    self.sendFrame(0x8, buf[0..@intCast(payload_len)]) catch {};
                    return Message{ .kind = .close, .data = buf[0..@intCast(payload_len)] };
                },

                // Ping
                0x9 => {
                    if (!fin or payload_len > 125) return error.InvalidFrame;
                    // Use a separate small stack buffer so we don't trample any
                    // partial text reassembly already in `buf`.
                    var ping_buf: [125]u8 = undefined;
                    if (payload_len > 0) {
                        try self.transport.readExact(ping_buf[0..@intCast(payload_len)]);
                    }
                    return Message{ .kind = .ping, .data = ping_buf[0..@intCast(payload_len)] };
                },

                // Pong
                0xA => {
                    if (!fin or payload_len > 125) return error.InvalidFrame;
                    var pong_buf: [125]u8 = undefined;
                    if (payload_len > 0) {
                        try self.transport.readExact(pong_buf[0..@intCast(payload_len)]);
                    }
                    return Message{ .kind = .pong, .data = pong_buf[0..@intCast(payload_len)] };
                },

                else => return error.UnsupportedOpcode,
            }
        }
    }

    // ── Internal: build & emit a single FIN=1 client frame ───────────────
    fn sendFrame(self: *WsClient, opcode: u8, payload: []const u8) !void {
        // Header: FIN=1 + opcode (1 byte) + MASK=1 + len/lenflag (1) + ext-len (0/2/8) + mask (4)
        var hdr: [14]u8 = undefined;
        var hdr_len: usize = 0;
        hdr[0] = 0x80 | (opcode & 0x0F);

        if (payload.len < 126) {
            hdr[1] = 0x80 | @as(u8, @intCast(payload.len));
            hdr_len = 2;
        } else if (payload.len <= 0xFFFF) {
            hdr[1] = 0x80 | 126;
            hdr[2] = @intCast((payload.len >> 8) & 0xFF);
            hdr[3] = @intCast(payload.len & 0xFF);
            hdr_len = 4;
        } else {
            hdr[1] = 0x80 | 127;
            const n: u64 = payload.len;
            hdr[2] = @intCast((n >> 56) & 0xFF);
            hdr[3] = @intCast((n >> 48) & 0xFF);
            hdr[4] = @intCast((n >> 40) & 0xFF);
            hdr[5] = @intCast((n >> 32) & 0xFF);
            hdr[6] = @intCast((n >> 24) & 0xFF);
            hdr[7] = @intCast((n >> 16) & 0xFF);
            hdr[8] = @intCast((n >> 8) & 0xFF);
            hdr[9] = @intCast(n & 0xFF);
            hdr_len = 10;
        }

        // Mask key (4 random bytes per frame).
        var mask: [4]u8 = undefined;
        std.crypto.random.bytes(&mask);
        hdr[hdr_len + 0] = mask[0];
        hdr[hdr_len + 1] = mask[1];
        hdr[hdr_len + 2] = mask[2];
        hdr[hdr_len + 3] = mask[3];
        hdr_len += 4;

        // Write header.
        try self.transport.writeAll(hdr[0..hdr_len]);

        // For very small payloads, mask in-place on the stack.
        if (payload.len <= 1024) {
            var stk: [1024]u8 = undefined;
            for (payload, 0..) |b, i| stk[i] = b ^ mask[i % 4];
            try self.transport.writeAll(stk[0..payload.len]);
        } else {
            // Larger payload — heap-allocate a scratch copy. (We can't mask in
            // place because `payload` is `[]const u8`.)
            const scratch = try self.allocator.alloc(u8, payload.len);
            defer self.allocator.free(scratch);
            for (payload, 0..) |b, i| scratch[i] = b ^ mask[i % 4];
            try self.transport.writeAll(scratch);
        }
    }
};

// ─── Self-tests ──────────────────────────────────────────────────────────────

test "computeExpectedAccept matches RFC 6455 example" {
    // RFC 6455 §1.3: key "dGhlIHNhbXBsZSBub25jZQ==" must yield
    // accept "s3pPLMBiTxaQ9kYGzzhZRbK+xOo=".
    var out: [28]u8 = undefined;
    computeExpectedAccept("dGhlIHNhbXBsZSBub25jZQ==", &out);
    try std.testing.expectEqualStrings("s3pPLMBiTxaQ9kYGzzhZRbK+xOo=", out[0..]);
}

test "containsCi finds substrings ignoring case" {
    try std.testing.expect(containsCi("Upgrade", "upgrade"));
    try std.testing.expect(containsCi("keep-alive, Upgrade", "upgrade"));
    try std.testing.expect(!containsCi("close", "upgrade"));
}

test "parseHeaderValue trims whitespace and is case-insensitive on name" {
    const hdrs = "HTTP/1.1 101 Switching Protocols\r\n" ++
        "Upgrade:   websocket  \r\n" ++
        "Connection: Upgrade\r\n" ++
        "Sec-WebSocket-Accept: abc123=\r\n" ++
        "\r\n";
    const v = parseHeaderValue(hdrs, "sec-websocket-accept") orelse return error.TestFailed;
    try std.testing.expectEqualStrings("abc123=", v);
    const u = parseHeaderValue(hdrs, "upgrade") orelse return error.TestFailed;
    try std.testing.expectEqualStrings("websocket", u);
}
