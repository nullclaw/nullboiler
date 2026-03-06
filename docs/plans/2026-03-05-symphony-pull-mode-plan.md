# Symphony Pull-Mode Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Add a pull-mode to NullBoiler that polls NullTickets for tasks, creates isolated workspaces, and runs NullClaw agents as subprocesses or dispatches to existing workers.

**Architecture:** New Tracker thread conditionally spawned when `config.tracker` is present. Polls NullTickets API, claims tasks, manages workspaces and NullClaw subprocesses. In-memory state (no new DB tables). Observability API endpoints for NullHub dashboard.

**Tech Stack:** Zig 0.15.2, std.http.Client (NullTickets API), std.process.Child (subprocess), std.json, existing SQLite store (unchanged).

---

### Task 1: TrackerConfig in config.zig

**Files:**
- Modify: `src/config.zig`

**Step 1: Write the failing test**

Add to `src/config.zig` at the end of the test section:

```zig
test "TrackerConfig defaults" {
    const tc = TrackerConfig{};
    try std.testing.expectEqual(@as(?[]const u8, null), tc.url);
    try std.testing.expectEqual(@as(u32, 10000), tc.poll_interval_ms);
    try std.testing.expectEqual(@as(u32, 10), tc.concurrency.max_concurrent_tasks);
    try std.testing.expectEqual(@as(u32, 300000), tc.stall_timeout_ms);
    try std.testing.expectEqual(@as(u32, 60000), tc.lease_ttl_ms);
    try std.testing.expectEqual(@as(u32, 30000), tc.heartbeat_interval_ms);
    try std.testing.expectEqualStrings("workflows", tc.workflows_dir);
}

test "Config with tracker null by default" {
    const cfg = Config{};
    try std.testing.expectEqual(@as(?TrackerConfig, null), cfg.tracker);
}
```

**Step 2: Run test to verify it fails**

Run: `zig build test 2>&1 | head -30`
Expected: FAIL — `TrackerConfig` not defined

**Step 3: Write minimal implementation**

Add these structs before `Config` in `src/config.zig`:

```zig
pub const ConcurrencyConfig = struct {
    max_concurrent_tasks: u32 = 10,
    per_pipeline: ?std.json.Value = null,
    per_role: ?std.json.Value = null,
};

pub const WorkspaceHooksConfig = struct {
    after_create: ?[]const u8 = null,
    before_run: ?[]const u8 = null,
    after_run: ?[]const u8 = null,
    before_remove: ?[]const u8 = null,
};

pub const WorkspaceConfig = struct {
    root: []const u8 = "/tmp/nullboiler-workspaces",
    hooks: WorkspaceHooksConfig = .{},
    hook_timeout_ms: u32 = 30000,
};

pub const SubprocessDefaults = struct {
    command: []const u8 = "nullclaw",
    max_turns: u32 = 20,
    turn_timeout_ms: u32 = 600000,
};

pub const TrackerConfig = struct {
    url: ?[]const u8 = null,
    api_token: ?[]const u8 = null,
    poll_interval_ms: u32 = 10000,
    agent_id: []const u8 = "nullboiler",
    concurrency: ConcurrencyConfig = .{},
    workspace: WorkspaceConfig = .{},
    subprocess: SubprocessDefaults = .{},
    stall_timeout_ms: u32 = 300000,
    lease_ttl_ms: u32 = 60000,
    heartbeat_interval_ms: u32 = 30000,
    workflows_dir: []const u8 = "workflows",
};
```

Add `tracker` field to `Config` struct:

```zig
pub const Config = struct {
    host: []const u8 = "127.0.0.1",
    port: u16 = 8080,
    db: []const u8 = "nullboiler.db",
    api_token: ?[]const u8 = null,
    strategies_dir: []const u8 = "strategies",
    workers: []const WorkerConfig = &.{},
    engine: EngineConfig = .{},
    tracker: ?TrackerConfig = null,
};
```

**Step 4: Run test to verify it passes**

Run: `zig build test 2>&1 | tail -5`
Expected: All tests pass

**Step 5: Commit**

```bash
git add src/config.zig
git commit -m "feat: add TrackerConfig for pull-mode NullTickets integration"
```

---

### Task 2: Workflow Loader (workflow_loader.zig)

**Files:**
- Create: `src/workflow_loader.zig`
- Modify: `src/main.zig` (add comptime import)

**Step 1: Write the test file with failing tests**

Create `src/workflow_loader.zig`:

```zig
const std = @import("std");

pub const ExecutionMode = enum {
    subprocess,
    dispatch,
};

pub const SubprocessConfig = struct {
    command: []const u8 = "nullclaw",
    args: []const []const u8 = &.{},
    max_turns: u32 = 20,
    turn_timeout_ms: u32 = 600000,
};

pub const DispatchConfig = struct {
    worker_tags: []const []const u8 = &.{},
    protocol: []const u8 = "webhook",
};

pub const TransitionConfig = struct {
    transition_to: ?[]const u8 = null,
};

pub const WorkflowDef = struct {
    id: []const u8,
    pipeline_id: []const u8,
    claim_roles: []const []const u8 = &.{},
    execution: ExecutionMode = .subprocess,
    subprocess: SubprocessConfig = .{},
    dispatch: DispatchConfig = .{},
    prompt_template: []const u8 = "",
    on_success: TransitionConfig = .{},
    on_failure: TransitionConfig = .{},
};

pub const WorkflowMap = std.StringArrayHashMapUnmanaged(WorkflowDef);

pub fn loadWorkflows(allocator: std.mem.Allocator, dir_path: []const u8) WorkflowMap {
    var map: WorkflowMap = .{};
    const dir = std.fs.cwd().openDir(dir_path, .{ .iterate = true }) catch return map;
    defer dir.close();

    var iter = dir.iterate();
    while (iter.next() catch null) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".json")) continue;

        const file = dir.openFile(entry.name, .{}) catch continue;
        defer file.close();
        const contents = file.readToEndAlloc(allocator, 1024 * 1024) catch continue;
        const parsed = std.json.parseFromSlice(WorkflowDef, allocator, contents, .{}) catch continue;
        map.put(allocator, parsed.value.id, parsed.value) catch continue;
    }

    return map;
}

pub fn getWorkflowForPipeline(map: *const WorkflowMap, pipeline_id: []const u8) ?*const WorkflowDef {
    for (map.values()) |*wf| {
        if (std.mem.eql(u8, wf.pipeline_id, pipeline_id)) return wf;
    }
    return null;
}

// ── Tests ──────────────────────────────────────────────────────────────

test "WorkflowDef defaults" {
    const wf = WorkflowDef{ .id = "test", .pipeline_id = "p1" };
    try std.testing.expectEqualStrings("test", wf.id);
    try std.testing.expectEqualStrings("p1", wf.pipeline_id);
    try std.testing.expectEqual(ExecutionMode.subprocess, wf.execution);
    try std.testing.expectEqual(@as(u32, 20), wf.subprocess.max_turns);
}

test "loadWorkflows returns empty map for nonexistent dir" {
    const allocator = std.testing.allocator;
    var map = loadWorkflows(allocator, "nonexistent_workflows_dir_12345");
    defer map.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 0), map.count());
}

test "loadWorkflows loads JSON file" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const wf_json =
        \\{"id":"code-review","pipeline_id":"pipeline-cr","claim_roles":["reviewer"],"execution":"subprocess","prompt_template":"Review this code"}
    ;
    try tmp.dir.writeFile(.{ .sub_path = "code-review.json", .data = wf_json });

    const tmp_path = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(tmp_path);

    var map = loadWorkflows(allocator, tmp_path);
    defer map.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 1), map.count());
    const wf = map.get("code-review");
    try std.testing.expect(wf != null);
    try std.testing.expectEqualStrings("pipeline-cr", wf.?.pipeline_id);
    try std.testing.expectEqualStrings("Review this code", wf.?.prompt_template);
}

test "getWorkflowForPipeline finds matching workflow" {
    const allocator = std.testing.allocator;
    var map: WorkflowMap = .{};
    defer map.deinit(allocator);

    const wf = WorkflowDef{ .id = "w1", .pipeline_id = "p1" };
    try map.put(allocator, wf.id, wf);

    const found = getWorkflowForPipeline(&map, "p1");
    try std.testing.expect(found != null);
    try std.testing.expectEqualStrings("w1", found.?.id);
}

test "getWorkflowForPipeline returns null for no match" {
    const allocator = std.testing.allocator;
    var map: WorkflowMap = .{};
    defer map.deinit(allocator);

    const found = getWorkflowForPipeline(&map, "nonexistent");
    try std.testing.expect(found == null);
}
```

