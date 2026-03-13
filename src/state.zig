/// State management module for NullBoiler orchestration.
/// Implements reducers and state operations for the unified state model.
/// Every node in the orchestration graph reads state, returns partial updates,
/// and the engine applies reducers to compute the new state.
const std = @import("std");
const types = @import("types.zig");
const ReducerType = types.ReducerType;
const Allocator = std.mem.Allocator;
const json = std.json;

// ── Helpers ───────────────────────────────────────────────────────────

/// Serialize a std.json.Value to an allocated JSON string.
fn serializeValue(alloc: Allocator, value: json.Value) ![]const u8 {
    var out: std.io.Writer.Allocating = .init(alloc);
    var jw: json.Stringify = .{ .writer = &out.writer };
    try jw.write(value);
    return try out.toOwnedSlice();
}

/// Extract f64 from a json.Value (handles both .integer and .float).
fn jsonToFloat(val: json.Value) ?f64 {
    return switch (val) {
        .float => |f| f,
        .integer => |i| @as(f64, @floatFromInt(i)),
        else => null,
    };
}

/// Format an f64 as a string. Renders integers without decimal point.
fn formatFloat(alloc: Allocator, f: f64) ![]const u8 {
    const i: i64 = @intFromFloat(f);
    if (@as(f64, @floatFromInt(i)) == f) {
        return try std.fmt.allocPrint(alloc, "{d}", .{i});
    }
    return try std.fmt.allocPrint(alloc, "{d}", .{f});
}

// ── Overwrite Bypass (Gap 5) ──────────────────────────────────────────

/// Check if a JSON value is wrapped in {"__overwrite": true, "value": ...}.
fn isOverwrite(value: json.Value) bool {
    if (value != .object) return false;
    const ow = value.object.get("__overwrite") orelse return false;
    if (ow != .bool) return false;
    return ow.bool;
}

/// Extract the "value" field from an overwrite wrapper.
/// Returns the unwrapped json.Value, or .null if "value" key is missing.
fn extractOverwriteValue(value: json.Value) json.Value {
    if (value != .object) return value;
    return value.object.get("value") orelse .null;
}

// ── Public API ────────────────────────────────────────────────────────

/// Apply a single reducer to merge old_value + update into new_value.
/// Returns newly allocated JSON string owned by the caller.
pub fn applyReducer(alloc: Allocator, reducer: ReducerType, old_value_json: ?[]const u8, update_json: []const u8) ![]const u8 {
    switch (reducer) {
        .last_value => {
            return try alloc.dupe(u8, update_json);
        },
        .append => {
            return try applyAppend(alloc, old_value_json, update_json);
        },
        .merge => {
            return try applyMerge(alloc, old_value_json, update_json);
        },
        .add => {
            return try applyAdd(alloc, old_value_json, update_json);
        },
        .min => {
            return try applyMin(alloc, old_value_json, update_json);
        },
        .max => {
            return try applyMax(alloc, old_value_json, update_json);
        },
        .add_messages => {
            return try applyAddMessages(alloc, old_value_json, update_json);
        },
    }
}

