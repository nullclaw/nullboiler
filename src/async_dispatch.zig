const std = @import("std");

// ── Types ─────────────────────────────────────────────────────────────

pub const AsyncResponse = struct {
    correlation_id: []const u8,
    output: []const u8,
    success: bool,
    error_text: ?[]const u8,
    timestamp_ms: i64,
};

// ── ResponseQueue ─────────────────────────────────────────────────────

/// Thread-safe queue for async dispatch responses, keyed by correlation_id.
pub const ResponseQueue = struct {
    allocator: std.mem.Allocator,
    map: std.StringArrayHashMapUnmanaged(AsyncResponse),
    mutex: std.Thread.Mutex,

    pub fn init(allocator: std.mem.Allocator) ResponseQueue {
        return .{
            .allocator = allocator,
            .map = .{},
            .mutex = .{},
        };
    }

    pub fn deinit(self: *ResponseQueue) void {
        self.map.deinit(self.allocator);
    }

    /// Insert or overwrite a response keyed by its correlation_id.
    pub fn put(self: *ResponseQueue, response: AsyncResponse) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.map.put(self.allocator, response.correlation_id, response) catch return;
    }

    /// Remove and return the response for the given correlation_id, or null
    /// if no such entry exists.
    pub fn take(self: *ResponseQueue, correlation_id: []const u8) ?AsyncResponse {
        self.mutex.lock();
        defer self.mutex.unlock();
        const kv = self.map.fetchOrderedRemove(correlation_id) orelse return null;
        return kv.value;
    }
};

// ── Tests ─────────────────────────────────────────────────────────────

fn make_response(correlation_id: []const u8, output: []const u8) AsyncResponse {
    return .{
        .correlation_id = correlation_id,
        .output = output,
        .success = true,
        .error_text = null,
        .timestamp_ms = 1000,
    };
}

test "put and take by correlation_id" {
    var queue = ResponseQueue.init(std.testing.allocator);
    defer queue.deinit();

    queue.put(make_response("abc-123", "hello world"));

    const result = queue.take("abc-123");
    try std.testing.expect(result != null);
    try std.testing.expectEqualStrings("hello world", result.?.output);
    try std.testing.expectEqualStrings("abc-123", result.?.correlation_id);
    try std.testing.expect(result.?.success);

    // Second take returns null
    const result2 = queue.take("abc-123");
    try std.testing.expect(result2 == null);
}

test "take returns null for unknown id" {
    var queue = ResponseQueue.init(std.testing.allocator);
    defer queue.deinit();

    const result = queue.take("nonexistent");
    try std.testing.expect(result == null);
}

test "multiple correlation ids" {
    var queue = ResponseQueue.init(std.testing.allocator);
    defer queue.deinit();

    queue.put(make_response("id-1", "first"));
    queue.put(make_response("id-2", "second"));

    // Take in reverse order
    const r2 = queue.take("id-2");
    try std.testing.expect(r2 != null);
    try std.testing.expectEqualStrings("second", r2.?.output);

    const r1 = queue.take("id-1");
    try std.testing.expect(r1 != null);
    try std.testing.expectEqualStrings("first", r1.?.output);
}

test "overwrite on same correlation_id" {
    var queue = ResponseQueue.init(std.testing.allocator);
    defer queue.deinit();

    queue.put(make_response("dup", "old value"));
    queue.put(make_response("dup", "new value"));

    const result = queue.take("dup");
    try std.testing.expect(result != null);
    try std.testing.expectEqualStrings("new value", result.?.output);
}
