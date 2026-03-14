const std = @import("std");
const Allocator = std.mem.Allocator;

pub const StreamMode = enum {
    values, // Full state after each step
    updates, // Only node name + updates
    tasks, // Task start/finish with metadata
    debug, // Everything with step number + timestamp
    custom, // User-defined via node output

    pub fn toString(self: StreamMode) []const u8 {
        return @tagName(self);
    }

    pub fn fromString(s: []const u8) ?StreamMode {
        inline for (@typeInfo(StreamMode).@"enum".fields) |f| {
            if (std.mem.eql(u8, s, f.name)) return @enumFromInt(f.value);
        }
        return null;
    }
};

pub const SseEvent = struct {
    event_type: []const u8, // "state_update", "step_started", etc.
    data: []const u8, // JSON string
    mode: StreamMode = .updates, // default mode
};

/// Per-run event queue. Thread-safe via mutex.
pub const RunEventQueue = struct {
    events: std.ArrayListUnmanaged(SseEvent),
    alloc: Allocator,
    mutex: std.Thread.Mutex,
    closed: std.atomic.Value(bool),

    fn freeEvent(self: *RunEventQueue, event: SseEvent) void {
        self.alloc.free(event.event_type);
        self.alloc.free(event.data);
    }

    pub fn init(alloc: Allocator) RunEventQueue {
        return .{
            .events = .empty,
            .alloc = alloc,
            .mutex = .{},
            .closed = std.atomic.Value(bool).init(false),
        };
    }

    pub fn deinit(self: *RunEventQueue) void {
        for (self.events.items) |event| {
            self.freeEvent(event);
        }
        self.events.deinit(self.alloc);
    }

    /// Push an event to the queue. Thread-safe.
    pub fn push(self: *RunEventQueue, event: SseEvent) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        const event_type = self.alloc.dupe(u8, event.event_type) catch return;
        const data = self.alloc.dupe(u8, event.data) catch {
            self.alloc.free(event_type);
            return;
        };

        self.events.append(self.alloc, .{
            .event_type = event_type,
            .data = data,
            .mode = event.mode,
        }) catch {
            self.alloc.free(event_type);
            self.alloc.free(data);
        };
    }

    /// Drain all events from the queue. Returns a queue-allocator-owned slice.
    /// The caller must release it with `freeDrained`.
    pub fn drain(self: *RunEventQueue) []SseEvent {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.events.items.len == 0) return &.{};
        return self.events.toOwnedSlice(self.alloc) catch &.{};
    }

    pub fn freeDrained(self: *RunEventQueue, events: []SseEvent) void {
        if (events.len == 0) return;
        for (events) |event| {
            self.freeEvent(event);
        }
        self.alloc.free(events);
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

    const events = queue.drain();
    defer queue.freeDrained(events);
    try std.testing.expectEqual(@as(usize, 2), events.len);
    try std.testing.expectEqualStrings("step_started", events[0].event_type);
}

test "sse hub queue owns event payloads beyond source arena lifetime" {
    const alloc = std.testing.allocator;
    var hub = SseHub.init(alloc);
    defer hub.deinit();

    const queue = hub.getOrCreateQueue("run1");

    var arena = std.heap.ArenaAllocator.init(alloc);
    const arena_alloc = arena.allocator();

    const event_type = try arena_alloc.dupe(u8, "step.completed");
    const payload = try arena_alloc.dupe(u8, "{\"ok\":true}");
    queue.push(.{ .event_type = event_type, .data = payload });
    arena.deinit();

    const events = queue.drain();
    defer queue.freeDrained(events);

    try std.testing.expectEqual(@as(usize, 1), events.len);
    try std.testing.expectEqualStrings("step.completed", events[0].event_type);
    try std.testing.expectEqualStrings("{\"ok\":true}", events[0].data);
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

test "stream mode toString and fromString" {
    try std.testing.expectEqualStrings("values", StreamMode.values.toString());
    try std.testing.expectEqualStrings("updates", StreamMode.updates.toString());
    try std.testing.expectEqualStrings("tasks", StreamMode.tasks.toString());
    try std.testing.expectEqualStrings("debug", StreamMode.debug.toString());
    try std.testing.expectEqualStrings("custom", StreamMode.custom.toString());

    try std.testing.expectEqual(StreamMode.values, StreamMode.fromString("values").?);
    try std.testing.expectEqual(StreamMode.debug, StreamMode.fromString("debug").?);
    try std.testing.expect(StreamMode.fromString("invalid") == null);
}

test "sse event default mode is updates" {
    const ev = SseEvent{ .event_type = "test", .data = "{}" };
    try std.testing.expectEqual(StreamMode.updates, ev.mode);
}

test "sse event with explicit mode" {
    const ev = SseEvent{ .event_type = "values", .data = "{\"state\":{}}", .mode = .values };
    try std.testing.expectEqual(StreamMode.values, ev.mode);
    try std.testing.expectEqualStrings("values", ev.event_type);
}

test "sse hub broadcast with mode" {
    const alloc = std.testing.allocator;
    var hub = SseHub.init(alloc);
    defer hub.deinit();

    const queue = hub.getOrCreateQueue("run1");
    queue.push(.{ .event_type = "values", .data = "{\"full\":true}", .mode = .values });
    queue.push(.{ .event_type = "task_start", .data = "{}", .mode = .tasks });
    queue.push(.{ .event_type = "debug", .data = "{}", .mode = .debug });

    const events = queue.drain();
    defer queue.freeDrained(events);
    try std.testing.expectEqual(@as(usize, 3), events.len);
    try std.testing.expectEqual(StreamMode.values, events[0].mode);
    try std.testing.expectEqual(StreamMode.tasks, events[1].mode);
    try std.testing.expectEqual(StreamMode.debug, events[2].mode);
}
