const std = @import("std");

pub const ValidateError = error{
    StepMustBeObject,
    StepIdMissingOrNotString,
    StepIdEmpty,
    StepIdDuplicate,
    DependsOnNotArray,
    DependsOnItemNotString,
    DependsOnDuplicate,
    DependsOnUnknownStepId,
    LoopBodyRequired,
    SubWorkflowRequired,
    WaitConditionRequired,
    WaitDurationInvalid,
    WaitUntilInvalid,
    WaitSignalInvalid,
    RouterRoutesRequired,
    SagaBodyRequired,
    DebateCountRequired,
    GroupChatParticipantsRequired,
    RetryMustBeObject,
    MaxAttemptsMustBePositiveInteger,
    TimeoutMsMustBePositiveInteger,
    OutOfMemory,
};

/// Validate steps payload for POST /runs.
/// Ensures structure is internally consistent before DB writes.
pub fn validateStepsForCreateRun(
    allocator: std.mem.Allocator,
    steps_array: []const std.json.Value,
) ValidateError!void {
    var step_defs = std.StringHashMap(void).init(allocator);
    defer step_defs.deinit();

    for (steps_array) |step_val| {
        if (step_val != .object) return error.StepMustBeObject;
        const step_obj = step_val.object;

        const def_step_id = getJsonString(step_obj, "id") orelse return error.StepIdMissingOrNotString;
        if (def_step_id.len == 0) return error.StepIdEmpty;
        if (step_defs.contains(def_step_id)) return error.StepIdDuplicate;
        step_defs.put(def_step_id, {}) catch return error.OutOfMemory;

        const step_type = getJsonString(step_obj, "type") orelse "task";
        validateStepTypeRules(step_type, step_obj) catch |err| return err;
        validateExecutionControls(step_obj) catch |err| return err;
        validateDependsOnTypes(allocator, step_obj) catch |err| return err;
    }

    for (steps_array) |step_val| {
        const step_obj = step_val.object;
        const deps_val = step_obj.get("depends_on") orelse continue;
        for (deps_val.array.items) |dep_item| {
            if (!step_defs.contains(dep_item.string)) {
                return error.DependsOnUnknownStepId;
            }
        }
    }
}

fn getJsonString(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const val = obj.get(key) orelse return null;
    if (val == .string) return val.string;
    return null;
}

fn validateStepTypeRules(step_type: []const u8, step_obj: std.json.ObjectMap) ValidateError!void {
    if (std.mem.eql(u8, step_type, "loop") and step_obj.get("body") == null) {
        return error.LoopBodyRequired;
    }
    if (std.mem.eql(u8, step_type, "sub_workflow") and step_obj.get("workflow") == null) {
        return error.SubWorkflowRequired;
    }
    if (std.mem.eql(u8, step_type, "wait")) {
        if (step_obj.get("duration_ms") == null and step_obj.get("until_ms") == null and step_obj.get("signal") == null) {
            return error.WaitConditionRequired;
        }
        if (step_obj.get("duration_ms")) |duration_val| {
            switch (duration_val) {
                .integer => {
                    if (duration_val.integer < 0) return error.WaitDurationInvalid;
                },
                else => return error.WaitDurationInvalid,
            }
        }
        if (step_obj.get("until_ms")) |until_val| {
            if (until_val != .integer or until_val.integer < 0) {
                return error.WaitUntilInvalid;
            }
        }
        if (step_obj.get("signal")) |signal_val| {
            if (signal_val != .string or signal_val.string.len == 0) {
                return error.WaitSignalInvalid;
            }
        }
    }
    if (std.mem.eql(u8, step_type, "router") and step_obj.get("routes") == null) {
        return error.RouterRoutesRequired;
    }
    if (std.mem.eql(u8, step_type, "saga") and step_obj.get("body") == null) {
        return error.SagaBodyRequired;
    }
    if (std.mem.eql(u8, step_type, "debate") and step_obj.get("count") == null) {
        return error.DebateCountRequired;
    }
    if (std.mem.eql(u8, step_type, "group_chat") and step_obj.get("participants") == null) {
        return error.GroupChatParticipantsRequired;
    }
}

