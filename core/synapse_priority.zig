/// synapse_priority.zig — Synapse Priority Scheduler
///
/// Synapse = scheduler-ul de prioritati intre OS-uri si module.
/// Inspirat din arhitectura neuronala: fiecare modul e un "neuron",
/// conexiunile intre ele sunt "sinapse" cu prioritati diferite.
///
/// Prioritati:
///   P0 = ExecutionOS (trade <40µs) — REAL-TIME, nu poate fi intrerupt
///   P1 = RiskOS (circuit breaker)  — HIGH, poate opri ExecutionOS
///   P2 = ValidationOS (SPARK)      — HIGH, ruleaza in paralel
///   P3 = StrategyOS                — NORMAL
///   P4 = BlockchainOS              — NORMAL
///   P5 = InfraOS                   — LOW
///   P6 = GovernanceOS              — BACKGROUND
const std = @import("std");
const os_mode = @import("os_mode.zig");

pub const OsMode = os_mode.OsMode;

// --- TIPURI ------------------------------------------------------------------

pub const Priority = enum(u8) {
    realtime   = 0,   // P0: ExecutionOS — nu poate fi intrerupt
    high       = 1,   // P1: RiskOS, ValidationOS
    normal     = 2,   // P3: StrategyOS, BlockchainOS
    low        = 3,   // P5: InfraOS
    background = 4,   // P6: GovernanceOS

    pub fn canPreempt(self: Priority, other: Priority) bool {
        return @intFromEnum(self) < @intFromEnum(other);
    }
};

/// Mapare OsMode → Priority
pub fn modePriority(mode: OsMode) Priority {
    return switch (mode) {
        .execution  => .realtime,
        .risk       => .high,
        .validation => .high,
        .strategy   => .normal,
        .blockchain => .normal,
        .infra      => .low,
        .governance => .background,
    };
}

/// O sarcina (task) in coada de prioritati
pub const SynapseTask = struct {
    task_id:   u64,
    mode:      OsMode,
    priority:  Priority,
    /// Timestamp la care a intrat in coada (block number)
    queued_at: u64,
    /// Deadline (block la care trebuie executat, 0 = no deadline)
    deadline:  u64,
    /// Descriere pentru debug
    label:     [32]u8,
    label_len: u8,

    pub fn isOverdue(self: *const SynapseTask, current_block: u64) bool {
        if (self.deadline == 0) return false;
        return current_block > self.deadline;
    }
};

// --- SYNAPSE SCHEDULER -------------------------------------------------------

pub const MAX_TASKS: usize = 256;

pub const SynapseScheduler = struct {
    tasks:       [MAX_TASKS]SynapseTask,
    task_count:  usize,
    next_task_id: u64,
    executed_count: u64,
    preemptions:    u64,

    pub fn init() SynapseScheduler {
        return SynapseScheduler{
            .tasks          = undefined,
            .task_count     = 0,
            .next_task_id   = 1,
            .executed_count = 0,
            .preemptions    = 0,
        };
    }

    /// Adauga o sarcina in coada
    pub fn enqueue(self: *SynapseScheduler,
                   mode:     OsMode,
                   label:    []const u8,
                   queued_at: u64,
                   deadline:  u64) !u64 {
        if (self.task_count >= MAX_TASKS) return error.QueueFull;

        var lbl: [32]u8 = @splat(0);
        const n = @min(label.len, 32);
        @memcpy(lbl[0..n], label[0..n]);

        const task = SynapseTask{
            .task_id   = self.next_task_id,
            .mode      = mode,
            .priority  = modePriority(mode),
            .queued_at = queued_at,
            .deadline  = deadline,
            .label     = lbl,
            .label_len = @intCast(n),
        };

        self.tasks[self.task_count] = task;
        self.task_count += 1;
        self.next_task_id += 1;

        return task.task_id;
    }

    /// Returneaza urmatoarea sarcina de executat (cea cu prioritatea cea mai mare)
    /// In caz de egalitate: FIFO (task_id mai mic = primul intrat)
    pub fn dequeue(self: *SynapseScheduler) ?SynapseTask {
        if (self.task_count == 0) return null;

        var best_idx: usize = 0;
        for (1..self.task_count) |i| {
            const cur_p = @intFromEnum(self.tasks[i].priority);
            const best_p = @intFromEnum(self.tasks[best_idx].priority);
            if (cur_p < best_p) {
                // Verificam daca noul task preempteaza
                if (self.tasks[i].priority.canPreempt(self.tasks[best_idx].priority)) {
                    self.preemptions += 1;
                }
                best_idx = i;
            } else if (cur_p == best_p and self.tasks[i].task_id < self.tasks[best_idx].task_id) {
                best_idx = i;
            }
        }

        const task = self.tasks[best_idx];

        // Elimina din coada (swap cu ultimul)
        self.tasks[best_idx] = self.tasks[self.task_count - 1];
        self.task_count -= 1;
        self.executed_count += 1;

        return task;
    }

    /// Verifica daca exista sarcini cu deadline depasit
    pub fn overdueCount(self: *const SynapseScheduler, current_block: u64) usize {
        var n: usize = 0;
        for (0..self.task_count) |i| {
            if (self.tasks[i].isOverdue(current_block)) n += 1;
        }
        return n;
    }

    pub fn isEmpty(self: *const SynapseScheduler) bool {
        return self.task_count == 0;
    }

    pub fn printStatus(self: *const SynapseScheduler) void {
        std.debug.print("[SYNAPSE] Queue: {d} | Executed: {d} | Preemptions: {d}\n",
            .{ self.task_count, self.executed_count, self.preemptions });
    }
};

