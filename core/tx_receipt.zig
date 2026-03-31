const std = @import("std");

/// Transaction Receipts & Event Logs
///
/// Dupa fiecare TX procesat, se genereaza un receipt cu:
///   - Status (success/failure)
///   - Gas/fee used
///   - Event logs (indexed topics + data)
///
/// Ca Ethereum: receipt trie cu Bloom filter pentru fast log queries
/// Ca Solana: transaction logs cu program invocations
/// Ca EGLD: smart contract events

/// Maximum events per transaction
pub const MAX_EVENTS: usize = 16;
/// Maximum topics per event
pub const MAX_TOPICS: usize = 4;
/// Maximum data bytes per event
pub const MAX_EVENT_DATA: usize = 256;

/// Transaction execution status
pub const TxStatus = enum(u8) {
    success = 1,
    failure = 0,
    pending = 2,
};

/// Event log entry (ca Ethereum LOG0-LOG4)
pub const EventLog = struct {
    /// Event signature hash (topic[0])
    event_type: [32]u8,
    /// Indexed topics for filtering (up to 3 additional)
    topics: [MAX_TOPICS][32]u8,
    topic_count: u8,
    /// Non-indexed event data
    data: [MAX_EVENT_DATA]u8,
    data_len: u16,
    /// Block height where event occurred
    block_height: u64,
    /// Transaction index within block
    tx_index: u32,

    pub fn init(event_type: [32]u8, block_height: u64, tx_index: u32) EventLog {
        return .{
            .event_type = event_type,
            .topics = [_][32]u8{[_]u8{0} ** 32} ** MAX_TOPICS,
            .topic_count = 0,
            .data = [_]u8{0} ** MAX_EVENT_DATA,
            .data_len = 0,
            .block_height = block_height,
            .tx_index = tx_index,
        };
    }

    /// Add an indexed topic
    pub fn addTopic(self: *EventLog, topic: [32]u8) !void {
        if (self.topic_count >= MAX_TOPICS) return error.TooManyTopics;
        self.topics[self.topic_count] = topic;
        self.topic_count += 1;
    }

    /// Set event data
    pub fn setData(self: *EventLog, data_bytes: []const u8) !void {
        if (data_bytes.len > MAX_EVENT_DATA) return error.DataTooLarge;
        @memcpy(self.data[0..data_bytes.len], data_bytes);
        self.data_len = @intCast(data_bytes.len);
    }
};

/// Transaction Receipt
pub const TxReceipt = struct {
    /// Transaction hash
    tx_hash: [32]u8,
    /// Execution status
    status: TxStatus,
    /// Block height
    block_height: u64,
    /// Transaction index in block
    tx_index: u32,
    /// Fee paid in SAT
    fee_paid: u64,
    /// Cumulative fee in block (for position calculation)
    cumulative_fee: u64,
    /// From address hash
    from_hash: [32]u8,
    /// To address hash
    to_hash: [32]u8,
    /// Amount transferred
    amount: u64,
    /// Event logs
    events: [MAX_EVENTS]EventLog,
    event_count: u8,

    pub fn init(tx_hash: [32]u8, block_height: u64, tx_index: u32) TxReceipt {
        return .{
            .tx_hash = tx_hash,
            .status = .pending,
            .block_height = block_height,
            .tx_index = tx_index,
            .fee_paid = 0,
            .cumulative_fee = 0,
            .from_hash = [_]u8{0} ** 32,
            .to_hash = [_]u8{0} ** 32,
            .amount = 0,
            .events = undefined,
            .event_count = 0,
        };
    }

    /// Mark as successful
    pub fn success(self: *TxReceipt, fee: u64) void {
        self.status = .success;
        self.fee_paid = fee;
    }

    /// Mark as failed
    pub fn fail(self: *TxReceipt) void {
        self.status = .failure;
    }

    /// Add event log
    pub fn addEvent(self: *TxReceipt, event: EventLog) !void {
        if (self.event_count >= MAX_EVENTS) return error.TooManyEvents;
        self.events[self.event_count] = event;
        self.event_count += 1;
    }

    /// Compute receipt hash (for receipt trie/merkle)
    pub fn hash(self: *const TxReceipt) [32]u8 {
        var hasher = std.crypto.hash.sha2.Sha256.init(.{});
        hasher.update(&self.tx_hash);
        hasher.update(&[_]u8{@intFromEnum(self.status)});
        var buf: [8]u8 = undefined;
        std.mem.writeInt(u64, &buf, self.fee_paid, .little);
        hasher.update(&buf);
        std.mem.writeInt(u64, &buf, self.block_height, .little);
        hasher.update(&buf);
        var result: [32]u8 = undefined;
        hasher.final(&result);
        return result;
    }
};

