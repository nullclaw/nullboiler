const std = @import("std");
const log = std.log.scoped(.workspace);

/// Sanitize an ID for safe use as a directory name.
/// Replaces any character that is not alphanumeric, '.', '_', or '-' with '_'.
pub fn sanitizeId(allocator: std.mem.Allocator, id: []const u8) ![]const u8 {
    const buf = try allocator.alloc(u8, id.len);
    for (buf, id) |*out, ch| {
        out.* = if (std.ascii.isAlphanumeric(ch) or ch == '.' or ch == '_' or ch == '-')
            ch
        else
            '_';
    }
    return buf;
}

/// Validate that a workspace path is safely contained within the workspace root.
/// Returns true if the canonical workspace_path starts with the canonical root
/// and contains no invalid characters. Returns false if a symlink escape or
/// directory traversal is detected.
pub fn validateWorkspacePath(allocator: std.mem.Allocator, workspace_root: []const u8, workspace_path: []const u8) bool {
    // Check for invalid characters (\n, \r, \0) in the raw path
    for (workspace_path) |ch| {
        if (ch == '\n' or ch == '\r' or ch == 0) {
            log.warn("workspace path contains invalid character: {s}", .{workspace_path});
            return false;
        }
    }

    // Canonicalize both paths (resolves symlinks)
    const canon_root = std.fs.cwd().realpathAlloc(allocator, workspace_root) catch {
        log.warn("workspace: cannot resolve root {s}", .{workspace_root});
        return false;
    };
    defer allocator.free(canon_root);

    const canon_path = std.fs.cwd().realpathAlloc(allocator, workspace_path) catch {
        log.warn("workspace: cannot resolve path {s}", .{workspace_path});
        return false;
    };
    defer allocator.free(canon_path);

    // Check that canonical workspace_path starts with canonical workspace_root
    if (!std.mem.startsWith(u8, canon_path, canon_root)) {
        log.warn("workspace path escape detected: {s} is not under {s}", .{ canon_path, canon_root });
        return false;
    }

    // Ensure there's a separator after the root (not just a prefix match on a longer name)
    if (canon_path.len > canon_root.len and canon_path[canon_root.len] != std.fs.path.sep) {
        log.warn("workspace path escape detected: {s} is not under {s}", .{ canon_path, canon_root });
        return false;
    }

    return true;
}

/// Sanitize a directory name by replacing any character not in [A-Za-z0-9._-]
/// with '_'. This prevents directory traversal via task identifiers.
/// Alias for sanitizeId — same logic, exported under the canonical name.
pub const sanitizeDirectoryName = sanitizeId;

/// An isolated workspace directory for a single task.
pub const Workspace = struct {
    root: []const u8,
    task_id: []const u8,
    path: []const u8,
    created: bool,

    /// Create (or open) a workspace directory under `root` for the given task ID.
    /// The task ID is sanitized before use as a directory component.
    /// Returns a Workspace; `created` is true when the directory was freshly made
    /// (i.e. it did not exist before this call).
    pub fn create(allocator: std.mem.Allocator, root: []const u8, task_id: []const u8) !Workspace {
        const safe_id = try sanitizeId(allocator, task_id);
        defer allocator.free(safe_id);

        // Build full path: root/safe_id
        const path = try std.fs.path.join(allocator, &.{ root, safe_id });

        // Ensure root directory exists
        std.fs.cwd().makePath(root) catch |err| {
            log.warn("workspace: failed to create root {s}: {}", .{ root, err });
            return err;
        };

        // Try to create the workspace directory; track whether it already existed
        var created = true;
        std.fs.cwd().makePath(path) catch |err| {
            log.warn("workspace: failed to create workspace dir {s}: {}", .{ path, err });
            return err;
        };

        // Validate the created path is safely under the workspace root
        if (!validateWorkspacePath(allocator, root, path)) {
            log.warn("workspace: path validation failed for {s}, refusing to use", .{path});
            allocator.free(path);
            return error.PathValidationFailed;
        }

        // If the directory already had contents it was not freshly created
        var dir = try std.fs.cwd().openDir(path, .{ .iterate = true });
        defer dir.close();

        var iter = dir.iterate();
        if (try iter.next()) |_| {
            created = false;
        }

        log.info("workspace ready: {s} (new={any})", .{ path, created });

        return Workspace{
            .root = root,
            .task_id = task_id,
            .path = path,
            .created = created,
        };
    }

    /// Remove the workspace directory tree. Logs a warning on failure.
    pub fn remove(self: *const Workspace) void {
        std.fs.cwd().deleteTree(self.path) catch |err| {
            log.warn("workspace: failed to remove {s}: {}", .{ self.path, err });
            return;
        };
        log.info("workspace removed: {s}", .{self.path});
    }
};

/// Remove all subdirectories under the workspace root.
/// Used for startup cleanup — workspaces are ephemeral and will be recreated by hooks.
pub fn cleanAll(root: []const u8) void {
    var dir = std.fs.cwd().openDir(root, .{ .iterate = true }) catch |err| {
        log.warn("workspace: cannot open root {s} for cleanup: {}", .{ root, err });
        return;
    };
    defer dir.close();

    var iter = dir.iterate();
    // Collect names first to avoid modifying directory while iterating
    var names: std.ArrayListUnmanaged([]const u8) = .empty;
    defer {
        for (names.items) |name| std.heap.page_allocator.free(@constCast(name));
        names.deinit(std.heap.page_allocator);
    }

    while (iter.next() catch null) |entry| {
        if (entry.kind == .directory) {
            names.append(std.heap.page_allocator, std.heap.page_allocator.dupe(u8, entry.name) catch continue) catch continue;
        }
    }

    for (names.items) |name| {
        dir.deleteTree(name) catch |err| {
            log.warn("workspace: failed to clean {s}/{s}: {}", .{ root, name, err });
            continue;
        };
        log.info("workspace: cleaned up {s}/{s}", .{ root, name });
    }

    if (names.items.len > 0) {
        log.info("workspace: startup cleanup removed {d} workspace(s)", .{names.items.len});
    }
}

