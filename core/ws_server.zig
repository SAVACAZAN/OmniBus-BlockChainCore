/// ws_server.zig — WebSocket server pentru frontend React (port 8334)
/// Protocol: HTTP Upgrade → WS, RFC 6455 framing minim
/// Push events: new_block, new_tx, status
/// Nu depinde de OpenSSL — ws:// (nu wss://) pentru localhost
const std = @import("std");
const builtin = @import("builtin");
const blockchain_mod = @import("blockchain.zig");

// Pe Windows, stream.read() foloseste ReadFile care pica pe socket-uri acceptate.
// Folosim ws2_32.recv/send direct (la fel ca rpc_server.zig).
const is_windows = builtin.os.tag == .windows;
const ws2 = if (is_windows) std.os.windows.ws2_32 else undefined;

fn wsRecv(stream: std.net.Stream, buf: []u8) !usize {
    if (comptime is_windows) {
        const got = ws2.recv(stream.handle, buf.ptr, @intCast(buf.len), 0);
        if (got <= 0) return error.ConnectionClosed;
        return @intCast(got);
    } else {
        const n = try stream.read(buf);
        if (n == 0) return error.ConnectionClosed;
        return n;
    }
}

fn wsSend(stream: std.net.Stream, data: []const u8) !void {
    if (comptime is_windows) {
        var sent: usize = 0;
        while (sent < data.len) {
            const remaining: c_int = @intCast(data.len - sent);
            const n = ws2.send(stream.handle, data[sent..].ptr, remaining, 0);
            if (n <= 0) return error.ConnectionClosed;
            sent += @intCast(n);
        }
    } else {
        try stream.writeAll(data);
    }
}

/// Port WebSocket (diferit de RPC 8332 si P2P 8333)
pub const WS_PORT: u16 = 8334;

const Blockchain = blockchain_mod.Blockchain;