/// Apply partial state updates to full state using schema reducers.
/// For each key in updates_json:
///   1. Look up reducer type from schema_json (format: {"key": {"type": "...", "reducer": "..."}})
///   2. Get old value from state_json (may be null/missing)
///   3. Apply reducer(old_value, new_value)
///   4. Write result to output state
pub fn applyUpdates(alloc: Allocator, state_json: []const u8, updates_json: []const u8, schema_json: []const u8) ![]const u8 {
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const arena_alloc = arena.allocator();

    const state_parsed = try json.parseFromSlice(json.Value, arena_alloc, state_json, .{});
    const state_obj = if (state_parsed.value == .object) state_parsed.value.object else json.ObjectMap.init(arena_alloc);

    const updates_parsed = try json.parseFromSlice(json.Value, arena_alloc, updates_json, .{});
    if (updates_parsed.value != .object) return try alloc.dupe(u8, state_json);

    const schema_parsed = try json.parseFromSlice(json.Value, arena_alloc, schema_json, .{});
    const schema_obj = if (schema_parsed.value == .object) schema_parsed.value.object else json.ObjectMap.init(arena_alloc);

    // Start with a copy of all existing state keys
    var result_obj = json.ObjectMap.init(arena_alloc);
    var state_it = state_obj.iterator();
    while (state_it.next()) |entry| {
        try result_obj.put(entry.key_ptr.*, entry.value_ptr.*);
    }

    // For each update key, apply the reducer (with overwrite bypass, Gap 5)
    var updates_it = updates_parsed.value.object.iterator();
    while (updates_it.next()) |entry| {
        const key = entry.key_ptr.*;
        const update_value = entry.value_ptr.*;

        // Gap 5: Check for overwrite bypass
        if (isOverwrite(update_value)) {
            const raw_val = extractOverwriteValue(update_value);
            try result_obj.put(key, raw_val);
            continue;
        }

        // Serialize the update value
        const update_str = try serializeValue(arena_alloc, update_value);

        // Look up reducer from schema
        const reducer_type = blk: {
            if (schema_obj.get(key)) |schema_entry| {
                if (schema_entry == .object) {
                    if (schema_entry.object.get("reducer")) |reducer_val| {
                        if (reducer_val == .string) {
                            break :blk ReducerType.fromString(reducer_val.string) orelse .last_value;
                        }
                    }
                }
            }
            break :blk ReducerType.last_value;
        };

        // Get old value as JSON string (or null if missing)
        const old_str: ?[]const u8 = blk: {
            if (state_obj.get(key)) |old_val| {
                break :blk try serializeValue(arena_alloc, old_val);
            }
            break :blk null;
        };

        // Apply the reducer (allocates into arena)
        const new_str = try applyReducer(arena_alloc, reducer_type, old_str, update_str);

        // Parse the result back into a json.Value and put in result
        const new_parsed = try json.parseFromSlice(json.Value, arena_alloc, new_str, .{});
        try result_obj.put(key, new_parsed.value);
    }

    // Serialize the result into the caller's allocator
    const result_str = try serializeValue(arena_alloc, json.Value{ .object = result_obj });
    return try alloc.dupe(u8, result_str);
}

/// Initialize state from input JSON and schema defaults.
/// For each key in schema:
///   - if key exists in input -> use input value
///   - else -> use type default: "" for string, [] for array, 0 for number, false for boolean, {} for object, null otherwise
pub fn initState(alloc: Allocator, input_json: []const u8, schema_json: []const u8) ![]const u8 {
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const arena_alloc = arena.allocator();

    const input_parsed = try json.parseFromSlice(json.Value, arena_alloc, input_json, .{});
    const input_obj = if (input_parsed.value == .object) input_parsed.value.object else json.ObjectMap.init(arena_alloc);

    const schema_parsed = try json.parseFromSlice(json.Value, arena_alloc, schema_json, .{});
    if (schema_parsed.value != .object) return try alloc.dupe(u8, input_json);

    var result_obj = json.ObjectMap.init(arena_alloc);

    var schema_it = schema_parsed.value.object.iterator();
    while (schema_it.next()) |entry| {
        const key = entry.key_ptr.*;
        const schema_entry = entry.value_ptr.*;

        if (input_obj.get(key)) |input_val| {
            try result_obj.put(key, input_val);
        } else {
            const type_str = blk: {
                if (schema_entry == .object) {
                    if (schema_entry.object.get("type")) |type_val| {
                        if (type_val == .string) {
                            break :blk type_val.string;
                        }
                    }
                }
                break :blk "";
            };

            const default_val: json.Value = if (std.mem.eql(u8, type_str, "string"))
                .{ .string = "" }
            else if (std.mem.eql(u8, type_str, "array"))
                .{ .array = json.Array.init(arena_alloc) }
            else if (std.mem.eql(u8, type_str, "number"))
                .{ .integer = 0 }
            else if (std.mem.eql(u8, type_str, "boolean"))
                .{ .bool = false }
            else if (std.mem.eql(u8, type_str, "object"))
                .{ .object = json.ObjectMap.init(arena_alloc) }
            else
                .null;

            try result_obj.put(key, default_val);
        }
    }

    const result_str = try serializeValue(arena_alloc, json.Value{ .object = result_obj });
    return try alloc.dupe(u8, result_str);
}

