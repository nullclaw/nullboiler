const std = @import("std");

// ── Types ─────────────────────────────────────────────────────────────

pub const Strategy = struct {
    name: []const u8,
    description: []const u8,
    build: []const u8, // "chain" or "independent"
};

pub const StrategyMap = std.StringArrayHashMapUnmanaged(Strategy);

pub const StrategyError = error{
    UnknownStrategy,
    DependsOnConflict,
    StepMustBeObject,
    StepsMissing,
    OutOfMemory,
};

// ── loadStrategies ────────────────────────────────────────────────────

/// Reads all .json files from `dir_path`, parses each into a Strategy,
/// and returns a name -> Strategy hash map. If the directory does not
/// exist, returns an empty map. Caller must provide an arena allocator —
/// loaded strategy strings point into allocations that are not individually freed.
pub fn loadStrategies(allocator: std.mem.Allocator, dir_path: []const u8) StrategyMap {
    var map = StrategyMap{};

    var dir = std.fs.cwd().openDir(dir_path, .{ .iterate = true }) catch {
        return map;
    };
    defer dir.close();

    var iter = dir.iterate();
    while (iter.next() catch null) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".json")) continue;

        const contents = dir.readFileAlloc(allocator, entry.name, 1024 * 1024) catch continue;
        const parsed = std.json.parseFromSlice(Strategy, allocator, contents, .{}) catch continue;
        const strategy = parsed.value;

        map.put(allocator, strategy.name, strategy) catch continue;
    }

    return map;
}

// ── expandStrategy ────────────────────────────────────────────────────

/// Takes the parsed run JSON object and expands strategy directives into
/// concrete steps with `depends_on`. Returns the (possibly modified) steps
/// array as a `std.json.Value`. Caller owns the returned value via the
/// arena allocator.
pub fn expandStrategy(
    allocator: std.mem.Allocator,
    strategies: StrategyMap,
    obj: std.json.ObjectMap,
) StrategyError!std.json.Value {
    const steps_val = obj.get("steps") orelse return StrategyError.StepsMissing;
    if (steps_val != .array) return StrategyError.StepsMissing;

    // No strategy field => passthrough
    const strategy_name = blk: {
        const val = obj.get("strategy") orelse return steps_val;
        if (val == .string) break :blk val.string;
        return steps_val;
    };

    // Look up the strategy
    const strategy = strategies.get(strategy_name) orelse return StrategyError.UnknownStrategy;

    // Validate: no step may have manual depends_on when strategy is set
    for (steps_val.array.items) |step_val| {
        if (step_val != .object) return StrategyError.StepMustBeObject;
        if (step_val.object.get("depends_on") != null) return StrategyError.DependsOnConflict;
    }

    // Expand steps with recursive nested handling first
    var expanded = std.json.Array.initCapacity(allocator, steps_val.array.items.len) catch
        return StrategyError.OutOfMemory;

    for (steps_val.array.items) |step_val| {
        if (step_val != .object) return StrategyError.StepMustBeObject;
        const expanded_step = try expandStepNested(allocator, strategies, step_val.object);
        expanded.append(expanded_step) catch return StrategyError.OutOfMemory;
    }

    // Apply build mode
    if (std.mem.eql(u8, strategy.build, "chain")) {
        applyChain(allocator, expanded.items) catch return StrategyError.OutOfMemory;
    }

    // Handle reduce field
    if (obj.get("reduce")) |reduce_val| {
        if (reduce_val == .object) {
            const reduce_step = buildReduceStep(allocator, reduce_val.object, expanded.items) catch
                return StrategyError.OutOfMemory;
            expanded.append(reduce_step) catch return StrategyError.OutOfMemory;
        }
    }

    return std.json.Value{ .array = expanded };
}

// ── Internal helpers ──────────────────────────────────────────────────