**Step 2: Add comptime import to main.zig**

Add to the `comptime` block at the bottom of `src/main.zig`:

```zig
_ = @import("workflow_loader.zig");
```

**Step 3: Run tests**

Run: `zig build test 2>&1 | tail -5`
Expected: All tests pass

**Step 4: Commit**

```bash
git add src/workflow_loader.zig src/main.zig
git commit -m "feat: add workflow_loader for JSON workflow definitions"
```

---

### Task 3: Tracker Client (tracker_client.zig)

**Files:**
- Create: `src/tracker_client.zig`
- Modify: `src/main.zig` (add comptime import)

**Step 1: Create tracker_client.zig with types and tests**

```zig
const std = @import("std");
const ids = @import("ids.zig");

// ── Response Types ────────────────────────────────────────────────────

pub const TaskInfo = struct {
    id: []const u8 = "",
    title: []const u8 = "",
    description: []const u8 = "",
    stage: []const u8 = "",
    pipeline_id: []const u8 = "",
    priority: i64 = 0,
    metadata_json: []const u8 = "{}",
};

pub const RunInfo = struct {
    id: []const u8 = "",
    attempt: i64 = 1,
};

pub const ClaimResponse = struct {
    task: TaskInfo = .{},
    run: RunInfo = .{},
    lease_id: []const u8 = "",
    lease_token: []const u8 = "",
};

pub const QueueStats = struct {
    role: []const u8 = "",
    claimable: i64 = 0,
};

// ── Client ────────────────────────────────────────────────────────────

pub const TrackerClient = struct {
    allocator: std.mem.Allocator,
    base_url: []const u8,
    api_token: ?[]const u8,

    pub fn init(allocator: std.mem.Allocator, base_url: []const u8, api_token: ?[]const u8) TrackerClient {
        return .{
            .allocator = allocator,
            .base_url = base_url,
            .api_token = api_token,
        };
    }

    pub fn claim(self: *TrackerClient, agent_id: []const u8, agent_role: []const u8, lease_ttl_ms: u32) !?ClaimResponse {
        const url = try std.fmt.allocPrint(self.allocator, "{s}/leases/claim", .{self.base_url});
        defer self.allocator.free(url);

        const body = try std.json.Stringify.valueAlloc(self.allocator, .{
            .agent_id = agent_id,
            .agent_role = agent_role,
            .lease_ttl_ms = lease_ttl_ms,
        }, .{});
        defer self.allocator.free(body);

        const response = self.httpPost(url, body) catch return null;
        if (response.status_code == 204) {
            self.allocator.free(response.body);
            return null;
        }
        if (response.status_code < 200 or response.status_code >= 300) {
            self.allocator.free(response.body);
            return null;
        }

        const parsed = std.json.parseFromSlice(ClaimResponse, self.allocator, response.body, .{}) catch {
            self.allocator.free(response.body);
            return null;
        };
        _ = parsed; // data owned by arena
        // Re-parse to get the value (caller uses arena allocator)
        const p2 = std.json.parseFromSlice(ClaimResponse, self.allocator, response.body, .{}) catch return null;
        return p2.value;
    }

    pub fn heartbeat(self: *TrackerClient, lease_id: []const u8, lease_token: []const u8) !bool {
        const url = try std.fmt.allocPrint(self.allocator, "{s}/leases/{s}/heartbeat", .{ self.base_url, lease_id });
        defer self.allocator.free(url);

        const response = self.httpPostWithToken(url, "{}", lease_token) catch return false;
        self.allocator.free(response.body);
        return response.status_code >= 200 and response.status_code < 300;
    }

    pub fn transition(self: *TrackerClient, run_id: []const u8, next_stage: []const u8, lease_token: []const u8) !bool {
        const url = try std.fmt.allocPrint(self.allocator, "{s}/runs/{s}/transition", .{ self.base_url, run_id });
        defer self.allocator.free(url);

        const body = try std.json.Stringify.valueAlloc(self.allocator, .{
            .next_stage = next_stage,
        }, .{});
        defer self.allocator.free(body);

        const response = self.httpPostWithToken(url, body, lease_token) catch return false;
        self.allocator.free(response.body);
        return response.status_code >= 200 and response.status_code < 300;
    }

    pub fn failRun(self: *TrackerClient, run_id: []const u8, reason: []const u8, lease_token: []const u8) !bool {
        const url = try std.fmt.allocPrint(self.allocator, "{s}/runs/{s}/fail", .{ self.base_url, run_id });
        defer self.allocator.free(url);

        const body = try std.json.Stringify.valueAlloc(self.allocator, .{
            .reason = reason,
        }, .{});
        defer self.allocator.free(body);

        const response = self.httpPostWithToken(url, body, lease_token) catch return false;
        self.allocator.free(response.body);
        return response.status_code >= 200 and response.status_code < 300;
    }

    pub fn postArtifact(self: *TrackerClient, task_id: []const u8, name: []const u8, content: []const u8) !bool {
        const url = try std.fmt.allocPrint(self.allocator, "{s}/artifacts", .{self.base_url});
        defer self.allocator.free(url);

        const body = try std.json.Stringify.valueAlloc(self.allocator, .{
            .task_id = task_id,
            .kind = name,
            .uri = "inline://output",
            .meta_json = content,
        }, .{});
        defer self.allocator.free(body);

        const response = self.httpPost(url, body) catch return false;
        self.allocator.free(response.body);
        return response.status_code >= 200 and response.status_code < 300;
    }

    pub fn getTask(self: *TrackerClient, task_id: []const u8) !?TaskInfo {
        const url = try std.fmt.allocPrint(self.allocator, "{s}/tasks/{s}", .{ self.base_url, task_id });
        defer self.allocator.free(url);

        const response = self.httpGet(url) catch return null;
        if (response.status_code < 200 or response.status_code >= 300) {
            self.allocator.free(response.body);
            return null;
        }

        const parsed = std.json.parseFromSlice(TaskInfo, self.allocator, response.body, .{}) catch {
            self.allocator.free(response.body);
            return null;
        };
        return parsed.value;
    }

    pub fn getQueueStats(self: *TrackerClient) ![]const u8 {
        const url = try std.fmt.allocPrint(self.allocator, "{s}/ops/queue", .{self.base_url});
        defer self.allocator.free(url);

        const response = self.httpGet(url) catch return "[]";
        return response.body;
    }

    // ── HTTP helpers ──────────────────────────────────────────────────

    const HttpResult = struct {
        status_code: u16,
        body: []const u8,
    };

    fn httpPost(self: *TrackerClient, url: []const u8, body: []const u8) !HttpResult {
        return self.httpRequest(url, .POST, body, null);
    }

    fn httpPostWithToken(self: *TrackerClient, url: []const u8, body: []const u8, bearer_token: []const u8) !HttpResult {
        return self.httpRequest(url, .POST, body, bearer_token);
    }

    fn httpGet(self: *TrackerClient, url: []const u8) !HttpResult {
        return self.httpRequest(url, .GET, null, null);
    }

    fn httpRequest(self: *TrackerClient, url: []const u8, method: std.http.Method, body: ?[]const u8, bearer_override: ?[]const u8) !HttpResult {
        var client: std.http.Client = .{ .allocator = self.allocator };
        defer client.deinit();

        var response_body: std.io.Writer.Allocating = .init(self.allocator);
        errdefer response_body.deinit();

        // Build auth header
        var headers_buf: [1]std.http.Header = undefined;
        const token = bearer_override orelse self.api_token;
        var auth_str: ?[]const u8 = null;
        defer if (auth_str) |a| self.allocator.free(a);

        var extra_headers: []const std.http.Header = &.{};
        if (token) |t| {
            auth_str = try std.fmt.allocPrint(self.allocator, "Bearer {s}", .{t});
            headers_buf[0] = .{ .name = "Authorization", .value = auth_str.? };
            extra_headers = headers_buf[0..1];
        }

        const result = try client.fetch(.{
            .location = .{ .url = url },
            .method = method,
            .payload = body,
            .response_writer = &response_body.writer,
            .extra_headers = extra_headers,
            .headers = .{
                .content_type = .{ .override = "application/json" },
            },
        });

        const status_code = @intFromEnum(result.status);
        return HttpResult{
            .status_code = @intCast(status_code),
            .body = response_body.toOwnedSlice() catch "",
        };
    }
};

// ── Tests ──────────────────────────────────────────────────────────────

test "TrackerClient init" {
    const allocator = std.testing.allocator;
    const client = TrackerClient.init(allocator, "http://localhost:8070", "test-token");
    try std.testing.expectEqualStrings("http://localhost:8070", client.base_url);
    try std.testing.expectEqualStrings("test-token", client.api_token.?);
}

test "TaskInfo defaults" {
    const info = TaskInfo{};
    try std.testing.expectEqualStrings("", info.id);
    try std.testing.expectEqualStrings("{}", info.metadata_json);
    try std.testing.expectEqual(@as(i64, 0), info.priority);
}

test "ClaimResponse defaults" {
    const cr = ClaimResponse{};
    try std.testing.expectEqualStrings("", cr.lease_id);
    try std.testing.expectEqualStrings("", cr.task.id);
    try std.testing.expectEqual(@as(i64, 1), cr.run.attempt);
}
```