fn validateDependsOnTypes(allocator: std.mem.Allocator, step_obj: std.json.ObjectMap) ValidateError!void {
    if (step_obj.get("depends_on")) |deps_val| {
        if (deps_val != .array) return error.DependsOnNotArray;
        var seen = std.StringHashMap(void).init(allocator);
        defer seen.deinit();
        for (deps_val.array.items) |dep_item| {
            if (dep_item != .string) return error.DependsOnItemNotString;
            if (seen.contains(dep_item.string)) return error.DependsOnDuplicate;
            seen.put(dep_item.string, {}) catch return error.OutOfMemory;
        }
    }
}

fn validateExecutionControls(step_obj: std.json.ObjectMap) ValidateError!void {
    if (step_obj.get("retry")) |retry_val| {
        if (retry_val != .object) return error.RetryMustBeObject;
        if (retry_val.object.get("max_attempts")) |ma| {
            if (ma != .integer or ma.integer < 1) {
                return error.MaxAttemptsMustBePositiveInteger;
            }
        }
    }

    if (step_obj.get("timeout_ms")) |timeout_val| {
        if (timeout_val != .integer or timeout_val.integer < 1) {
            return error.TimeoutMsMustBePositiveInteger;
        }
    }
}

// ── Tests ─────────────────────────────────────────────────────────────

test "validateStepsForCreateRun: valid workflow" {
    const allocator = std.testing.allocator;
    const payload =
        \\[
        \\  {"id":"a","type":"task"},
        \\  {"id":"b","type":"task","depends_on":["a"]}
        \\]
    ;

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, payload, .{});
    defer parsed.deinit();
    try validateStepsForCreateRun(allocator, parsed.value.array.items);
}

test "validateStepsForCreateRun: rejects unknown dependency" {
    const allocator = std.testing.allocator;
    const payload =
        \\[
        \\  {"id":"a","type":"task","depends_on":["missing"]}
        \\]
    ;

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, payload, .{});
    defer parsed.deinit();
    try std.testing.expectError(error.DependsOnUnknownStepId, validateStepsForCreateRun(allocator, parsed.value.array.items));
}

test "validateStepsForCreateRun: rejects duplicate ids" {
    const allocator = std.testing.allocator;
    const payload =
        \\[
        \\  {"id":"a","type":"task"},
        \\  {"id":"a","type":"task"}
        \\]
    ;

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, payload, .{});
    defer parsed.deinit();
    try std.testing.expectError(error.StepIdDuplicate, validateStepsForCreateRun(allocator, parsed.value.array.items));
}

test "validateStepsForCreateRun: rejects non-object step item" {
    const allocator = std.testing.allocator;
    const payload =
        \\[
        \\  "not-an-object"
        \\]
    ;

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, payload, .{});
    defer parsed.deinit();
    try std.testing.expectError(error.StepMustBeObject, validateStepsForCreateRun(allocator, parsed.value.array.items));
}

test "validateStepsForCreateRun: rejects missing string id" {
    const allocator = std.testing.allocator;
    const payload =
        \\[
        \\  {"type":"task"}
        \\]
    ;

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, payload, .{});
    defer parsed.deinit();
    try std.testing.expectError(error.StepIdMissingOrNotString, validateStepsForCreateRun(allocator, parsed.value.array.items));
}

test "validateStepsForCreateRun: rejects non-array depends_on" {
    const allocator = std.testing.allocator;
    const payload =
        \\[
        \\  {"id":"a","type":"task","depends_on":"x"}
        \\]
    ;

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, payload, .{});
    defer parsed.deinit();
    try std.testing.expectError(error.DependsOnNotArray, validateStepsForCreateRun(allocator, parsed.value.array.items));
}

test "validateStepsForCreateRun: rejects non-string depends_on item" {
    const allocator = std.testing.allocator;
    const payload =
        \\[
        \\  {"id":"a","type":"task","depends_on":[1]}
        \\]
    ;

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, payload, .{});
    defer parsed.deinit();
    try std.testing.expectError(error.DependsOnItemNotString, validateStepsForCreateRun(allocator, parsed.value.array.items));
}

test "validateStepsForCreateRun: rejects duplicate depends_on item" {
    const allocator = std.testing.allocator;
    const payload =
        \\[
        \\  {"id":"a","type":"task"},
        \\  {"id":"b","type":"task","depends_on":["a","a"]}
        \\]
    ;

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, payload, .{});
    defer parsed.deinit();
    try std.testing.expectError(error.DependsOnDuplicate, validateStepsForCreateRun(allocator, parsed.value.array.items));
}

