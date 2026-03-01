const std = @import("std");

pub const ParseResult = struct {
    output: []const u8,
    success: bool,
    error_text: ?[]const u8,
};

pub const invalid_json_error = "worker response must be a JSON object";
pub const missing_output_error = "worker response missing response/reply/choices.message.content field";
pub const ack_without_output_error = "worker acknowledged request but returned no synchronous output";

pub fn parse(allocator: std.mem.Allocator, response_data: []const u8) !ParseResult {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, response_data, .{}) catch {
        return failure(invalid_json_error);
    };
    defer parsed.deinit();

    if (parsed.value != .object) return failure(invalid_json_error);
    const obj = parsed.value.object;

    if (try extractErrorMessage(allocator, obj)) |error_text| {
        return .{
            .output = "",
            .success = false,
            .error_text = error_text,
        };
    }

    if (extractOutput(obj)) |output| {
        return .{
            .output = try allocator.dupe(u8, output),
            .success = true,
            .error_text = null,
        };
    }

    if (isAsyncAckWithoutOutput(obj)) return failure(ack_without_output_error);
    return failure(missing_output_error);
}

fn failure(message: []const u8) ParseResult {
    return .{
        .output = "",
        .success = false,
        .error_text = message,
    };
}

fn extractOutput(obj: std.json.ObjectMap) ?[]const u8 {
    if (obj.get("response")) |resp_val| {
        if (resp_val == .string) return resp_val.string;
    }

    if (obj.get("reply")) |reply_val| {
        if (reply_val == .string) return reply_val.string;
    }

    if (obj.get("choices")) |choices_val| {
        if (choices_val == .array and choices_val.array.items.len > 0) {
            const first_choice = choices_val.array.items[0];
            if (first_choice == .object) {
                if (first_choice.object.get("message")) |msg_val| {
                    if (msg_val == .object) {
                        if (msg_val.object.get("content")) |content_val| {
                            if (content_val == .string) return content_val.string;
                        }
                    }
                }
            }
        }
    }

    return null;
}

fn extractErrorMessage(allocator: std.mem.Allocator, obj: std.json.ObjectMap) !?[]const u8 {
    const err_val = obj.get("error") orelse return null;

    if (err_val == .string) {
        return try allocator.dupe(u8, err_val.string);
    }

    if (err_val == .object) {
        if (err_val.object.get("message")) |msg_val| {
            if (msg_val == .string) {
                return try allocator.dupe(u8, msg_val.string);
            }
        }
    }

    return null;
}

fn isAsyncAckWithoutOutput(obj: std.json.ObjectMap) bool {
    const status_val = obj.get("status") orelse return false;
    return status_val == .string and std.mem.eql(u8, status_val.string, "received");
}

test "parse supports nullclaw response format" {
    const allocator = std.testing.allocator;
    const result = try parse(
        allocator,
        "{\"status\":\"ok\",\"response\":\"Done\",\"thread_events\":[]}",
    );
    defer allocator.free(result.output);
    try std.testing.expect(result.success);
    try std.testing.expectEqualStrings("Done", result.output);
}

test "parse supports zeroclaw api_chat format" {
    const allocator = std.testing.allocator;
    const result = try parse(allocator, "{\"reply\":\"API chat response\",\"model\":\"foo\"}");
    defer allocator.free(result.output);
    try std.testing.expect(result.success);
    try std.testing.expectEqualStrings("API chat response", result.output);
}

test "parse supports openai chat completions format" {
    const allocator = std.testing.allocator;
    const result = try parse(
        allocator,
        "{\"id\":\"chatcmpl-1\",\"choices\":[{\"index\":0,\"message\":{\"role\":\"assistant\",\"content\":\"OpenAI style\"}}]}",
    );
    defer allocator.free(result.output);
    try std.testing.expect(result.success);
    try std.testing.expectEqualStrings("OpenAI style", result.output);
}

test "parse rejects non-object payload" {
    const allocator = std.testing.allocator;
    const result = try parse(allocator, "plain text");
    try std.testing.expect(!result.success);
    try std.testing.expectEqualStrings(invalid_json_error, result.error_text.?);
}

test "parse returns worker error message from error object" {
    const allocator = std.testing.allocator;
    const result = try parse(allocator, "{\"error\":{\"message\":\"boom\"}}");
    defer allocator.free(result.error_text.?);
    try std.testing.expect(!result.success);
    try std.testing.expectEqualStrings("boom", result.error_text.?);
}

test "parse prioritizes error field over output fields" {
    const allocator = std.testing.allocator;
    const result = try parse(allocator, "{\"response\":\"partial\",\"error\":\"hard failure\"}");
    defer allocator.free(result.error_text.?);
    try std.testing.expect(!result.success);
    try std.testing.expectEqualStrings("hard failure", result.error_text.?);
}

test "parse rejects status received without output" {
    const allocator = std.testing.allocator;
    const result = try parse(allocator, "{\"status\":\"received\"}");
    try std.testing.expect(!result.success);
    try std.testing.expectEqualStrings(ack_without_output_error, result.error_text.?);
}

test "parse rejects object without supported output fields" {
    const allocator = std.testing.allocator;
    const result = try parse(allocator, "{\"output\":\"legacy\"}");
    try std.testing.expect(!result.success);
    try std.testing.expectEqualStrings(missing_output_error, result.error_text.?);
}