**Step 2: Add comptime import to main.zig**

```zig
_ = @import("tracker_client.zig");
```

**Step 3: Run tests**

Run: `zig build test 2>&1 | tail -5`
Expected: All tests pass

**Step 4: Commit**

```bash
git add src/tracker_client.zig src/main.zig
git commit -m "feat: add tracker_client HTTP client for NullTickets API"
```

---

### Task 4: Workspace Manager (workspace.zig)

**Files:**
- Create: `src/workspace.zig`
- Modify: `src/main.zig` (add comptime import)

**Step 1: Create workspace.zig**

```zig
const std = @import("std");
const log = std.log.scoped(.workspace);

pub const Workspace = struct {
    root: []const u8,
    task_id: []const u8,
    path: []const u8,
    created: bool,

    pub fn create(allocator: std.mem.Allocator, root: []const u8, task_id: []const u8) !Workspace {
        const sanitized = try sanitizeId(allocator, task_id);
        defer allocator.free(sanitized);

        const path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ root, sanitized });

        // Ensure root exists
        std.fs.cwd().makePath(root) catch |err| {
            log.err("failed to create workspace root {s}: {}", .{ root, err });
            return err;
        };

        // Create workspace dir
        var created = false;
        std.fs.cwd().makePath(path) catch |err| {
            log.err("failed to create workspace {s}: {}", .{ path, err });
            return err;
        };
        // Check if dir was just created (no files yet) vs reused
        var dir = try std.fs.cwd().openDir(path, .{ .iterate = true });
        defer dir.close();
        var iter = dir.iterate();
        created = (iter.next() catch null) == null;

        return .{
            .root = root,
            .task_id = task_id,
            .path = path,
            .created = created,
        };
    }

    pub fn remove(self: *const Workspace) void {
        std.fs.cwd().deleteTree(self.path) catch |err| {
            log.warn("failed to remove workspace {s}: {}", .{ self.path, err });
        };
    }
};

pub fn sanitizeId(allocator: std.mem.Allocator, id: []const u8) ![]const u8 {
    var buf = try allocator.alloc(u8, id.len);
    for (id, 0..) |c, i| {
        buf[i] = if (std.ascii.isAlphanumeric(c) or c == '.' or c == '_' or c == '-') c else '_';
    }
    return buf;
}

pub fn runHook(allocator: std.mem.Allocator, command: []const u8, cwd: []const u8, timeout_ms: u32) !bool {
    _ = timeout_ms; // TODO: implement timeout via separate thread
    const argv = [_][]const u8{ "/bin/sh", "-lc", command };

    var child = std.process.Child.init(.{
        .argv = &argv,
        .allocator = allocator,
        .cwd = cwd,
        .stdout_behavior = .Pipe,
        .stderr_behavior = .Pipe,
    });
    try child.spawn();

    const result = try child.wait();
    return result.Exited == 0;
}

// ── Tests ──────────────────────────────────────────────────────────────

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

test "Workspace create and remove" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(root);

    var ws = try Workspace.create(allocator, root, "test-task-1");
    defer allocator.free(ws.path);

    // Verify directory exists
    const dir = std.fs.cwd().openDir(ws.path, .{}) catch {
        try std.testing.expect(false); // dir should exist
        return;
    };
    dir.close();

    try std.testing.expect(ws.created);

    ws.remove();

    // Verify directory removed
    const result = std.fs.cwd().openDir(ws.path, .{});
    try std.testing.expectError(error.FileNotFound, result);
}

test "runHook executes shell command" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const cwd = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(cwd);

    const success = try runHook(allocator, "echo hello > test.txt", cwd, 5000);
    try std.testing.expect(success);

    // Verify file was created
    const content = try tmp.dir.readFileAlloc(allocator, "test.txt", 1024);
    defer allocator.free(content);
    try std.testing.expect(std.mem.startsWith(u8, content, "hello"));
}
```

**Step 2: Add comptime import**

```zig
_ = @import("workspace.zig");
```

**Step 3: Run tests**

Run: `zig build test 2>&1 | tail -5`
Expected: All tests pass

**Step 4: Commit**

```bash
git add src/workspace.zig src/main.zig
git commit -m "feat: add workspace manager with sanitization and shell hooks"
```

---

### Task 5: Subprocess Manager (subprocess.zig)

**Files:**
- Create: `src/subprocess.zig`
- Modify: `src/main.zig` (add comptime import)

**Step 1: Create subprocess.zig**