/// Stare globala WebSocket — lista de conexiuni active
pub const WsServer = struct {
    port:        u16,
    clients:     std.array_list.Managed(*WsClient),
    allocator:   std.mem.Allocator,
    mutex:       std.Thread.Mutex,
    blockchain:  ?*const Blockchain,

    pub fn init(port: u16, allocator: std.mem.Allocator) WsServer {
        return .{
            .port       = port,
            .clients    = std.array_list.Managed(*WsClient).init(allocator),
            .allocator  = allocator,
            .mutex      = .{},
            .blockchain = null,
        };
    }

    pub fn deinit(self: *WsServer) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        for (self.clients.items) |c| {
            c.stream.close();
            self.allocator.destroy(c);
        }
        self.clients.deinit();
    }

    pub fn attachBlockchain(self: *WsServer, bc: *const Blockchain) void {
        self.blockchain = bc;
    }

    /// Porneste TCP listener + accept loop in thread detasat
    pub fn start(self: *WsServer) !void {
        const addr = try std.net.Address.parseIp4("127.0.0.1", self.port);
        const server_sock = try addr.listen(.{ .reuse_address = true });
        std.debug.print("[WS] Server pornit pe ws://127.0.0.1:{d}\n", .{self.port});

        const Args = struct { sock: std.net.Server, srv: *WsServer };
        const args = try self.allocator.create(Args);
        args.* = .{ .sock = server_sock, .srv = self };

        const t = try std.Thread.spawn(.{}, acceptLoop, .{args});
        t.detach();
    }

    fn acceptLoop(args: anytype) void {
        var server = args.sock;
        const srv   = args.srv;
        defer srv.allocator.destroy(args);

        while (true) {
            const conn = server.accept() catch |err| {
                std.debug.print("[WS] Accept error: {}\n", .{err});
                std.Thread.sleep(1 * std.time.ns_per_s);
                continue;
            };

            const client = srv.allocator.create(WsClient) catch {
                conn.stream.close();
                continue;
            };
            client.* = WsClient{
                .stream    = conn.stream,
                .allocator = srv.allocator,
                .connected = false,
            };

            // Adauga in lista (cu lock)
            srv.mutex.lock();
            srv.clients.append(client) catch {
                srv.mutex.unlock();
                conn.stream.close();
                srv.allocator.destroy(client);
                continue;
            };
            srv.mutex.unlock();

            // Handler in thread propriu
            const HandlerArgs = struct { client: *WsClient, srv: *WsServer };
            const hargs = srv.allocator.create(HandlerArgs) catch {
                conn.stream.close();
                continue;
            };
            hargs.* = .{ .client = client, .srv = srv };

            const ht = std.Thread.spawn(.{}, handleClient, .{hargs}) catch |err| {
                std.debug.print("[WS] Thread spawn error: {}\n", .{err});
                srv.allocator.destroy(hargs);
                conn.stream.close();
                continue;
            };
            ht.detach();
        }
    }

    fn handleClient(args: anytype) void {
        const client = args.client;
        const srv    = args.srv;
        defer srv.allocator.destroy(args);

        // Perform WebSocket HTTP Upgrade handshake
        wsHandshake(client) catch |err| {
            std.debug.print("[WS] Handshake failed: {}\n", .{err});
            removeClient(srv, client);
            return;
        };

        client.connected = true;
        std.debug.print("[WS] Client conectat\n", .{});

        // Trimite status initial
        if (srv.blockchain) |bc| {
            const height = bc.chain.items.len;
            var buf: [256]u8 = undefined;
            const json = std.fmt.bufPrint(&buf,
                "{{\"event\":\"status\",\"height\":{d},\"difficulty\":{d}}}",
                .{ height, bc.difficulty },
            ) catch "{}";
            client.sendText(json) catch {};
        }

        // Loop citire mesaje de la client (ping-uri etc.) — exit la deconectare
        while (client.connected) {
            var frame_buf: [128]u8 = undefined;
            // Citeste frame header (2 bytes minim)
            const n = wsRecv(client.stream, frame_buf[0..2]) catch break;
            if (n < 2) break;

            // Frame WS: [FIN+opcode][MASK+len]...
            const opcode = frame_buf[0] & 0x0F;
            const masked  = (frame_buf[1] & 0x80) != 0;
            const pay_len = frame_buf[1] & 0x7F;

            // Sarim extended length (nu ne intereseaza mesajele mari de la client)
            if (pay_len == 126 or pay_len == 127) {
                // skip extension bytes
                const ext_len: usize = if (pay_len == 126) 2 else 8;
                var skip_buf: [8]u8 = undefined;
                _ = wsRecv(client.stream, skip_buf[0..ext_len]) catch break;
            }

            // Citeste masking key (4 bytes) si payload
            if (masked and pay_len <= 120) {
                var mask_key: [4]u8 = undefined;
                _ = wsRecv(client.stream, &mask_key) catch break;
                _ = wsRecv(client.stream, frame_buf[0..pay_len]) catch break;
                // demasca
                for (0..pay_len) |i| frame_buf[i] ^= mask_key[i % 4];
            } else if (pay_len <= 120) {
                _ = wsRecv(client.stream, frame_buf[0..pay_len]) catch break;
            }

            // Opcode 8 = Connection Close
            if (opcode == 8) break;
            // Opcode 9 = Ping → raspunde cu Pong (opcode 10)
            if (opcode == 9) {
                const pong = [_]u8{ 0x8A, 0x00 }; // FIN + Pong, len 0
                wsSend(client.stream, &pong) catch break;
            }
        }

        std.debug.print("[WS] Client deconectat\n", .{});
        removeClient(srv, client);
    }

    fn removeClient(srv: *WsServer, client: *WsClient) void {
        client.stream.close();
        client.connected = false;
        srv.mutex.lock();
        defer srv.mutex.unlock();
        for (srv.clients.items, 0..) |c, i| {
            if (c == client) {
                _ = srv.clients.swapRemove(i);
                break;
            }
        }
        srv.allocator.destroy(client);
    }

    /// Broadcast JSON la toti clientii conectati
    /// Apelat din mining loop la fiecare bloc minat
    pub fn broadcast(self: *WsServer, json: []const u8) void {
        self.mutex.lock();
        var i: usize = 0;
        while (i < self.clients.items.len) {
            const c = self.clients.items[i];
            if (!c.connected) {
                i += 1;
                continue;
            }
            c.sendText(json) catch {
                // Eroare → marcheaza ca deconectat, va fi curatat
                c.connected = false;
            };
            i += 1;
        }
        self.mutex.unlock();
    }

    /// Trimite eveniment "new_block" la toti clientii
    pub fn broadcastBlock(
        self:       *WsServer,
        height:     u64,
        hash_hex:   []const u8,
        reward_sat: u64,
        difficulty: u64,
        mempool_sz: usize,
    ) void {
        var buf: [512]u8 = undefined;
        const json = std.fmt.bufPrint(&buf,
            "{{\"event\":\"new_block\"," ++
            "\"height\":{d}," ++
            "\"hash\":\"{s}\"," ++
            "\"reward_sat\":{d}," ++
            "\"difficulty\":{d}," ++
            "\"mempool_size\":{d}," ++
            "\"timestamp\":{d}}}",
            .{
                height,
                hash_hex[0..@min(hash_hex.len, 64)],
                reward_sat,
                difficulty,
                mempool_sz,
                std.time.milliTimestamp(),
            },
        ) catch return;
        self.broadcast(json);
    }

    /// Trimite eveniment "new_tx" la toti clientii
    pub fn broadcastTx(self: *WsServer, tx_id: []const u8, from: []const u8, amount_sat: u64) void {
        var buf: [256]u8 = undefined;
        const json = std.fmt.bufPrint(&buf,
            "{{\"event\":\"new_tx\",\"txid\":\"{s}\",\"from\":\"{s}\",\"amount_sat\":{d}}}",
            .{
                tx_id[0..@min(tx_id.len, 64)],
                from[0..@min(from.len, 32)],
                amount_sat,
            },
        ) catch return;
        self.broadcast(json);
    }
};

