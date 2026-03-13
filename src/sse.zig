const std = @import("std");
const Allocator = std.mem.Allocator;

pub const SseEvent = struct {
    event_type: []const u8, // "state_update", "step_started", etc.
    data: []const u8, // JSON string
};

/// Per-run event queue. Thread-safe via mutex.
pub const RunEventQueue = struct {
    events: std.ArrayListUnmanaged(SseEvent),
    alloc: Allocator,
    mutex: std.Thread.Mutex,
    closed: std.atomic.Value(bool),

    pub fn init(alloc: Allocator) RunEventQueue {
        return .{
            .events = .empty,
            .alloc = alloc,
            .mutex = .{},
            .closed = std.atomic.Value(bool).init(false),
        };
    }

    pub fn deinit(self: *RunEventQueue) void {
        self.events.deinit(self.alloc);
    }

    /// Push an event to the queue. Thread-safe.
    pub fn push(self: *RunEventQueue, event: SseEvent) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.events.append(self.alloc, event) catch {};
    }

    /// Drain all events from the queue. Returns owned slice. Thread-safe.
    pub fn drain(self: *RunEventQueue, alloc: Allocator) []SseEvent {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.events.items.len == 0) return &.{};
        const items = alloc.dupe(SseEvent, self.events.items) catch return &.{};
        self.events.clearRetainingCapacity();
        return items;
    }

    /// Mark queue as closed (run completed/cancelled).
    pub fn close(self: *RunEventQueue) void {
        self.closed.store(true, .release);
    }

    pub fn isClosed(self: *RunEventQueue) bool {
        return self.closed.load(.acquire);
    }
};

/// Central hub managing per-run event queues.
pub const SseHub = struct {
    queues: std.StringHashMap(*RunEventQueue),
    mutex: std.Thread.Mutex,
    alloc: Allocator,

    pub fn init(alloc: Allocator) SseHub {
        return .{
            .queues = std.StringHashMap(*RunEventQueue).init(alloc),
            .mutex = .{},
            .alloc = alloc,
        };
    }

    pub fn deinit(self: *SseHub) void {
        var it = self.queues.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.*.deinit();
            self.alloc.destroy(entry.value_ptr.*);
            self.alloc.free(entry.key_ptr.*);
        }
        self.queues.deinit();
    }

    /// Get or create queue for a run.
    pub fn getOrCreateQueue(self: *SseHub, run_id: []const u8) *RunEventQueue {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.queues.get(run_id)) |q| return q;
        const queue = self.alloc.create(RunEventQueue) catch @panic("OOM: failed to allocate RunEventQueue");
        queue.* = RunEventQueue.init(self.alloc);
        const id_copy = self.alloc.dupe(u8, run_id) catch @panic("OOM: failed to duplicate run_id");
        self.queues.put(id_copy, queue) catch @panic("OOM: failed to insert queue into map");
        return queue;
    }

    /// Broadcast event to a run's queue.
    pub fn broadcast(self: *SseHub, run_id: []const u8, event: SseEvent) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.queues.get(run_id)) |queue| {
            queue.push(event);
        }
        // If no queue exists, event is silently dropped (no listeners)
    }

    /// Close and remove queue when run completes.
    pub fn removeQueue(self: *SseHub, run_id: []const u8) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.queues.fetchRemove(run_id)) |entry| {
            entry.value.close();
            entry.value.deinit();
            self.alloc.destroy(entry.value);
            self.alloc.free(entry.key);
        }
    }
};

// ── Tests ─────────────────────────────────────────────────────────────

test "sse hub broadcast and drain" {
    const alloc = std.testing.allocator;
    var hub = SseHub.init(alloc);
    defer hub.deinit();

    const queue = hub.getOrCreateQueue("run1");
    queue.push(.{ .event_type = "step_started", .data = "{}" });
    queue.push(.{ .event_type = "step_completed", .data = "{}" });

    const events = queue.drain(alloc);
    defer alloc.free(events);
    try std.testing.expectEqual(@as(usize, 2), events.len);
    try std.testing.expectEqualStrings("step_started", events[0].event_type);
}

test "sse hub broadcast to non-existent queue is silent" {
    const alloc = std.testing.allocator;
    var hub = SseHub.init(alloc);
    defer hub.deinit();

    // Should not crash
    hub.broadcast("nonexistent", .{ .event_type = "test", .data = "{}" });
}

test "sse hub remove queue" {
    const alloc = std.testing.allocator;
    var hub = SseHub.init(alloc);
    defer hub.deinit();

    _ = hub.getOrCreateQueue("run1");
    hub.removeQueue("run1");
    // Queue should be gone
    try std.testing.expectEqual(@as(usize, 0), hub.queues.count());
}

test "sse queue close" {
    const alloc = std.testing.allocator;
    var queue = RunEventQueue.init(alloc);
    defer queue.deinit();

    try std.testing.expect(!queue.isClosed());
    queue.close();
    try std.testing.expect(queue.isClosed());
}