```zig
const std = @import("std");
const ids = @import("ids.zig");
const log = std.log.scoped(.subprocess);

pub const SubprocessState = enum {
    starting,
    running,
    done,
    failed,
    stalled,
};

pub const SubprocessInfo = struct {
    task_id: []const u8,
    lease_id: []const u8,
    lease_token: []const u8,
    workspace_path: []const u8,
    pipeline_id: []const u8,
    agent_role: []const u8,
    port: u16,
    child: ?std.process.Child,
    current_turn: u32,
    max_turns: u32,
    started_at_ms: i64,
    last_activity_ms: i64,
    state: SubprocessState,
    last_output: ?[]const u8,
    run_id: []const u8,
    task_title: []const u8,
    task_identifier: []const u8,
    execution_mode: []const u8, // "subprocess" or "dispatch"
};

pub fn spawnNullClaw(
    allocator: std.mem.Allocator,
    command: []const u8,
    args: []const []const u8,
    port: u16,
    workspace_path: []const u8,
) !std.process.Child {
    var argv_list: std.ArrayListUnmanaged([]const u8) = .empty;
    defer argv_list.deinit(allocator);

    try argv_list.append(allocator, command);
    for (args) |arg| {
        try argv_list.append(allocator, arg);
    }

    var port_buf: [8]u8 = undefined;
    const port_str = std.fmt.bufPrint(&port_buf, "{d}", .{port}) catch unreachable;
    try argv_list.append(allocator, "--port");
    try argv_list.append(allocator, port_str);
    try argv_list.append(allocator, "--workdir");
    try argv_list.append(allocator, workspace_path);

    var child = std.process.Child.init(.{
        .argv = argv_list.items,
        .allocator = allocator,
        .cwd = workspace_path,
        .stdout_behavior = .Pipe,
        .stderr_behavior = .Pipe,
    });
    try child.spawn();
    return child;
}

pub fn waitForHealth(allocator: std.mem.Allocator, port: u16, max_retries: u32) bool {
    const url = std.fmt.allocPrint(allocator, "http://127.0.0.1:{d}/health", .{port}) catch return false;
    defer allocator.free(url);

    var attempt: u32 = 0;
    while (attempt < max_retries) : (attempt += 1) {
        var client: std.http.Client = .{ .allocator = allocator };
        defer client.deinit();

        var response_body: std.io.Writer.Allocating = .init(allocator);
        defer response_body.deinit();

        const result = client.fetch(.{
            .location = .{ .url = url },
            .method = .GET,
            .response_writer = &response_body.writer,
        }) catch {
            std.Thread.sleep(500 * std.time.ns_per_ms);
            continue;
        };

        const status = @intFromEnum(result.status);
        if (status >= 200 and status < 300) return true;
        std.Thread.sleep(500 * std.time.ns_per_ms);
    }

    return false;
}

pub fn sendPrompt(allocator: std.mem.Allocator, port: u16, prompt: []const u8) !?[]const u8 {
    const url = std.fmt.allocPrint(allocator, "http://127.0.0.1:{d}/task", .{port}) catch return null;
    defer allocator.free(url);

    const body = std.json.Stringify.valueAlloc(allocator, .{
        .message = prompt,
    }, .{}) catch return null;
    defer allocator.free(body);

    var client: std.http.Client = .{ .allocator = allocator };
    defer client.deinit();

    var response_body: std.io.Writer.Allocating = .init(allocator);
    defer response_body.deinit();

    const result = client.fetch(.{
        .location = .{ .url = url },
        .method = .POST,
        .payload = body,
        .response_writer = &response_body.writer,
        .headers = .{
            .content_type = .{ .override = "application/json" },
        },
    }) catch return null;

    const status = @intFromEnum(result.status);
    if (status < 200 or status >= 300) return null;

    const data = response_body.toOwnedSlice() catch return null;
    return data;
}

pub fn killSubprocess(child: *std.process.Child) void {
    _ = child.kill() catch {};
    _ = child.wait() catch {};
}

pub fn isStalled(info: *const SubprocessInfo, stall_timeout_ms: u32) bool {
    const now = ids.nowMs();
    const elapsed = now - info.last_activity_ms;
    return elapsed > @as(i64, @intCast(stall_timeout_ms));
}

// ── Tests ──────────────────────────────────────────────────────────────

test "SubprocessInfo defaults" {
    const info = SubprocessInfo{
        .task_id = "t1",
        .lease_id = "l1",
        .lease_token = "tok",
        .workspace_path = "/tmp/ws",
        .pipeline_id = "p1",
        .agent_role = "coder",
        .port = 9201,
        .child = null,
        .current_turn = 0,
        .max_turns = 20,
        .started_at_ms = 1000,
        .last_activity_ms = 1000,
        .state = .starting,
        .last_output = null,
        .run_id = "r1",
        .task_title = "Test",
        .task_identifier = "TST-1",
        .execution_mode = "subprocess",
    };
    try std.testing.expectEqualStrings("t1", info.task_id);
    try std.testing.expectEqual(SubprocessState.starting, info.state);
}

test "isStalled detects timeout" {
    const info = SubprocessInfo{
        .task_id = "t1",
        .lease_id = "l1",
        .lease_token = "tok",
        .workspace_path = "/tmp",
        .pipeline_id = "p1",
        .agent_role = "coder",
        .port = 0,
        .child = null,
        .current_turn = 0,
        .max_turns = 20,
        .started_at_ms = 0,
        .last_activity_ms = 0, // very old
        .state = .running,
        .last_output = null,
        .run_id = "r1",
        .task_title = "Test",
        .task_identifier = "TST-1",
        .execution_mode = "subprocess",
    };
    try std.testing.expect(isStalled(&info, 1000));
}
```

**Step 2: Add comptime import**

```zig
_ = @import("subprocess.zig");
```

**Step 3: Run tests**

Run: `zig build test 2>&1 | tail -5`
Expected: All tests pass

**Step 4: Commit**

```bash
git add src/subprocess.zig src/main.zig
git commit -m "feat: add subprocess manager for NullClaw child processes"
```

---

### Task 6: Task Template Variables in templates.zig

**Files:**
- Modify: `src/templates.zig`

**Step 1: Write failing tests**

Add to end of test section in `src/templates.zig`:

```zig
test "render task.title variable" {
    const allocator = std.testing.allocator;
    const result = try render(allocator, "Work on: {{task.title}}", .{
        .input_json = "{}",
        .step_outputs = &.{},
        .item = null,
        .task_json = "{\"title\":\"Fix login bug\",\"description\":\"Users cannot log in\"}",
    });
    defer allocator.free(result);
    try std.testing.expectEqualStrings("Work on: Fix login bug", result);
}

test "render task.description variable" {
    const allocator = std.testing.allocator;
    const result = try render(allocator, "{{task.description}}", .{
        .input_json = "{}",
        .step_outputs = &.{},
        .item = null,
        .task_json = "{\"title\":\"Fix\",\"description\":\"Users cannot log in\"}",
    });
    defer allocator.free(result);
    try std.testing.expectEqualStrings("Users cannot log in", result);
}

test "render task.metadata.X variable" {
    const allocator = std.testing.allocator;
    const result = try render(allocator, "Repo: {{task.metadata.repo_url}}", .{
        .input_json = "{}",
        .step_outputs = &.{},
        .item = null,
        .task_json = "{\"title\":\"T\",\"description\":\"D\",\"metadata\":{\"repo_url\":\"https://github.com/org/repo\"}}",
    });
    defer allocator.free(result);
    try std.testing.expectEqualStrings("Repo: https://github.com/org/repo", result);
}
```

**Step 2: Run tests to verify they fail**

Run: `zig build test 2>&1 | head -20`
Expected: FAIL — `task_json` not a field of Context

**Step 3: Implement**

Add `task_json` field to `Context`:

```zig
pub const Context = struct {
    input_json: []const u8,
    step_outputs: []const StepOutput,
    item: ?[]const u8,
    debate_responses: ?[]const u8 = null,
    chat_history: ?[]const u8 = null,
    role: ?[]const u8 = null,
    task_json: ?[]const u8 = null, // NEW: NullTickets task data for pull-mode

    // ... StepOutput unchanged
};
```

Add task resolution to `resolveExpression`, before the `return error.UnknownExpression` at the end:

```zig
    if (std.mem.startsWith(u8, expr, "task.")) {
        const field = expr["task.".len..];
        if (ctx.task_json) |tj| {
            return resolveTaskField(allocator, tj, field);
        }
        return error.UnknownExpression;
    }
```

Add the resolver function:

