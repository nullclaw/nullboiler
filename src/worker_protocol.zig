const std = @import("std");

pub const Protocol = enum {
    webhook,
    api_chat,
    openai_chat,
};

pub fn parse(raw: []const u8) ?Protocol {
    if (std.mem.eql(u8, raw, "webhook")) return .webhook;
    if (std.mem.eql(u8, raw, "api_chat")) return .api_chat;
    if (std.mem.eql(u8, raw, "openai_chat")) return .openai_chat;
    return null;
}

pub fn requiresModel(protocol: Protocol) bool {
    return protocol == .openai_chat;
}

pub fn requiresExplicitPath(protocol: Protocol) bool {
    return protocol == .webhook;
}

pub fn validateUrlForProtocol(url: []const u8, protocol: Protocol) bool {
    if (!requiresExplicitPath(protocol)) return true;
    return hasExplicitPath(url);
}

pub fn buildRequestUrl(
    allocator: std.mem.Allocator,
    worker_url: []const u8,
    protocol: Protocol,
) ![]const u8 {
    const trimmed = std.mem.trimRight(u8, worker_url, "/");
    if (requiresExplicitPath(protocol) and !hasExplicitPath(trimmed)) {
        return error.WebhookUrlPathRequired;
    }
    return try allocator.dupe(u8, trimmed);
}

pub fn hasExplicitPath(url: []const u8) bool {
    const trimmed = std.mem.trimRight(u8, url, "/");
    if (std.mem.startsWith(u8, trimmed, "/")) return true;

    const scheme_idx = std.mem.indexOf(u8, trimmed, "://") orelse return false;
    const host_start = scheme_idx + 3;
    const slash_idx = std.mem.indexOfScalarPos(u8, trimmed, host_start, '/') orelse return false;
    return slash_idx + 1 < trimmed.len;
}

test "parse protocol supports known values" {
    try std.testing.expectEqual(Protocol.webhook, parse("webhook").?);
    try std.testing.expectEqual(Protocol.api_chat, parse("api_chat").?);
    try std.testing.expectEqual(Protocol.openai_chat, parse("openai_chat").?);
    try std.testing.expect(parse("unknown") == null);
}

test "hasExplicitPath only accepts explicit path" {
    try std.testing.expect(!hasExplicitPath("http://localhost:3000"));
    try std.testing.expect(!hasExplicitPath("http://localhost:3000/"));
    try std.testing.expect(hasExplicitPath("http://localhost:3000/webhook"));
    try std.testing.expect(hasExplicitPath("/webhook"));
}

test "buildRequestUrl enforces explicit webhook path" {
    const allocator = std.testing.allocator;

    try std.testing.expectError(
        error.WebhookUrlPathRequired,
        buildRequestUrl(allocator, "http://localhost:3000", .webhook),
    );

    const webhook_url = try buildRequestUrl(allocator, "http://localhost:3000/webhook", .webhook);
    defer allocator.free(webhook_url);
    try std.testing.expectEqualStrings("http://localhost:3000/webhook", webhook_url);

    const api_url = try buildRequestUrl(allocator, "http://localhost:42617/api/chat/", .api_chat);
    defer allocator.free(api_url);
    try std.testing.expectEqualStrings("http://localhost:42617/api/chat", api_url);
}

test "validateUrlForProtocol enforces protocol-specific constraints" {
    try std.testing.expect(!validateUrlForProtocol("http://localhost:3000", .webhook));
    try std.testing.expect(validateUrlForProtocol("http://localhost:3000/webhook", .webhook));
    try std.testing.expect(validateUrlForProtocol("http://localhost:42617/api/chat", .api_chat));
}