/// Extract a value from state JSON by dotted path.
/// Supports:
///   - "state.messages" -> strips "state." prefix, returns value at key "messages"
///   - "state.plan.files" -> nested object access
///   - "state.messages[-1]" -> last element of array
pub fn getStateValue(alloc: Allocator, state_json: []const u8, path: []const u8) !?[]const u8 {
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const arena_alloc = arena.allocator();

    // Strip "state." prefix if present
    const effective_path = if (std.mem.startsWith(u8, path, "state."))
        path["state.".len..]
    else
        path;

    const parsed = try json.parseFromSlice(json.Value, arena_alloc, state_json, .{});
    var current = parsed.value;

    // Split by "." and walk the path
    var segments = std.mem.splitScalar(u8, effective_path, '.');
    while (segments.next()) |segment| {
        // Check for array index like "messages[-1]"
        if (std.mem.indexOfScalar(u8, segment, '[')) |bracket_pos| {
            const key = segment[0..bracket_pos];
            const index_str = segment[bracket_pos..];

            // Navigate to the key first
            if (current != .object) return null;
            current = current.object.get(key) orelse return null;

            // Parse the array index
            if (std.mem.eql(u8, index_str, "[-1]")) {
                if (current != .array) return null;
                if (current.array.items.len == 0) return null;
                current = current.array.items[current.array.items.len - 1];
            } else {
                // Parse positive index: [N]
                if (index_str.len < 3) return null;
                const num_str = index_str[1 .. index_str.len - 1];
                const idx = std.fmt.parseInt(usize, num_str, 10) catch return null;
                if (current != .array) return null;
                if (idx >= current.array.items.len) return null;
                current = current.array.items[idx];
            }
        } else {
            if (current != .object) return null;
            current = current.object.get(segment) orelse return null;
        }
    }

    const result_str = try serializeValue(arena_alloc, current);
    return try alloc.dupe(u8, result_str);
}

/// Convert JSON value to string for route matching.
/// - true/false -> "true"/"false"
/// - numbers -> decimal string representation
/// - "quoted string" -> strip quotes, return inner string
/// - anything else -> return as-is
pub fn stringifyForRoute(alloc: Allocator, value_json: []const u8) ![]const u8 {
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const arena_alloc = arena.allocator();

    const parsed = try json.parseFromSlice(json.Value, arena_alloc, value_json, .{});

    switch (parsed.value) {
        .bool => |b| {
            return try alloc.dupe(u8, if (b) "true" else "false");
        },
        .integer => |i| {
            return try std.fmt.allocPrint(alloc, "{d}", .{i});
        },
        .float => |f| {
            const tmp = try formatFloat(arena_alloc, f);
            return try alloc.dupe(u8, tmp);
        },
        .string => |s| {
            return try alloc.dupe(u8, s);
        },
        else => {
            return try alloc.dupe(u8, value_json);
        },
    }
}

// ── Reducer implementations ───────────────────────────────────────────

/// append: if old is null/empty -> wrap update in array [update].
/// If old is array -> parse, append update (element or array elements), serialize.
fn applyAppend(alloc: Allocator, old_json: ?[]const u8, update_json: []const u8) ![]const u8 {
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const arena_alloc = arena.allocator();

    const update_parsed = try json.parseFromSlice(json.Value, arena_alloc, update_json, .{});

    const old = old_json orelse {
        var arr = json.Array.init(arena_alloc);
        try arr.append(update_parsed.value);
        const result = try serializeValue(arena_alloc, json.Value{ .array = arr });
        return try alloc.dupe(u8, result);
    };

    if (old.len == 0) {
        var arr = json.Array.init(arena_alloc);
        try arr.append(update_parsed.value);
        const result = try serializeValue(arena_alloc, json.Value{ .array = arr });
        return try alloc.dupe(u8, result);
    }

    const old_parsed = try json.parseFromSlice(json.Value, arena_alloc, old, .{});

    if (old_parsed.value != .array) {
        var arr = json.Array.init(arena_alloc);
        try arr.append(old_parsed.value);
        try arr.append(update_parsed.value);
        const result = try serializeValue(arena_alloc, json.Value{ .array = arr });
        return try alloc.dupe(u8, result);
    }

    // Old is array - copy elements then append update
    var arr = json.Array.init(arena_alloc);
    for (old_parsed.value.array.items) |item| {
        try arr.append(item);
    }

    // If update is an array, append each element; otherwise append the single value
    if (update_parsed.value == .array) {
        for (update_parsed.value.array.items) |item| {
            try arr.append(item);
        }
    } else {
        try arr.append(update_parsed.value);
    }

    const result = try serializeValue(arena_alloc, json.Value{ .array = arr });
    return try alloc.dupe(u8, result);
}