```zig
fn resolveTaskField(allocator: std.mem.Allocator, task_json: []const u8, field_path: []const u8) RenderError![]const u8 {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, task_json, .{}) catch {
        return error.InvalidInputJson;
    };
    defer parsed.deinit();

    const root = parsed.value;
    if (root != .object) return error.InvalidInputJson;

    // Handle nested paths like "metadata.repo_url"
    var current = root;
    var path_iter = std.mem.splitScalar(u8, field_path, '.');
    while (path_iter.next()) |segment| {
        if (current != .object) return error.InputFieldNotFound;
        current = current.object.get(segment) orelse return error.InputFieldNotFound;
    }

    return jsonValueToString(allocator, current);
}
```

**Step 4: Run tests**

Run: `zig build test 2>&1 | tail -5`
Expected: All tests pass

**Step 5: Commit**

```bash
git add src/templates.zig
git commit -m "feat: add task.* template variables for pull-mode prompts"
```

---

### Task 7: Tracker Types in types.zig

**Files:**
- Modify: `src/types.zig`

**Step 1: Write failing test**

Add to `src/types.zig`:

```zig
test "TrackerTaskState round-trip" {
    const s = TrackerTaskState.running;
    try std.testing.expectEqualStrings("running", s.toString());
    try std.testing.expectEqual(TrackerTaskState.running, TrackerTaskState.fromString("running").?);
}
```

**Step 2: Run test to verify it fails**

**Step 3: Implement**

Add at end of enums section in `src/types.zig`:

```zig
pub const TrackerTaskState = enum {
    claiming,
    workspace_setup,
    running,
    completing,
    completed,
    failed,
    stalled,
    cooldown,

    pub fn toString(self: TrackerTaskState) []const u8 {
        return @tagName(self);
    }

    pub fn fromString(s: []const u8) ?TrackerTaskState {
        inline for (@typeInfo(TrackerTaskState).@"enum".fields) |f| {
            if (std.mem.eql(u8, s, f.name)) return @enumFromInt(f.value);
        }
        return null;
    }
};
```

**Step 4: Run tests**

Run: `zig build test 2>&1 | tail -5`
Expected: All tests pass

**Step 5: Commit**

```bash
git add src/types.zig
git commit -m "feat: add TrackerTaskState enum for pull-mode task lifecycle"
```

---

### Task 8: Tracker Thread (tracker.zig) — Core Loop

**Files:**
- Create: `src/tracker.zig`
- Modify: `src/main.zig` (add comptime import)

**Step 1: Create tracker.zig with state management and core loop**