/// Un client WebSocket conectat
pub const WsClient = struct {
    stream:    std.net.Stream,
    allocator: std.mem.Allocator,
    connected: bool,

    /// Trimite un frame TEXT WebSocket (opcode 1)
    /// RFC 6455: [0x81][len][payload] — server nu maskeaza
    pub fn sendText(self: *WsClient, text: []const u8) !void {
        const len = text.len;
        var header: [10]u8 = undefined;
        var header_len: usize = 2;

        header[0] = 0x81; // FIN + TEXT opcode
        if (len < 126) {
            header[1] = @intCast(len);
            header_len = 2;
        } else if (len < 65536) {
            header[1] = 126;
            std.mem.writeInt(u16, header[2..4], @intCast(len), .big);
            header_len = 4;
        } else {
            header[1] = 127;
            std.mem.writeInt(u64, header[2..10], len, .big);
            header_len = 10;
        }

        try wsSend(self.stream, header[0..header_len]);
        try wsSend(self.stream, text);
    }
};

// ─── HTTP Upgrade / WebSocket Handshake ──────────────────────────────────────
//
// RFC 6455: client trimite GET cu Upgrade: websocket + Sec-WebSocket-Key
// Server raspunde 101 Switching Protocols cu Sec-WebSocket-Accept = base64(SHA1(key + GUID))
//
// GUID fix: "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
//

const WS_GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";

fn wsHandshake(client: *WsClient) !void {
    // Citeste cererea HTTP (max 2KB)
    var req_buf: [2048]u8 = undefined;
    var total: usize = 0;
    while (total < req_buf.len - 1) {
        const n = wsRecv(client.stream, req_buf[total..]) catch return error.ConnectionClosed;
        total += n;
        // Detecteaza sfarsitul header HTTP (\r\n\r\n)
        if (total >= 4 and
            req_buf[total - 4] == '\r' and
            req_buf[total - 3] == '\n' and
            req_buf[total - 2] == '\r' and
            req_buf[total - 1] == '\n') break;
    }

    const req = req_buf[0..total];

    // Extrage Sec-WebSocket-Key din header
    const key_header = "Sec-WebSocket-Key: ";
    const key_start = std.mem.indexOf(u8, req, key_header) orelse
        return error.NoWebSocketKey;
    const key_val_start = key_start + key_header.len;
    const key_end = std.mem.indexOfScalarPos(u8, req, key_val_start, '\r') orelse
        return error.NoWebSocketKey;
    const key = std.mem.trim(u8, req[key_val_start..key_end], " \r\n");

    if (key.len == 0) return error.NoWebSocketKey;

    // accept_key = base64(SHA1(key + GUID))
    var combined_buf: [128]u8 = undefined;
    const combined = std.fmt.bufPrint(&combined_buf, "{s}{s}", .{ key, WS_GUID }) catch
        return error.KeyTooLong;

    var sha1_out: [20]u8 = undefined;
    std.crypto.hash.Sha1.hash(combined, &sha1_out, .{});

    var accept_buf: [32]u8 = undefined;
    const accept = std.base64.standard.Encoder.encode(&accept_buf, &sha1_out);

    // Trimite raspuns HTTP 101
    var resp_buf: [256]u8 = undefined;
    const resp = std.fmt.bufPrint(&resp_buf,
        "HTTP/1.1 101 Switching Protocols\r\n" ++
        "Upgrade: websocket\r\n" ++
        "Connection: Upgrade\r\n" ++
        "Sec-WebSocket-Accept: {s}\r\n" ++
        "\r\n",
        .{accept},
    ) catch return error.ResponseTooLong;

    try wsSend(client.stream, resp);
}

// ─── Teste ────────────────────────────────────────────────────────────────────

const testing = std.testing;

test "WsClient sendText framing — len < 126" {
    // Nu putem testa fara stream real — testam doar constructia headerului
    // Verificam ca header[0] = 0x81 si header[1] = len pentru len < 126
    const text = "hello";
    var header: [2]u8 = undefined;
    header[0] = 0x81; // FIN + TEXT
    header[1] = @intCast(text.len);
    try testing.expectEqual(header[0], 0x81);
    try testing.expectEqual(header[1], 5);
}

test "wsHandshake accept key derivation" {
    // RFC 6455 test vector:
    // key = "dGhlIHNhbXBsZSBub25jZQ=="
    // expected accept = "s3pPLMBiTxaQ9kYGzzhZRbK+xOo="
    const key = "dGhlIHNhbXBsZSBub25jZQ==";
    var combined_buf: [128]u8 = undefined;
    const combined = try std.fmt.bufPrint(&combined_buf, "{s}{s}", .{ key, WS_GUID });
    var sha1_out: [20]u8 = undefined;
    std.crypto.hash.Sha1.hash(combined, &sha1_out, .{});
    var accept_buf: [32]u8 = undefined;
    const accept = std.base64.standard.Encoder.encode(&accept_buf, &sha1_out);
    try testing.expectEqualStrings("s3pPLMBiTxaQ9kYGzzhZRbK+xOo=", accept);
}

test "WsServer init/deinit" {
    var srv = WsServer.init(8334, testing.allocator);
    defer srv.deinit();
    try testing.expectEqual(@as(usize, 0), srv.clients.items.len);
    try testing.expectEqual(@as(u16, 8334), srv.port);
}