/// merge: deep merge two JSON objects. Update keys override old keys.
/// Nested objects are recursively merged.
fn applyMerge(alloc: Allocator, old_json: ?[]const u8, update_json: []const u8) ![]const u8 {
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const arena_alloc = arena.allocator();

    const update_parsed = try json.parseFromSlice(json.Value, arena_alloc, update_json, .{});

    if (update_parsed.value != .object) {
        return try alloc.dupe(u8, update_json);
    }

    const old = old_json orelse {
        return try alloc.dupe(u8, update_json);
    };

    if (old.len == 0) {
        return try alloc.dupe(u8, update_json);
    }

    const old_parsed = try json.parseFromSlice(json.Value, arena_alloc, old, .{});

    if (old_parsed.value != .object) {
        return try alloc.dupe(u8, update_json);
    }

    const merged = try deepMerge(arena_alloc, old_parsed.value, update_parsed.value);
    const result = try serializeValue(arena_alloc, merged);
    return try alloc.dupe(u8, result);
}

/// Recursively deep-merge two JSON objects.
fn deepMerge(alloc: Allocator, base: json.Value, overlay: json.Value) !json.Value {
    if (base != .object or overlay != .object) {
        return overlay;
    }

    var result = json.ObjectMap.init(alloc);

    // Copy all base keys
    var base_it = base.object.iterator();
    while (base_it.next()) |entry| {
        try result.put(entry.key_ptr.*, entry.value_ptr.*);
    }

    // Apply overlay keys, recursively merging nested objects
    var overlay_it = overlay.object.iterator();
    while (overlay_it.next()) |entry| {
        const key = entry.key_ptr.*;
        const overlay_val = entry.value_ptr.*;

        if (result.get(key)) |existing| {
            if (existing == .object and overlay_val == .object) {
                const merged = try deepMerge(alloc, existing, overlay_val);
                try result.put(key, merged);
            } else {
                try result.put(key, overlay_val);
            }
        } else {
            try result.put(key, overlay_val);
        }
    }

    return json.Value{ .object = result };
}

/// add: parse both as numbers (f64), add, return string. If old is null, treat as 0.
fn applyAdd(alloc: Allocator, old_json: ?[]const u8, update_json: []const u8) ![]const u8 {
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const arena_alloc = arena.allocator();

    const update_parsed = try json.parseFromSlice(json.Value, arena_alloc, update_json, .{});
    const update_val = jsonToFloat(update_parsed.value) orelse return error.InvalidNumber;

    const old_val: f64 = blk: {
        const old = old_json orelse break :blk 0;
        if (old.len == 0) break :blk 0;
        const old_parsed = json.parseFromSlice(json.Value, arena_alloc, old, .{}) catch break :blk 0;
        break :blk jsonToFloat(old_parsed.value) orelse 0;
    };

    return try formatFloat(alloc, old_val + update_val);
}

/// min: parse both as numbers, return the smaller. If old is null, return update.
fn applyMin(alloc: Allocator, old_json: ?[]const u8, update_json: []const u8) ![]const u8 {
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const arena_alloc = arena.allocator();

    const update_parsed = try json.parseFromSlice(json.Value, arena_alloc, update_json, .{});
    const update_val = jsonToFloat(update_parsed.value) orelse return error.InvalidNumber;

    const old = old_json orelse return try formatFloat(alloc, update_val);
    if (old.len == 0) return try formatFloat(alloc, update_val);

    const old_parsed = json.parseFromSlice(json.Value, arena_alloc, old, .{}) catch
        return try formatFloat(alloc, update_val);
    const old_val = jsonToFloat(old_parsed.value) orelse return try formatFloat(alloc, update_val);

    return try formatFloat(alloc, @min(old_val, update_val));
}