/// If a step has both "strategy" and "steps" fields, recursively expand
/// and wrap into a sub_workflow step. Otherwise return the step as-is.
fn expandStepNested(
    allocator: std.mem.Allocator,
    strategies: StrategyMap,
    step_obj: std.json.ObjectMap,
) StrategyError!std.json.Value {
    const has_strategy = step_obj.get("strategy") != null;
    const has_steps = step_obj.get("steps") != null;

    if (!has_strategy or !has_steps) {
        return std.json.Value{ .object = step_obj };
    }

    // Build a sub-object for recursive expansion
    const nested_steps = expandStrategy(allocator, strategies, step_obj) catch |err| return err;

    // Build a new step object: copy all fields except strategy/steps,
    // set type=sub_workflow, add workflow object with expanded steps
    var new_obj = std.json.ObjectMap.init(allocator);

    // Copy existing fields
    for (step_obj.keys(), step_obj.values()) |key, val| {
        if (std.mem.eql(u8, key, "strategy")) continue;
        if (std.mem.eql(u8, key, "steps")) continue;
        new_obj.put(key, val) catch return StrategyError.OutOfMemory;
    }

    // Override type to sub_workflow
    new_obj.put("type", std.json.Value{ .string = "sub_workflow" }) catch
        return StrategyError.OutOfMemory;

    // Build workflow object with expanded steps
    var workflow_obj = std.json.ObjectMap.init(allocator);
    workflow_obj.put("steps", nested_steps) catch return StrategyError.OutOfMemory;
    new_obj.put("workflow", std.json.Value{ .object = workflow_obj }) catch
        return StrategyError.OutOfMemory;

    return std.json.Value{ .object = new_obj };
}

/// For chain mode: step[i] depends on step[i-1].
fn applyChain(allocator: std.mem.Allocator, steps: []std.json.Value) !void {
    for (steps, 0..) |*step_val, i| {
        if (i == 0) continue;
        if (step_val.* != .object) continue;

        const prev_step = steps[i - 1];
        if (prev_step != .object) continue;

        const prev_id_val = prev_step.object.get("id") orelse continue;
        if (prev_id_val != .string) continue;

        var deps = try std.json.Array.initCapacity(allocator, 1);
        try deps.append(std.json.Value{ .string = prev_id_val.string });

        try step_val.object.put("depends_on", std.json.Value{ .array = deps });
    }
}

/// Build a reduce step that depends on all other steps.
fn buildReduceStep(
    allocator: std.mem.Allocator,
    reduce_obj: std.json.ObjectMap,
    steps: []const std.json.Value,
) !std.json.Value {
    var new_obj = std.json.ObjectMap.init(allocator);

    // Copy all fields from the reduce config
    for (reduce_obj.keys(), reduce_obj.values()) |key, val| {
        try new_obj.put(key, val);
    }

    // Set type to reduce
    try new_obj.put("type", std.json.Value{ .string = "reduce" });

    // Ensure it has an id; default to "__reduce" if not provided
    if (new_obj.get("id") == null) {
        try new_obj.put("id", std.json.Value{ .string = "__reduce" });
    }

    // Build depends_on array from all step ids
    var deps = try std.json.Array.initCapacity(allocator, steps.len);
    for (steps) |step_val| {
        if (step_val != .object) continue;
        const id_val = step_val.object.get("id") orelse continue;
        if (id_val != .string) continue;
        try deps.append(std.json.Value{ .string = id_val.string });
    }

    try new_obj.put("depends_on", std.json.Value{ .array = deps });

    return std.json.Value{ .object = new_obj };
}

// ── Tests ─────────────────────────────────────────────────────────────

fn makeTestStrategies(allocator: std.mem.Allocator) StrategyMap {
    var map = StrategyMap{};
    map.put(allocator, "sequential", Strategy{
        .name = "sequential",
        .description = "chain steps",
        .build = "chain",
    }) catch unreachable;
    map.put(allocator, "parallel", Strategy{
        .name = "parallel",
        .description = "independent steps",
        .build = "independent",
    }) catch unreachable;
    return map;
}

fn parseJson(allocator: std.mem.Allocator, input: []const u8) !std.json.Parsed(std.json.Value) {
    return try std.json.parseFromSlice(std.json.Value, allocator, input, .{});
}