```zig
const std = @import("std");
const log = std.log.scoped(.tracker);

const ids = @import("ids.zig");
const config = @import("config.zig");
const subprocess_mod = @import("subprocess.zig");
const tracker_client = @import("tracker_client.zig");
const workspace_mod = @import("workspace.zig");
const workflow_loader = @import("workflow_loader.zig");
const templates = @import("templates.zig");
const dispatch = @import("dispatch.zig");
const types = @import("types.zig");
const Store = @import("store.zig").Store;

// ── Tracker State ─────────────────────────────────────────────────────

pub const RunningTask = struct {
    task_id: []const u8,
    task_title: []const u8,
    task_identifier: []const u8,
    pipeline_id: []const u8,
    agent_role: []const u8,
    lease_id: []const u8,
    lease_token: []const u8,
    run_id: []const u8,
    workspace_path: []const u8,
    execution_mode: []const u8,
    subprocess: ?subprocess_mod.SubprocessInfo,
    started_at_ms: i64,
    last_activity_ms: i64,
    current_turn: u32,
    max_turns: u32,
    state: types.TrackerTaskState,
};

pub const CooldownEntry = struct {
    task_id: []const u8,
    until_ms: i64,
};

pub const TrackerState = struct {
    running: std.StringArrayHashMapUnmanaged(RunningTask),
    completed_count: u64,
    failed_count: u64,
    cooldowns: std.StringArrayHashMapUnmanaged(i64), // task_id → cooldown_until_ms

    pub fn init() TrackerState {
        return .{
            .running = .{},
            .completed_count = 0,
            .failed_count = 0,
            .cooldowns = .{},
        };
    }

    pub fn deinit(self: *TrackerState, allocator: std.mem.Allocator) void {
        self.running.deinit(allocator);
        self.cooldowns.deinit(allocator);
    }

    pub fn runningCount(self: *const TrackerState) usize {
        return self.running.count();
    }

    pub fn countByPipeline(self: *const TrackerState, pipeline_id: []const u8) usize {
        var count: usize = 0;
        for (self.running.values()) |task| {
            if (std.mem.eql(u8, task.pipeline_id, pipeline_id)) count += 1;
        }
        return count;
    }

    pub fn countByRole(self: *const TrackerState, role: []const u8) usize {
        var count: usize = 0;
        for (self.running.values()) |task| {
            if (std.mem.eql(u8, task.agent_role, role)) count += 1;
        }
        return count;
    }

    pub fn isInCooldown(self: *const TrackerState, task_id: []const u8) bool {
        const until = self.cooldowns.get(task_id) orelse return false;
        return ids.nowMs() < until;
    }
};

// ── Concurrency Check ─────────────────────────────────────────────────

pub fn canClaimMore(state: *const TrackerState, cfg: *const config.ConcurrencyConfig, pipeline_id: []const u8, role: []const u8) bool {
    // Global limit
    if (state.runningCount() >= cfg.max_concurrent_tasks) return false;

    // Per-pipeline limit (checked via JSON value)
    if (cfg.per_pipeline) |pp| {
        if (pp == .object) {
            if (pp.object.get(pipeline_id)) |limit_val| {
                if (limit_val == .integer) {
                    const limit: usize = @intCast(limit_val.integer);
                    if (state.countByPipeline(pipeline_id) >= limit) return false;
                }
            }
        }
    }

    // Per-role limit
    if (cfg.per_role) |pr| {
        if (pr == .object) {
            if (pr.object.get(role)) |limit_val| {
                if (limit_val == .integer) {
                    const limit: usize = @intCast(limit_val.integer);
                    if (state.countByRole(role) >= limit) return false;
                }
            }
        }
    }

    return true;
}

// ── Tracker Thread Entry Point ────────────────────────────────────────

pub const Tracker = struct {
    allocator: std.mem.Allocator,
    cfg: config.TrackerConfig,
    state: TrackerState,
    workflows: workflow_loader.WorkflowMap,
    store: *Store,
    shutdown: *std.atomic.Value(bool),
    last_heartbeat_ms: i64,

    pub fn init(
        allocator: std.mem.Allocator,
        cfg: config.TrackerConfig,
        workflows: workflow_loader.WorkflowMap,
        store: *Store,
        shutdown: *std.atomic.Value(bool),
    ) Tracker {
        return .{
            .allocator = allocator,
            .cfg = cfg,
            .state = TrackerState.init(),
            .workflows = workflows,
            .store = store,
            .shutdown = shutdown,
            .last_heartbeat_ms = ids.nowMs(),
        };
    }

    pub fn deinit(self: *Tracker) void {
        self.state.deinit(self.allocator);
    }

    pub fn run(self: *Tracker) void {
        log.info("tracker started (poll_interval={d}ms, max_concurrent={d})", .{
            self.cfg.poll_interval_ms,
            self.cfg.concurrency.max_concurrent_tasks,
        });

        while (!self.shutdown.load(.acquire)) {
            self.tick();
            std.Thread.sleep(@as(u64, self.cfg.poll_interval_ms) * std.time.ns_per_ms);
        }

        self.shutdown_subprocesses();
        log.info("tracker stopped", .{});
    }

    fn tick(self: *Tracker) void {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const alloc = arena.allocator();

        // 1. Heartbeat leases
        const now = ids.nowMs();
        if (now - self.last_heartbeat_ms >= self.cfg.heartbeat_interval_ms) {
            self.heartbeatAll(alloc);
            self.last_heartbeat_ms = now;
        }

        // 2. Stall detection
        self.detectStalls(alloc);

        // 3. Poll and claim
        self.pollAndClaim(alloc);

        // 4. Clean expired cooldowns
        self.cleanCooldowns();
    }

    fn heartbeatAll(self: *Tracker, allocator: std.mem.Allocator) void {
        var client = tracker_client.TrackerClient.init(allocator, self.cfg.url orelse return, self.cfg.api_token);
        var to_remove: std.ArrayListUnmanaged([]const u8) = .empty;
        defer to_remove.deinit(allocator);

        for (self.state.running.keys(), self.state.running.values()) |key, task| {
            const ok = client.heartbeat(task.lease_id, task.lease_token) catch false;
            if (!ok) {
                log.warn("heartbeat failed for task {s}, lease expired", .{key});
                to_remove.append(allocator, key) catch continue;
            }
        }

        for (to_remove.items) |key| {
            if (self.state.running.get(key)) |task| {
                if (task.subprocess) |*sub| {
                    if (sub.child) |*child| {
                        subprocess_mod.killSubprocess(child);
                    }
                }
            }
            _ = self.state.running.orderedRemove(key);
        }
    }

    fn detectStalls(self: *Tracker, allocator: std.mem.Allocator) void {
        var client = tracker_client.TrackerClient.init(allocator, self.cfg.url orelse return, self.cfg.api_token);
        var to_remove: std.ArrayListUnmanaged([]const u8) = .empty;
        defer to_remove.deinit(allocator);

        for (self.state.running.keys(), self.state.running.values()) |key, task| {
            if (task.subprocess) |*sub| {
                if (subprocess_mod.isStalled(sub, self.cfg.stall_timeout_ms)) {
                    log.warn("task {s} stalled (no activity for {d}ms)", .{ key, self.cfg.stall_timeout_ms });
                    _ = client.failRun(task.run_id, "stall_timeout", task.lease_token) catch false;
                    if (sub.child) |*child| {
                        subprocess_mod.killSubprocess(child);
                    }
                    to_remove.append(allocator, key) catch continue;
                    self.state.failed_count += 1;
                }
            }
        }

        for (to_remove.items) |key| {
            _ = self.state.running.orderedRemove(key);
        }
    }

    fn pollAndClaim(self: *Tracker, allocator: std.mem.Allocator) void {
        const url = self.cfg.url orelse return;
        var client = tracker_client.TrackerClient.init(allocator, url, self.cfg.api_token);

        // Claim for each workflow's roles
        for (self.workflows.values()) |wf| {
            for (wf.claim_roles) |role| {
                if (!canClaimMore(&self.state, &self.cfg.concurrency, wf.pipeline_id, role)) continue;

                const claim = client.claim(self.cfg.agent_id, role, self.cfg.lease_ttl_ms) catch continue orelse continue;

                // Skip if in cooldown
                if (self.state.isInCooldown(claim.task.id)) continue;

                log.info("claimed task {s} ({s}) for role {s}", .{ claim.task.id, claim.task.title, role });

                self.startTask(allocator, &wf, &claim, role);
            }
        }
    }

    fn startTask(self: *Tracker, allocator: std.mem.Allocator, wf: *const workflow_loader.WorkflowDef, claim: *const tracker_client.ClaimResponse, role: []const u8) void {
        const now = ids.nowMs();

        // Determine hooks (per-workflow or global)
        const global_hooks = self.cfg.workspace.hooks;

        if (wf.execution == .subprocess) {
            // Create workspace
            const ws = workspace_mod.Workspace.create(allocator, self.cfg.workspace.root, claim.task.id) catch {
                log.err("failed to create workspace for task {s}", .{claim.task.id});
                return;
            };

            // Run after_create hook (only if new workspace)
            if (ws.created) {
                const hook = global_hooks.after_create;
                if (hook) |cmd| {
                    // Render hook template
                    const rendered_cmd = templates.render(allocator, cmd, .{
                        .input_json = "{}",
                        .step_outputs = &.{},
                        .item = null,
                        .task_json = claim.task.metadata_json,
                    }) catch cmd;
                    const ok = workspace_mod.runHook(allocator, rendered_cmd, ws.path, self.cfg.workspace.hook_timeout_ms) catch false;
                    if (!ok) {
                        log.err("after_create hook failed for task {s}", .{claim.task.id});
                        return;
                    }
                }
            }

            // Run before_run hook
            const before_hook = global_hooks.before_run;
            if (before_hook) |cmd| {
                const rendered_cmd = templates.render(allocator, cmd, .{
                    .input_json = "{}",
                    .step_outputs = &.{},
                    .item = null,
                    .task_json = claim.task.metadata_json,
                }) catch cmd;
                const ok = workspace_mod.runHook(allocator, rendered_cmd, ws.path, self.cfg.workspace.hook_timeout_ms) catch false;
                if (!ok) {
                    log.err("before_run hook failed for task {s}", .{claim.task.id});
                    return;
                }
            }

            const task = RunningTask{
                .task_id = claim.task.id,
                .task_title = claim.task.title,
                .task_identifier = claim.task.id,
                .pipeline_id = wf.pipeline_id,
                .agent_role = role,
                .lease_id = claim.lease_id,
                .lease_token = claim.lease_token,
                .run_id = claim.run.id,
                .workspace_path = ws.path,
                .execution_mode = "subprocess",
                .subprocess = subprocess_mod.SubprocessInfo{
                    .task_id = claim.task.id,
                    .lease_id = claim.lease_id,
                    .lease_token = claim.lease_token,
                    .workspace_path = ws.path,
                    .pipeline_id = wf.pipeline_id,
                    .agent_role = role,
                    .port = 0, // will be set after spawn
                    .child = null,
                    .current_turn = 0,
                    .max_turns = wf.subprocess.max_turns,
                    .started_at_ms = now,
                    .last_activity_ms = now,
                    .state = .starting,
                    .last_output = null,
                    .run_id = claim.run.id,
                    .task_title = claim.task.title,
                    .task_identifier = claim.task.id,
                    .execution_mode = "subprocess",
                },
                .started_at_ms = now,
                .last_activity_ms = now,
                .current_turn = 0,
                .max_turns = wf.subprocess.max_turns,
                .state = .running,
            };

            self.state.running.put(self.allocator, claim.task.id, task) catch {
                log.err("failed to track task {s}", .{claim.task.id});
            };
        } else {
            // dispatch mode — use existing worker dispatch
            const task = RunningTask{
                .task_id = claim.task.id,
                .task_title = claim.task.title,
                .task_identifier = claim.task.id,
                .pipeline_id = wf.pipeline_id,
                .agent_role = role,
                .lease_id = claim.lease_id,
                .lease_token = claim.lease_token,
                .run_id = claim.run.id,
                .workspace_path = "",
                .execution_mode = "dispatch",
                .subprocess = null,
                .started_at_ms = now,
                .last_activity_ms = now,
                .current_turn = 0,
                .max_turns = 1,
                .state = .running,
            };

            self.state.running.put(self.allocator, claim.task.id, task) catch {
                log.err("failed to track dispatch task {s}", .{claim.task.id});
            };
        }
    }

    fn cleanCooldowns(self: *Tracker) void {
        const now = ids.nowMs();
        var to_remove: [64][]const u8 = undefined;
        var remove_count: usize = 0;

        for (self.state.cooldowns.keys(), self.state.cooldowns.values()) |key, until| {
            if (now >= until and remove_count < 64) {
                to_remove[remove_count] = key;
                remove_count += 1;
            }
        }

        for (to_remove[0..remove_count]) |key| {
            _ = self.state.cooldowns.orderedRemove(key);
        }
    }

    fn shutdown_subprocesses(self: *Tracker) void {
        for (self.state.running.values()) |*task| {
            if (task.subprocess) |*sub| {
                if (sub.child) |*child| {
                    log.info("stopping subprocess for task {s}", .{task.task_id});
                    subprocess_mod.killSubprocess(child);
                }
            }
        }
    }
};

// ── Tests ──────────────────────────────────────────────────────────────

test "TrackerState init and counts" {
    const allocator = std.testing.allocator;
    var state = TrackerState.init();
    defer state.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 0), state.runningCount());
    try std.testing.expectEqual(@as(u64, 0), state.completed_count);
}

test "canClaimMore respects global limit" {
    const allocator = std.testing.allocator;
    var state = TrackerState.init();
    defer state.deinit(allocator);

    var cfg = config.ConcurrencyConfig{ .max_concurrent_tasks = 0 };
    try std.testing.expect(!canClaimMore(&state, &cfg, "p1", "r1"));

    cfg.max_concurrent_tasks = 10;
    try std.testing.expect(canClaimMore(&state, &cfg, "p1", "r1"));
}

test "TrackerState countByPipeline" {
    const allocator = std.testing.allocator;
    var state = TrackerState.init();
    defer state.deinit(allocator);

    try state.running.put(allocator, "t1", RunningTask{
        .task_id = "t1",
        .task_title = "T1",
        .task_identifier = "T-1",
        .pipeline_id = "code-review",
        .agent_role = "reviewer",
        .lease_id = "l1",
        .lease_token = "tok",
        .run_id = "r1",
        .workspace_path = "",
        .execution_mode = "subprocess",
        .subprocess = null,
        .started_at_ms = 0,
        .last_activity_ms = 0,
        .current_turn = 0,
        .max_turns = 20,
        .state = .running,
    });

    try std.testing.expectEqual(@as(usize, 1), state.countByPipeline("code-review"));
    try std.testing.expectEqual(@as(usize, 0), state.countByPipeline("feature-dev"));
}

test "TrackerState countByRole" {
    const allocator = std.testing.allocator;
    var state = TrackerState.init();
    defer state.deinit(allocator);

    try state.running.put(allocator, "t1", RunningTask{
        .task_id = "t1",
        .task_title = "T1",
        .task_identifier = "T-1",
        .pipeline_id = "p1",
        .agent_role = "coder",
        .lease_id = "l1",
        .lease_token = "tok",
        .run_id = "r1",
        .workspace_path = "",
        .execution_mode = "subprocess",
        .subprocess = null,
        .started_at_ms = 0,
        .last_activity_ms = 0,
        .current_turn = 0,
        .max_turns = 20,
        .state = .running,
    });

    try std.testing.expectEqual(@as(usize, 1), state.countByRole("coder"));
    try std.testing.expectEqual(@as(usize, 0), state.countByRole("reviewer"));
}
```