/// max: parse both as numbers, return the larger. If old is null, return update.
fn applyMax(alloc: Allocator, old_json: ?[]const u8, update_json: []const u8) ![]const u8 {
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const arena_alloc = arena.allocator();

    const update_parsed = try json.parseFromSlice(json.Value, arena_alloc, update_json, .{});
    const update_val = jsonToFloat(update_parsed.value) orelse return error.InvalidNumber;

    const old = old_json orelse return try formatFloat(alloc, update_val);
    if (old.len == 0) return try formatFloat(alloc, update_val);

    const old_parsed = json.parseFromSlice(json.Value, arena_alloc, old, .{}) catch
        return try formatFloat(alloc, update_val);
    const old_val = jsonToFloat(old_parsed.value) orelse return try formatFloat(alloc, update_val);

    return try formatFloat(alloc, @max(old_val, update_val));
}

/// add_messages: merge message arrays by "id" field.
/// - If old is null → wrap update in array
/// - If update msg has "remove": true → remove matching id from old
/// - If update msg "id" matches existing → replace in-place
/// - If update msg "id" doesn't match → append
/// - If update msg has no "id" → generate one and append
fn applyAddMessages(alloc: Allocator, old_json: ?[]const u8, update_json: []const u8) ![]const u8 {
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const arena_alloc = arena.allocator();

    // Parse update: single object or array of objects
    const update_parsed = try json.parseFromSlice(json.Value, arena_alloc, update_json, .{});
    var update_msgs = json.Array.init(arena_alloc);
    if (update_parsed.value == .array) {
        for (update_parsed.value.array.items) |item| {
            try update_msgs.append(item);
        }
    } else if (update_parsed.value == .object) {
        try update_msgs.append(update_parsed.value);
    } else {
        return try alloc.dupe(u8, update_json);
    }

    // Parse old array or start empty
    var result_msgs = json.Array.init(arena_alloc);
    if (old_json) |old| {
        if (old.len > 0) {
            const old_parsed = try json.parseFromSlice(json.Value, arena_alloc, old, .{});
            if (old_parsed.value == .array) {
                for (old_parsed.value.array.items) |item| {
                    try result_msgs.append(item);
                }
            }
        }
    }

    // Process each update message
    for (update_msgs.items) |msg| {
        if (msg != .object) continue;

        const msg_id: ?[]const u8 = blk: {
            if (msg.object.get("id")) |id_val| {
                if (id_val == .string) break :blk id_val.string;
            }
            break :blk null;
        };

        // Check for remove flag
        const is_remove = blk: {
            if (msg.object.get("remove")) |rm_val| {
                if (rm_val == .bool) break :blk rm_val.bool;
            }
            break :blk false;
        };

        if (is_remove) {
            if (msg_id) |id| {
                // Filter out the message with matching id
                var filtered = json.Array.init(arena_alloc);
                for (result_msgs.items) |existing| {
                    if (existing == .object) {
                        if (existing.object.get("id")) |eid| {
                            if (eid == .string and std.mem.eql(u8, eid.string, id)) {
                                continue; // skip — removing this message
                            }
                        }
                    }
                    try filtered.append(existing);
                }
                result_msgs = filtered;
            }
            continue;
        }

        if (msg_id) |id| {
            // Try to find and replace existing message with same id
            var replaced = false;
            for (result_msgs.items, 0..) |existing, i| {
                if (existing == .object) {
                    if (existing.object.get("id")) |eid| {
                        if (eid == .string and std.mem.eql(u8, eid.string, id)) {
                            result_msgs.items[i] = msg;
                            replaced = true;
                            break;
                        }
                    }
                }
            }
            if (!replaced) {
                try result_msgs.append(msg);
            }
        } else {
            // No id — generate one and append
            var msg_copy = json.ObjectMap.init(arena_alloc);
            var it = msg.object.iterator();
            while (it.next()) |entry| {
                try msg_copy.put(entry.key_ptr.*, entry.value_ptr.*);
            }
            const gen_id = try std.fmt.allocPrint(arena_alloc, "msg_{d}", .{result_msgs.items.len});
            try msg_copy.put("id", json.Value{ .string = gen_id });
            try result_msgs.append(json.Value{ .object = msg_copy });
        }
    }

    const result = try serializeValue(arena_alloc, json.Value{ .array = result_msgs });
    return try alloc.dupe(u8, result);
}