/// Run a shell hook command via /bin/sh in the given working directory.
/// Returns true when the command exits with code 0, false otherwise.
/// Times out after `timeout_ms` milliseconds (the child is killed on timeout).
pub fn runHook(allocator: std.mem.Allocator, command: []const u8, cwd: []const u8, timeout_ms: u64) !bool {
    const argv = [_][]const u8{ "/bin/sh", "-lc", command };

    var child = std.process.Child.init(&argv, allocator);
    child.cwd = cwd;

    // We don't need to capture output for hooks — inherit parent stdio
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Ignore;

    try child.spawn();

    // Spawn a watchdog thread that kills the child after the timeout.
    // The atomic flag lets the watchdog exit early once the child finishes.
    var child_done = std.atomic.Value(bool).init(false);
    const killer = std.Thread.spawn(.{}, killAfterTimeout, .{ &child, timeout_ms, &child_done }) catch null;
    defer {
        child_done.store(true, .release);
        if (killer) |t| t.join();
    }

    const term = child.wait() catch |err| {
        log.warn("hook wait failed: {s}: {}", .{ command, err });
        return false;
    };

    const success = term == .Exited and term.Exited == 0;
    if (!success) {
        log.warn("hook exited non-zero: {s}", .{command});
    }
    return success;
}

fn killAfterTimeout(child: *std.process.Child, timeout_ms: u64, done: *std.atomic.Value(bool)) void {
    // Poll in 100ms increments so we exit promptly once the child finishes
    const poll_ns: u64 = 100 * std.time.ns_per_ms;
    var elapsed_ns: u64 = 0;
    const deadline_ns: u64 = timeout_ms * std.time.ns_per_ms;

    while (elapsed_ns < deadline_ns) {
        if (done.load(.acquire)) return;
        std.Thread.sleep(poll_ns);
        elapsed_ns += poll_ns;
    }

    // Timeout reached — kill the child if still running
    if (!done.load(.acquire)) {
        _ = child.kill() catch {};
    }
}

// ── Tests ─────────────────────────────────────────────────────────────

test "sanitizeId replaces invalid chars" {
    const allocator = std.testing.allocator;
    const result = try sanitizeId(allocator, "FEAT-123/branch");
    defer allocator.free(result);
    try std.testing.expectEqualStrings("FEAT-123_branch", result);
}

test "sanitizeId keeps valid chars" {
    const allocator = std.testing.allocator;
    const result = try sanitizeId(allocator, "task_123.abc-def");
    defer allocator.free(result);
    try std.testing.expectEqualStrings("task_123.abc-def", result);
}

test "sanitizeId replaces multiple invalid chars" {
    const allocator = std.testing.allocator;
    const result = try sanitizeId(allocator, "a/../b");
    defer allocator.free(result);
    try std.testing.expectEqualStrings("a_.._b", result);
}

test "Workspace create and remove" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(root);

    const ws = try Workspace.create(allocator, root, "test-task");
    defer allocator.free(ws.path);

    // Workspace was freshly created
    try std.testing.expect(ws.created);

    // Directory should exist
    var dir = try std.fs.cwd().openDir(ws.path, .{});
    dir.close();

    // Remove it
    ws.remove();

    // Directory should no longer exist
    const open_result = std.fs.cwd().openDir(ws.path, .{});
    try std.testing.expectError(error.FileNotFound, open_result);
}

test "runHook executes shell command" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const cwd = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(cwd);

    // Run a command that creates a file
    const ok = try runHook(allocator, "echo hello > test.txt", cwd, 5000);
    try std.testing.expect(ok);

    // Verify the file was created
    const contents = try tmp.dir.readFileAlloc(allocator, "test.txt", 1024);
    defer allocator.free(contents);
    try std.testing.expectEqualStrings("hello\n", contents);
}

test "runHook returns false for failing command" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const cwd = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(cwd);

    const ok = try runHook(allocator, "exit 1", cwd, 5000);
    try std.testing.expect(!ok);
}

test "cleanAll removes all subdirectories" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(root);

    // Create some fake workspace dirs
    try tmp.dir.makeDir("task-001");
    try tmp.dir.makeDir("task-002");

    cleanAll(root);

    // Verify they're gone
    try std.testing.expectError(error.FileNotFound, tmp.dir.openDir("task-001", .{}));
    try std.testing.expectError(error.FileNotFound, tmp.dir.openDir("task-002", .{}));
}

test "validateWorkspacePath accepts safe path" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(root);

    // Create a subdirectory
    try tmp.dir.makeDir("safe-task");
    const sub_path = try std.fs.path.join(allocator, &.{ root, "safe-task" });
    defer allocator.free(sub_path);

    try std.testing.expect(validateWorkspacePath(allocator, root, sub_path));
}

test "validateWorkspacePath rejects path outside root" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(root);

    // /tmp is definitely not under the test temp dir
    try std.testing.expect(!validateWorkspacePath(allocator, root, "/tmp"));
}

test "sanitizeDirectoryName replaces invalid chars" {
    const allocator = std.testing.allocator;
    const result = try sanitizeDirectoryName(allocator, "../../etc/passwd");
    defer allocator.free(result);
    try std.testing.expectEqualStrings(".._.._etc_passwd", result);
}