test "validateStepsForCreateRun: rejects missing sub_workflow workflow field" {
    const allocator = std.testing.allocator;
    const payload =
        \\[
        \\  {"id":"sw","type":"sub_workflow"}
        \\]
    ;

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, payload, .{});
    defer parsed.deinit();
    try std.testing.expectError(error.SubWorkflowRequired, validateStepsForCreateRun(allocator, parsed.value.array.items));
}

test "validateStepsForCreateRun: rejects missing saga body field" {
    const allocator = std.testing.allocator;
    const payload =
        \\[
        \\  {"id":"sg","type":"saga"}
        \\]
    ;

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, payload, .{});
    defer parsed.deinit();
    try std.testing.expectError(error.SagaBodyRequired, validateStepsForCreateRun(allocator, parsed.value.array.items));
}

test "validateStepsForCreateRun: rejects missing debate count field" {
    const allocator = std.testing.allocator;
    const payload =
        \\[
        \\  {"id":"db","type":"debate","prompt_template":"x"}
        \\]
    ;

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, payload, .{});
    defer parsed.deinit();
    try std.testing.expectError(error.DebateCountRequired, validateStepsForCreateRun(allocator, parsed.value.array.items));
}

test "validateStepsForCreateRun: rejects missing group_chat participants field" {
    const allocator = std.testing.allocator;
    const payload =
        \\[
        \\  {"id":"gc","type":"group_chat","prompt_template":"x"}
        \\]
    ;

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, payload, .{});
    defer parsed.deinit();
    try std.testing.expectError(error.GroupChatParticipantsRequired, validateStepsForCreateRun(allocator, parsed.value.array.items));
}

test "validateStepsForCreateRun: rejects non-object retry field" {
    const allocator = std.testing.allocator;
    const payload =
        \\[
        \\  {"id":"a","type":"task","retry":1}
        \\]
    ;

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, payload, .{});
    defer parsed.deinit();
    try std.testing.expectError(error.RetryMustBeObject, validateStepsForCreateRun(allocator, parsed.value.array.items));
}

test "validateStepsForCreateRun: rejects non-positive max_attempts" {
    const allocator = std.testing.allocator;
    const payload =
        \\[
        \\  {"id":"a","type":"task","retry":{"max_attempts":0}}
        \\]
    ;

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, payload, .{});
    defer parsed.deinit();
    try std.testing.expectError(error.MaxAttemptsMustBePositiveInteger, validateStepsForCreateRun(allocator, parsed.value.array.items));
}

test "validateStepsForCreateRun: rejects non-positive timeout_ms" {
    const allocator = std.testing.allocator;
    const payload =
        \\[
        \\  {"id":"a","type":"task","timeout_ms":0}
        \\]
    ;

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, payload, .{});
    defer parsed.deinit();
    try std.testing.expectError(error.TimeoutMsMustBePositiveInteger, validateStepsForCreateRun(allocator, parsed.value.array.items));
}

test "validateStepsForCreateRun: rejects invalid wait duration string" {
    const allocator = std.testing.allocator;
    const payload =
        \\[
        \\  {"id":"w","type":"wait","duration_ms":"abc"}
        \\]
    ;

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, payload, .{});
    defer parsed.deinit();
    try std.testing.expectError(error.WaitDurationInvalid, validateStepsForCreateRun(allocator, parsed.value.array.items));
}

test "validateStepsForCreateRun: rejects negative wait duration" {
    const allocator = std.testing.allocator;
    const payload =
        \\[
        \\  {"id":"w","type":"wait","duration_ms":-1}
        \\]
    ;

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, payload, .{});
    defer parsed.deinit();
    try std.testing.expectError(error.WaitDurationInvalid, validateStepsForCreateRun(allocator, parsed.value.array.items));
}

test "validateStepsForCreateRun: rejects invalid wait signal type" {
    const allocator = std.testing.allocator;
    const payload =
        \\[
        \\  {"id":"w","type":"wait","signal":1}
        \\]
    ;

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, payload, .{});
    defer parsed.deinit();
    try std.testing.expectError(error.WaitSignalInvalid, validateStepsForCreateRun(allocator, parsed.value.array.items));
}