// ── Custom errors ─────────────────────────────────────────────────────

const InvalidNumber = error{InvalidNumber};

// ── Tests ─────────────────────────────────────────────────────────────

fn parseTestJson(alloc: Allocator, json_str: []const u8) !json.Parsed(json.Value) {
    return try json.parseFromSlice(json.Value, alloc, json_str, .{});
}

test "last_value reducer" {
    const alloc = std.testing.allocator;
    const result = try applyReducer(alloc, .last_value, "\"old\"", "\"new\"");
    defer alloc.free(result);
    try std.testing.expectEqualStrings("\"new\"", result);
}

test "add reducer" {
    const alloc = std.testing.allocator;
    const result = try applyReducer(alloc, .add, "10", "5");
    defer alloc.free(result);
    try std.testing.expectEqualStrings("15", result);
}

test "add reducer with null old" {
    const alloc = std.testing.allocator;
    const result = try applyReducer(alloc, .add, null, "7");
    defer alloc.free(result);
    try std.testing.expectEqualStrings("7", result);
}

test "append reducer" {
    const alloc = std.testing.allocator;
    const result = try applyReducer(alloc, .append, "[1,2]", "3");
    defer alloc.free(result);
    try std.testing.expectEqualStrings("[1,2,3]", result);
}

test "append reducer with null old" {
    const alloc = std.testing.allocator;
    const result = try applyReducer(alloc, .append, null, "\"hello\"");
    defer alloc.free(result);
    try std.testing.expectEqualStrings("[\"hello\"]", result);
}

test "merge reducer - flat objects" {
    const alloc = std.testing.allocator;
    const result = try applyReducer(alloc, .merge, "{\"a\":1,\"b\":2}", "{\"b\":3,\"c\":4}");
    defer alloc.free(result);
    // Parse result to check keys since JSON object key order is not guaranteed
    const parsed = try parseTestJson(alloc, result);
    defer parsed.deinit();
    try std.testing.expect(parsed.value == .object);

    const a = parsed.value.object.get("a") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(i64, 1), a.integer);

    const b = parsed.value.object.get("b") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(i64, 3), b.integer);

    const c = parsed.value.object.get("c") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(i64, 4), c.integer);
}

test "merge reducer - null old" {
    const alloc = std.testing.allocator;
    const result = try applyReducer(alloc, .merge, null, "{\"x\":1}");
    defer alloc.free(result);
    try std.testing.expectEqualStrings("{\"x\":1}", result);
}

test "min reducer" {
    const alloc = std.testing.allocator;
    const result = try applyReducer(alloc, .min, "10", "3");
    defer alloc.free(result);
    try std.testing.expectEqualStrings("3", result);
}

test "max reducer" {
    const alloc = std.testing.allocator;
    const result = try applyReducer(alloc, .max, "10", "3");
    defer alloc.free(result);
    try std.testing.expectEqualStrings("10", result);
}

test "applyUpdates with mixed reducers" {
    const alloc = std.testing.allocator;
    const state =
        \\{"count":5,"messages":["hello"],"config":{"a":1}}
    ;
    const updates =
        \\{"count":3,"messages":"world","config":{"b":2}}
    ;
    const schema =
        \\{"count":{"type":"number","reducer":"add"},"messages":{"type":"array","reducer":"append"},"config":{"type":"object","reducer":"merge"}}
    ;

    const result = try applyUpdates(alloc, state, updates, schema);
    defer alloc.free(result);

    const parsed = try parseTestJson(alloc, result);
    defer parsed.deinit();
    try std.testing.expect(parsed.value == .object);

    // count: 5 + 3 = 8
    const count = parsed.value.object.get("count") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(i64, 8), count.integer);

    // messages: ["hello"] + "world" = ["hello","world"]
    const messages = parsed.value.object.get("messages") orelse return error.TestUnexpectedResult;
    try std.testing.expect(messages == .array);
    try std.testing.expectEqual(@as(usize, 2), messages.array.items.len);

    // config: merge {a:1} + {b:2} = {a:1, b:2}
    const config = parsed.value.object.get("config") orelse return error.TestUnexpectedResult;
    try std.testing.expect(config == .object);
    try std.testing.expect(config.object.get("a") != null);
    try std.testing.expect(config.object.get("b") != null);
}