fn getJsonString(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const val = obj.get(key) orelse return null;
    if (val == .string) return val.string;
    return null;
}

test "loadStrategies: returns empty map when directory missing" {
    const map = loadStrategies(std.testing.allocator, "nonexistent_dir_xyz_999");
    try std.testing.expectEqual(@as(usize, 0), map.count());
}

test "loadStrategies: loads from directory" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{
        .sub_path = "mychain.json",
        .data =
        \\{"name":"mychain","description":"test chain","build":"chain"}
        ,
    });
    try tmp.dir.writeFile(.{
        .sub_path = "mypar.json",
        .data =
        \\{"name":"mypar","description":"test parallel","build":"independent"}
        ,
    });
    // Non-json file should be ignored
    try tmp.dir.writeFile(.{
        .sub_path = "readme.txt",
        .data = "not json",
    });

    const dir_path = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(dir_path);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const map = loadStrategies(arena.allocator(), dir_path);
    try std.testing.expectEqual(@as(usize, 2), map.count());

    const chain = map.get("mychain").?;
    try std.testing.expectEqualStrings("chain", chain.build);

    const par = map.get("mypar").?;
    try std.testing.expectEqualStrings("independent", par.build);
}

test "expandStrategy: passthrough when no strategy field" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const strategies = makeTestStrategies(alloc);

    const input =
        \\{"steps":[{"id":"a","type":"task"},{"id":"b","type":"task"}]}
    ;
    const parsed = try parseJson(alloc, input);
    const result = try expandStrategy(alloc, strategies, parsed.value.object);

    // Should return steps array as-is
    try std.testing.expectEqual(@as(usize, 2), result.array.items.len);
    // No depends_on should be added
    try std.testing.expect(result.array.items[0].object.get("depends_on") == null);
    try std.testing.expect(result.array.items[1].object.get("depends_on") == null);
}

test "expandStrategy chain: adds sequential depends_on" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const strategies = makeTestStrategies(alloc);

    const input =
        \\{"strategy":"sequential","steps":[{"id":"a","type":"task"},{"id":"b","type":"task"},{"id":"c","type":"task"}]}
    ;
    const parsed = try parseJson(alloc, input);
    const result = try expandStrategy(alloc, strategies, parsed.value.object);

    try std.testing.expectEqual(@as(usize, 3), result.array.items.len);

    // Step a: no depends_on
    try std.testing.expect(result.array.items[0].object.get("depends_on") == null);

    // Step b: depends on a
    const b_deps = result.array.items[1].object.get("depends_on").?;
    try std.testing.expectEqual(@as(usize, 1), b_deps.array.items.len);
    try std.testing.expectEqualStrings("a", b_deps.array.items[0].string);

    // Step c: depends on b
    const c_deps = result.array.items[2].object.get("depends_on").?;
    try std.testing.expectEqual(@as(usize, 1), c_deps.array.items.len);
    try std.testing.expectEqualStrings("b", c_deps.array.items[0].string);
}

test "expandStrategy independent: no depends_on added" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const strategies = makeTestStrategies(alloc);

    const input =
        \\{"strategy":"parallel","steps":[{"id":"a","type":"task"},{"id":"b","type":"task"}]}
    ;
    const parsed = try parseJson(alloc, input);
    const result = try expandStrategy(alloc, strategies, parsed.value.object);

    try std.testing.expectEqual(@as(usize, 2), result.array.items.len);
    try std.testing.expect(result.array.items[0].object.get("depends_on") == null);
    try std.testing.expect(result.array.items[1].object.get("depends_on") == null);
}