**Step 2: Add comptime import**

```zig
_ = @import("tracker.zig");
```

**Step 3: Run tests**

Run: `zig build test 2>&1 | tail -5`
Expected: All tests pass

**Step 4: Commit**

```bash
git add src/tracker.zig src/main.zig
git commit -m "feat: add tracker thread with poll loop, concurrency, stall detection"
```

---

### Task 9: Observability API Endpoints

**Files:**
- Modify: `src/api.zig`
- Modify: `src/main.zig` (pass tracker state to API context)

**Step 1: Add tracker_state field to api.Context**

In `src/api.zig`, add to Context struct:

```zig
tracker_state: ?*const @import("tracker.zig").TrackerState = null,
tracker_cfg: ?*const @import("config.zig").TrackerConfig = null,
```

**Step 2: Add route handlers in api.zig handleRequest**

Add before the 404 fallback at the end of `handleRequest`:

```zig
    // GET /tracker/status
    if (is_get and eql(seg0, "tracker") and eql(seg1, "status") and seg2 == null) {
        return handleTrackerStatus(ctx);
    }

    // GET /tracker/tasks
    if (is_get and eql(seg0, "tracker") and eql(seg1, "tasks") and seg2 == null) {
        return handleTrackerTasks(ctx);
    }

    // GET /tracker/tasks/{task_id}
    if (is_get and eql(seg0, "tracker") and eql(seg1, "tasks") and seg2 != null and seg3 == null) {
        return handleTrackerTaskDetail(ctx, seg2.?);
    }
```

**Step 3: Implement handler functions**

Add at end of `src/api.zig` (before tests):

```zig
fn handleTrackerStatus(ctx: *Context) HttpResponse {
    const state = ctx.tracker_state orelse {
        return jsonResponse(404, "{\"error\":{\"code\":\"tracker_disabled\",\"message\":\"pull-mode tracker is not configured\"}}");
    };
    const cfg = ctx.tracker_cfg orelse {
        return jsonResponse(500, "{\"error\":{\"code\":\"internal\",\"message\":\"tracker config missing\"}}");
    };

    var tasks_arr: std.ArrayListUnmanaged(u8) = .empty;
    defer tasks_arr.deinit(ctx.allocator);

    tasks_arr.append(ctx.allocator, '[') catch return serverError();
    var first = true;
    for (state.running.values()) |task| {
        if (!first) tasks_arr.append(ctx.allocator, ',') catch return serverError();
        first = false;

        const entry = std.fmt.allocPrint(ctx.allocator,
            \\{{"task_id":"{s}","task_title":"{s}","pipeline_id":"{s}","agent_role":"{s}","execution":"{s}","current_turn":{d},"max_turns":{d},"started_at_ms":{d},"last_activity_ms":{d},"state":"{s}"}}
        , .{
            task.task_id,
            task.task_title,
            task.pipeline_id,
            task.agent_role,
            task.execution_mode,
            task.current_turn,
            task.max_turns,
            task.started_at_ms,
            task.last_activity_ms,
            task.state.toString(),
        }) catch return serverError();
        defer ctx.allocator.free(entry);
        tasks_arr.appendSlice(ctx.allocator, entry) catch return serverError();
    }
    tasks_arr.append(ctx.allocator, ']') catch return serverError();

    const body = std.fmt.allocPrint(ctx.allocator,
        \\{{"mode":"pull","running_count":{d},"max_concurrent":{d},"completed_count":{d},"failed_count":{d},"poll_interval_ms":{d},"running":{s}}}
    , .{
        state.runningCount(),
        cfg.concurrency.max_concurrent_tasks,
        state.completed_count,
        state.failed_count,
        cfg.poll_interval_ms,
        tasks_arr.items,
    }) catch return serverError();

    return jsonResponse(200, body);
}

fn handleTrackerTasks(ctx: *Context) HttpResponse {
    const state = ctx.tracker_state orelse {
        return jsonResponse(404, "{\"error\":{\"code\":\"tracker_disabled\",\"message\":\"pull-mode tracker is not configured\"}}");
    };

    var arr: std.ArrayListUnmanaged(u8) = .empty;
    defer arr.deinit(ctx.allocator);

    arr.append(ctx.allocator, '[') catch return serverError();
    var first = true;
    for (state.running.values()) |task| {
        if (!first) arr.append(ctx.allocator, ',') catch return serverError();
        first = false;

        const entry = std.fmt.allocPrint(ctx.allocator,
            \\{{"task_id":"{s}","task_title":"{s}","pipeline_id":"{s}","agent_role":"{s}","execution":"{s}","current_turn":{d},"max_turns":{d},"started_at_ms":{d},"last_activity_ms":{d},"state":"{s}","lease_id":"{s}","run_id":"{s}","workspace_path":"{s}"}}
        , .{
            task.task_id,
            task.task_title,
            task.pipeline_id,
            task.agent_role,
            task.execution_mode,
            task.current_turn,
            task.max_turns,
            task.started_at_ms,
            task.last_activity_ms,
            task.state.toString(),
            task.lease_id,
            task.run_id,
            task.workspace_path,
        }) catch return serverError();
        defer ctx.allocator.free(entry);
        arr.appendSlice(ctx.allocator, entry) catch return serverError();
    }
    arr.append(ctx.allocator, ']') catch return serverError();

    const body = std.fmt.allocPrint(ctx.allocator, "{s}", .{arr.items}) catch return serverError();
    return jsonResponse(200, body);
}

fn handleTrackerTaskDetail(ctx: *Context, task_id: []const u8) HttpResponse {
    const state = ctx.tracker_state orelse {
        return jsonResponse(404, "{\"error\":{\"code\":\"tracker_disabled\",\"message\":\"pull-mode tracker is not configured\"}}");
    };

    const task = state.running.get(task_id) orelse {
        return jsonResponse(404, "{\"error\":{\"code\":\"not_found\",\"message\":\"task not found in tracker\"}}");
    };

    const body = std.fmt.allocPrint(ctx.allocator,
        \\{{"task_id":"{s}","task_title":"{s}","pipeline_id":"{s}","agent_role":"{s}","execution":"{s}","current_turn":{d},"max_turns":{d},"started_at_ms":{d},"last_activity_ms":{d},"state":"{s}","lease_id":"{s}","run_id":"{s}","workspace_path":"{s}"}}
    , .{
        task.task_id,
        task.task_title,
        task.pipeline_id,
        task.agent_role,
        task.execution_mode,
        task.current_turn,
        task.max_turns,
        task.started_at_ms,
        task.last_activity_ms,
        task.state.toString(),
        task.lease_id,
        task.run_id,
        task.workspace_path,
    }) catch return serverError();

    return jsonResponse(200, body);
}

fn serverError() HttpResponse {
    return jsonResponse(500, "{\"error\":{\"code\":\"internal\",\"message\":\"internal server error\"}}");
}
```