test "initState with defaults" {
    const alloc = std.testing.allocator;
    const input =
        \\{"prompt":"hi"}
    ;
    const schema =
        \\{"prompt":{"type":"string","reducer":"last_value"},"messages":{"type":"array","reducer":"append"},"count":{"type":"number","reducer":"add"},"done":{"type":"boolean","reducer":"last_value"},"meta":{"type":"object","reducer":"merge"}}
    ;

    const result = try initState(alloc, input, schema);
    defer alloc.free(result);

    const parsed = try parseTestJson(alloc, result);
    defer parsed.deinit();
    try std.testing.expect(parsed.value == .object);

    // prompt should be from input
    const prompt = parsed.value.object.get("prompt") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("hi", prompt.string);

    // messages should default to []
    const messages = parsed.value.object.get("messages") orelse return error.TestUnexpectedResult;
    try std.testing.expect(messages == .array);
    try std.testing.expectEqual(@as(usize, 0), messages.array.items.len);

    // count should default to 0
    const count = parsed.value.object.get("count") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(i64, 0), count.integer);

    // done should default to false
    const done = parsed.value.object.get("done") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(false, done.bool);

    // meta should default to {}
    const meta = parsed.value.object.get("meta") orelse return error.TestUnexpectedResult;
    try std.testing.expect(meta == .object);
    try std.testing.expectEqual(@as(usize, 0), meta.object.count());
}

test "getStateValue simple key" {
    const alloc = std.testing.allocator;
    const state =
        \\{"prompt":"hello","count":42}
    ;
    const result = try getStateValue(alloc, state, "state.prompt");
    defer if (result) |r| alloc.free(r);
    try std.testing.expect(result != null);
    try std.testing.expectEqualStrings("\"hello\"", result.?);
}

test "getStateValue nested" {
    const alloc = std.testing.allocator;
    const state =
        \\{"plan":{"files":["a.zig","b.zig"]}}
    ;
    const result = try getStateValue(alloc, state, "state.plan.files");
    defer if (result) |r| alloc.free(r);
    try std.testing.expect(result != null);
    try std.testing.expectEqualStrings("[\"a.zig\",\"b.zig\"]", result.?);
}

test "getStateValue array last element" {
    const alloc = std.testing.allocator;
    const state =
        \\{"messages":["first","second","third"]}
    ;
    const result = try getStateValue(alloc, state, "state.messages[-1]");
    defer if (result) |r| alloc.free(r);
    try std.testing.expect(result != null);
    try std.testing.expectEqualStrings("\"third\"", result.?);
}

test "stringifyForRoute boolean" {
    const alloc = std.testing.allocator;
    const result_true = try stringifyForRoute(alloc, "true");
    defer alloc.free(result_true);
    try std.testing.expectEqualStrings("true", result_true);

    const result_false = try stringifyForRoute(alloc, "false");
    defer alloc.free(result_false);
    try std.testing.expectEqualStrings("false", result_false);
}

test "stringifyForRoute number" {
    const alloc = std.testing.allocator;
    const result = try stringifyForRoute(alloc, "42");
    defer alloc.free(result);
    try std.testing.expectEqualStrings("42", result);
}

test "stringifyForRoute string" {
    const alloc = std.testing.allocator;
    const result = try stringifyForRoute(alloc, "\"hello world\"");
    defer alloc.free(result);
    try std.testing.expectEqualStrings("hello world", result);
}