/// Standard event type IDs (fixed, deterministic)
pub const EVENT_TRANSFER: [32]u8 = [_]u8{ 0xA9, 0x05, 0x9C, 0xBB } ++ [_]u8{0} ** 28;
pub const EVENT_APPROVAL: [32]u8 = [_]u8{ 0x8C, 0x5B, 0xE1, 0xE5 } ++ [_]u8{0} ** 28;
pub const EVENT_STAKE:    [32]u8 = [_]u8{ 0xE1, 0xFF, 0xFC, 0xC4 } ++ [_]u8{0} ** 28;
pub const EVENT_SLASH:    [32]u8 = [_]u8{ 0x3B, 0x88, 0x1E, 0x5D } ++ [_]u8{0} ** 28;

// ─── Tests ──────────────────────────────────────────────────────────────────

const testing = std.testing;

test "TxReceipt — init and success" {
    const tx_hash = [_]u8{0xAA} ** 32;
    var receipt = TxReceipt.init(tx_hash, 100, 0);
    try testing.expectEqual(TxStatus.pending, receipt.status);
    receipt.success(50);
    try testing.expectEqual(TxStatus.success, receipt.status);
    try testing.expectEqual(@as(u64, 50), receipt.fee_paid);
}

test "TxReceipt — fail" {
    var receipt = TxReceipt.init([_]u8{0xBB} ** 32, 200, 1);
    receipt.fail();
    try testing.expectEqual(TxStatus.failure, receipt.status);
}

test "TxReceipt — add events" {
    var receipt = TxReceipt.init([_]u8{0xCC} ** 32, 300, 0);
    var event = EventLog.init(EVENT_TRANSFER, 300, 0);
    try event.addTopic([_]u8{0x11} ** 32);
    try event.setData("100 OMNI transferred");
    try receipt.addEvent(event);
    try testing.expectEqual(@as(u8, 1), receipt.event_count);
}

test "TxReceipt — hash is deterministic" {
    var r1 = TxReceipt.init([_]u8{0xDD} ** 32, 400, 0);
    r1.success(10);
    var r2 = TxReceipt.init([_]u8{0xDD} ** 32, 400, 0);
    r2.success(10);
    try testing.expectEqualSlices(u8, &r1.hash(), &r2.hash());
}

test "TxReceipt — different TX hash -> different receipt hash" {
    var r1 = TxReceipt.init([_]u8{0xEE} ** 32, 500, 0);
    r1.success(1);
    var r2 = TxReceipt.init([_]u8{0xFF} ** 32, 500, 0);
    r2.success(1);
    try testing.expect(!std.mem.eql(u8, &r1.hash(), &r2.hash()));
}

test "EventLog — topics and data" {
    var event = EventLog.init(EVENT_STAKE, 100, 0);
    try event.addTopic([_]u8{0x01} ** 32);
    try event.addTopic([_]u8{0x02} ** 32);
    try event.setData("staked 100 OMNI");
    try testing.expectEqual(@as(u8, 2), event.topic_count);
    try testing.expectEqual(@as(u16, 15), event.data_len);
}

test "EventLog — max topics" {
    var event = EventLog.init(EVENT_TRANSFER, 100, 0);
    try event.addTopic([_]u8{0x01} ** 32);
    try event.addTopic([_]u8{0x02} ** 32);
    try event.addTopic([_]u8{0x03} ** 32);
    try event.addTopic([_]u8{0x04} ** 32);
    try testing.expectError(error.TooManyTopics, event.addTopic([_]u8{0x05} ** 32));
}

test "Standard event types are distinct" {
    try testing.expect(!std.mem.eql(u8, &EVENT_TRANSFER, &EVENT_APPROVAL));
    try testing.expect(!std.mem.eql(u8, &EVENT_TRANSFER, &EVENT_STAKE));
    try testing.expect(!std.mem.eql(u8, &EVENT_STAKE, &EVENT_SLASH));
}