test "expandStrategy independent + reduce: appends reduce step depending on all" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const strategies = makeTestStrategies(alloc);

    const input =
        \\{"strategy":"parallel","steps":[{"id":"a","type":"task"},{"id":"b","type":"task"}],"reduce":{"id":"r","prompt_template":"summarize"}}
    ;
    const parsed = try parseJson(alloc, input);
    const result = try expandStrategy(alloc, strategies, parsed.value.object);

    // 2 original + 1 reduce = 3
    try std.testing.expectEqual(@as(usize, 3), result.array.items.len);

    const reduce_step = result.array.items[2].object;
    try std.testing.expectEqualStrings("reduce", getJsonString(reduce_step, "type").?);
    try std.testing.expectEqualStrings("r", getJsonString(reduce_step, "id").?);

    // depends_on should include a and b
    const deps = reduce_step.get("depends_on").?.array.items;
    try std.testing.expectEqual(@as(usize, 2), deps.len);
    try std.testing.expectEqualStrings("a", deps[0].string);
    try std.testing.expectEqualStrings("b", deps[1].string);
}

test "expandStrategy nested: converts to sub_workflow with recursive expansion" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const strategies = makeTestStrategies(alloc);

    const input =
        \\{"strategy":"sequential","steps":[{"id":"outer1","type":"task"},{"id":"nested","strategy":"sequential","steps":[{"id":"inner1","type":"task"},{"id":"inner2","type":"task"}]}]}
    ;
    const parsed = try parseJson(alloc, input);
    const result = try expandStrategy(alloc, strategies, parsed.value.object);

    try std.testing.expectEqual(@as(usize, 2), result.array.items.len);

    // First step is unchanged
    try std.testing.expectEqualStrings("outer1", getJsonString(result.array.items[0].object, "id").?);

    // Second step should be converted to sub_workflow
    const nested = result.array.items[1].object;
    try std.testing.expectEqualStrings("sub_workflow", getJsonString(nested, "type").?);
    try std.testing.expectEqualStrings("nested", getJsonString(nested, "id").?);

    // Should have workflow field with expanded steps
    const workflow = nested.get("workflow").?;
    try std.testing.expect(workflow == .object);
    const inner_steps = workflow.object.get("steps").?.array.items;
    try std.testing.expectEqual(@as(usize, 2), inner_steps.len);

    // Inner steps should have chain deps applied
    try std.testing.expect(inner_steps[0].object.get("depends_on") == null);
    const inner2_deps = inner_steps[1].object.get("depends_on").?.array.items;
    try std.testing.expectEqual(@as(usize, 1), inner2_deps.len);
    try std.testing.expectEqualStrings("inner1", inner2_deps[0].string);

    // Outer chain: nested depends on outer1
    const outer_deps = nested.get("depends_on").?.array.items;
    try std.testing.expectEqual(@as(usize, 1), outer_deps.len);
    try std.testing.expectEqualStrings("outer1", outer_deps[0].string);
}

test "expandStrategy error: unknown strategy" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const strategies = makeTestStrategies(alloc);

    const input =
        \\{"strategy":"nonexistent","steps":[{"id":"a","type":"task"}]}
    ;
    const parsed = try parseJson(alloc, input);
    try std.testing.expectError(
        StrategyError.UnknownStrategy,
        expandStrategy(alloc, strategies, parsed.value.object),
    );
}

test "expandStrategy error: strategy + depends_on conflict" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const strategies = makeTestStrategies(alloc);

    const input =
        \\{"strategy":"sequential","steps":[{"id":"a","type":"task","depends_on":["x"]}]}
    ;
    const parsed = try parseJson(alloc, input);
    try std.testing.expectError(
        StrategyError.DependsOnConflict,
        expandStrategy(alloc, strategies, parsed.value.object),
    );
}

test "expandStrategy: reduce step gets default id when not provided" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const strategies = makeTestStrategies(alloc);

    const input =
        \\{"strategy":"parallel","steps":[{"id":"a","type":"task"}],"reduce":{"prompt_template":"summarize"}}
    ;
    const parsed = try parseJson(alloc, input);
    const result = try expandStrategy(alloc, strategies, parsed.value.object);

    try std.testing.expectEqual(@as(usize, 2), result.array.items.len);

    const reduce_step = result.array.items[1].object;
    try std.testing.expectEqualStrings("__reduce", getJsonString(reduce_step, "id").?);
    try std.testing.expectEqualStrings("reduce", getJsonString(reduce_step, "type").?);
}