test "add_messages reducer - append new" {
    const alloc = std.testing.allocator;
    const result = try applyReducer(alloc, .add_messages,
        \\[{"id":"1","text":"hello"}]
    ,
        \\{"id":"2","text":"world"}
    );
    defer alloc.free(result);
    // Parse and verify: should be array with 2 messages
    const parsed = try parseTestJson(alloc, result);
    defer parsed.deinit();
    try std.testing.expect(parsed.value == .array);
    try std.testing.expectEqual(@as(usize, 2), parsed.value.array.items.len);
    // First message id=1
    const m0 = parsed.value.array.items[0];
    try std.testing.expect(m0 == .object);
    const id0 = m0.object.get("id") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("1", id0.string);
    // Second message id=2
    const m1 = parsed.value.array.items[1];
    try std.testing.expect(m1 == .object);
    const id1 = m1.object.get("id") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("2", id1.string);
    const text1 = m1.object.get("text") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("world", text1.string);
}

test "add_messages reducer - replace by id" {
    const alloc = std.testing.allocator;
    const result = try applyReducer(alloc, .add_messages,
        \\[{"id":"1","text":"old"}]
    ,
        \\{"id":"1","text":"new"}
    );
    defer alloc.free(result);
    const parsed = try parseTestJson(alloc, result);
    defer parsed.deinit();
    try std.testing.expect(parsed.value == .array);
    try std.testing.expectEqual(@as(usize, 1), parsed.value.array.items.len);
    const m0 = parsed.value.array.items[0];
    const text = m0.object.get("text") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("new", text.string);
}

test "add_messages reducer - remove by id" {
    const alloc = std.testing.allocator;
    const result = try applyReducer(alloc, .add_messages,
        \\[{"id":"1","text":"hello"},{"id":"2","text":"world"}]
    ,
        \\{"id":"1","remove":true}
    );
    defer alloc.free(result);
    const parsed = try parseTestJson(alloc, result);
    defer parsed.deinit();
    try std.testing.expect(parsed.value == .array);
    try std.testing.expectEqual(@as(usize, 1), parsed.value.array.items.len);
    const m0 = parsed.value.array.items[0];
    const id0 = m0.object.get("id") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("2", id0.string);
}

test "add_messages reducer - null old" {
    const alloc = std.testing.allocator;
    const result = try applyReducer(alloc, .add_messages, null,
        \\{"id":"1","text":"first"}
    );
    defer alloc.free(result);
    const parsed = try parseTestJson(alloc, result);
    defer parsed.deinit();
    try std.testing.expect(parsed.value == .array);
    try std.testing.expectEqual(@as(usize, 1), parsed.value.array.items.len);
    const m0 = parsed.value.array.items[0];
    const id0 = m0.object.get("id") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("1", id0.string);
    const text0 = m0.object.get("text") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("first", text0.string);
}

test "overwrite bypasses reducer" {
    const alloc = std.testing.allocator;
    // count has "add" reducer, but __overwrite should bypass it
    const state =
        \\{"count":10}
    ;
    const updates =
        \\{"count":{"__overwrite":true,"value":42}}
    ;
    const schema =
        \\{"count":{"type":"number","reducer":"add"}}
    ;

    const result = try applyUpdates(alloc, state, updates, schema);
    defer alloc.free(result);

    const parsed = try parseTestJson(alloc, result);
    defer parsed.deinit();
    try std.testing.expect(parsed.value == .object);
    const count = parsed.value.object.get("count") orelse return error.TestUnexpectedResult;
    // Should be 42 (overwritten), not 52 (10 + 42 via add reducer)
    try std.testing.expectEqual(@as(i64, 42), count.integer);
}

test "overwrite with array value" {
    const alloc = std.testing.allocator;
    const state =
        \\{"items":[1,2,3]}
    ;
    const updates =
        \\{"items":{"__overwrite":true,"value":[99]}}
    ;
    const schema =
        \\{"items":{"type":"array","reducer":"append"}}
    ;

    const result = try applyUpdates(alloc, state, updates, schema);
    defer alloc.free(result);

    const parsed = try parseTestJson(alloc, result);
    defer parsed.deinit();
    const items = parsed.value.object.get("items") orelse return error.TestUnexpectedResult;
    try std.testing.expect(items == .array);
    // Should be [99] (overwritten), not [1,2,3,99] (appended)
    try std.testing.expectEqual(@as(usize, 1), items.array.items.len);
    try std.testing.expectEqual(@as(i64, 99), items.array.items[0].integer);
}