// --- TESTE -------------------------------------------------------------------
const testing = std.testing;

test "Priority — canPreempt corect" {
    try testing.expect(Priority.realtime.canPreempt(.high));
    try testing.expect(Priority.high.canPreempt(.normal));
    try testing.expect(!Priority.normal.canPreempt(.high));
    try testing.expect(!Priority.background.canPreempt(.realtime));
}

test "modePriority — execution = realtime" {
    try testing.expectEqual(Priority.realtime, modePriority(.execution));
    try testing.expectEqual(Priority.high,     modePriority(.risk));
    try testing.expectEqual(Priority.background, modePriority(.governance));
}

test "SynapseScheduler — init gol" {
    const s = SynapseScheduler.init();
    try testing.expect(s.isEmpty());
    try testing.expectEqual(@as(usize, 0), s.task_count);
}

test "SynapseScheduler — enqueue si dequeue" {
    var s = SynapseScheduler.init();
    _ = try s.enqueue(.strategy, "trade_signal", 100, 0);
    try testing.expect(!s.isEmpty());
    const t = s.dequeue();
    try testing.expect(t != null);
    try testing.expect(s.isEmpty());
}

test "SynapseScheduler — prioritate mai mare iese prima" {
    var s = SynapseScheduler.init();
    _ = try s.enqueue(.governance, "dao_vote", 100, 0);    // background
    _ = try s.enqueue(.execution,  "trade_exec", 101, 0);  // realtime
    _ = try s.enqueue(.strategy,   "grid_check", 102, 0);  // normal

    const first = s.dequeue().?;
    try testing.expectEqual(OsMode.execution, first.mode);

    const second = s.dequeue().?;
    try testing.expectEqual(OsMode.strategy, second.mode);

    const third = s.dequeue().?;
    try testing.expectEqual(OsMode.governance, third.mode);
}

test "SynapseScheduler — FIFO la prioritate egala" {
    var s = SynapseScheduler.init();
    _ = try s.enqueue(.strategy, "first",  100, 0);
    _ = try s.enqueue(.strategy, "second", 101, 0);
    _ = try s.enqueue(.strategy, "third",  102, 0);

    const t1 = s.dequeue().?;
    const t2 = s.dequeue().?;
    try testing.expect(t1.task_id < t2.task_id);
}

test "SynapseScheduler — overdueCount" {
    var s = SynapseScheduler.init();
    _ = try s.enqueue(.execution, "urgent",  100, 105);  // deadline 105
    _ = try s.enqueue(.strategy,  "normal",  100, 200);  // deadline 200
    _ = try s.enqueue(.infra,     "nodeadl", 100, 0);    // no deadline

    try testing.expectEqual(@as(usize, 0), s.overdueCount(104));
    try testing.expectEqual(@as(usize, 1), s.overdueCount(110));
}

test "SynapseScheduler — coada plina returneaza eroare" {
    var s = SynapseScheduler.init();
    for (0..MAX_TASKS) |_| {
        _ = try s.enqueue(.infra, "fill", 0, 0);
    }
    try testing.expectError(error.QueueFull,
        s.enqueue(.infra, "overflow", 0, 0));
}