**Step 4: Run tests**

Run: `zig build test 2>&1 | tail -5`
Expected: All tests pass

**Step 5: Commit**

```bash
git add src/api.zig
git commit -m "feat: add /tracker/* observability API endpoints for NullHub"
```

---

### Task 10: Wire Tracker Thread in main.zig

**Files:**
- Modify: `src/main.zig`

**Step 1: Add tracker thread spawning after engine thread**

After the MQTT/Redis listener setup and before `std.debug.print("listening on...`, add:

```zig
    // Start Tracker thread for pull-mode (conditionally)
    var tracker_instance: ?@import("tracker.zig").Tracker = null;
    var tracker_thread: ?std.Thread = null;

    if (cfg.tracker) |tracker_cfg| {
        if (tracker_cfg.url != null) {
            var workflows = @import("workflow_loader.zig").loadWorkflows(cfg_arena.allocator(), tracker_cfg.workflows_dir);
            _ = &workflows;

            tracker_instance = @import("tracker.zig").Tracker.init(
                allocator,
                tracker_cfg,
                workflows,
                &store,
                &shutdown_requested,
            );

            tracker_thread = std.Thread.spawn(.{}, struct {
                fn entry(t: *@import("tracker.zig").Tracker) void {
                    t.run();
                }
            }.entry, .{&tracker_instance.?}) catch |err| blk: {
                std.debug.print("warning: failed to start tracker thread: {}\n", .{err});
                break :blk null;
            };

            if (tracker_thread != null) {
                std.debug.print("tracker started (poll_interval={d}ms, workflows_dir={s})\n", .{
                    tracker_cfg.poll_interval_ms,
                    tracker_cfg.workflows_dir,
                });
            }
        }
    }
```

**Step 2: Add tracker_state to API context**

Update the `var ctx = api.Context{...}` to include:

```zig
            .tracker_state = if (tracker_instance) |*ti| &ti.state else null,
            .tracker_cfg = if (cfg.tracker) |*tc| tc else null,
```

**Step 3: Add tracker shutdown to defer block**

After the engine shutdown in the defer block, add:

```zig
        if (tracker_thread) |t| {
            t.join();
            std.debug.print("tracker stopped\n", .{});
        }
        if (tracker_instance) |*ti| {
            ti.deinit();
        }
```

**Step 4: Run build**

Run: `zig build 2>&1 | tail -10`
Expected: Build succeeds

**Step 5: Run tests**

Run: `zig build test 2>&1 | tail -5`
Expected: All tests pass

**Step 6: Commit**

```bash
git add src/main.zig
git commit -m "feat: wire tracker thread conditionally in main startup"
```

---

### Task 11: Example Workflow Files

**Files:**
- Create: `workflows/example-code-review.json`
- Create: `workflows/example-quick-analysis.json`

**Step 1: Create example workflow files**

`workflows/example-code-review.json`:
```json
{
  "id": "code-review",
  "pipeline_id": "pipeline-code-review",
  "claim_roles": ["reviewer"],
  "execution": "subprocess",
  "subprocess": {
    "command": "nullclaw",
    "args": ["--single-task"],
    "max_turns": 20,
    "turn_timeout_ms": 600000
  },
  "prompt_template": "Review the code in this workspace.\n\nTask: {{task.title}}\nDescription: {{task.description}}",
  "on_success": {
    "transition_to": "reviewed"
  },
  "on_failure": {
    "transition_to": "review-failed"
  }
}
```

`workflows/example-quick-analysis.json`:
```json
{
  "id": "quick-analysis",
  "pipeline_id": "pipeline-triage",
  "claim_roles": ["analyst"],
  "execution": "dispatch",
  "dispatch": {
    "worker_tags": ["analysis"],
    "protocol": "webhook"
  },
  "prompt_template": "Analyze this task:\n\nTitle: {{task.title}}\nDescription: {{task.description}}",
  "on_success": {
    "transition_to": "analyzed"
  },
  "on_failure": {
    "transition_to": "analysis-failed"
  }
}
```

**Step 2: Commit**

```bash
git add workflows/
git commit -m "docs: add example workflow files for pull-mode"
```

---

### Task 12: Integration Test — Full Pull-Mode Flow

**Files:**
- Modify: `tests/test_e2e.sh` (add pull-mode test section)

**Step 1: Add pull-mode integration test**

Add to `tests/test_e2e.sh` a new test section that:
1. Starts a mock NullTickets server (Python) that responds to `/leases/claim`, `/leases/{id}/heartbeat`, `/ops/queue`
2. Creates a test workflow JSON in a temp workflows dir
3. Starts NullBoiler with `tracker` config pointing to mock NullTickets
4. Verifies `GET /tracker/status` returns correct state
5. Verifies `GET /tracker/tasks` returns empty array initially
6. Cleans up

This is a manual verification step — the mock server pattern already exists in the e2e test file for worker mocking.

**Step 2: Commit**

```bash
git add tests/test_e2e.sh
git commit -m "test: add e2e pull-mode tracker integration test"
```

---

### Task 13: Final Verification & Cleanup

**Step 1: Run full test suite**

Run: `zig build test 2>&1`
Expected: All tests pass, no leaks

**Step 2: Run build**

Run: `zig build 2>&1`
Expected: Clean build

**Step 3: Verify push-mode still works**

Run: `zig build && bash tests/test_e2e.sh 2>&1 | tail -20`
Expected: Existing e2e tests pass (push-mode unchanged)

**Step 4: Verify tracker doesn't start without config**

Run: `./zig-out/bin/nullboiler --port 8099 --db :memory: &`
Then: `curl -s http://localhost:8099/tracker/status`
Expected: `{"error":{"code":"tracker_disabled","message":"pull-mode tracker is not configured"}}`
Kill: `kill %1`

**Step 5: Commit summary**

```bash
git add -A
git commit -m "feat: complete pull-mode Symphony integration (tracker, workspace, subprocess, observability)"
```
