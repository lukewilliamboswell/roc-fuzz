//! The embedded quality supervisor. Roc values never cross its process boundary.
//!
//! Every example is materialized once, copied into host storage, and executed in
//! one new process. Baselines contain complete observations, never sampled costs.
const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;

pub const worker_format = "roc-fuzz-worker/1";
pub const baseline_format = "roc-fuzz-baseline/1";
pub const report_format = "roc-fuzz-quality/2";
pub const preparation_format = "roc-fuzz-examples/1";
pub const metric_version = "roc-fuzz-allocations/1";
pub const max_input_len = 2 * 1024 * 1024;
/// Keep equal to the host's goal inventory capacity.
pub const max_goals = 1024;
pub const max_goal_name_bytes = 128;
const max_json_len = 32 * 1024 * 1024;
const max_breadcrumb_len = 64 * 1024;

pub const Example = struct { name: []const u8, revision: []const u8, bytes: []const u8 };
pub const Capture = enum { normal, detailed };
pub const WorkerResult = struct {
    accepted: bool,
    metric_valid: bool,
    trace_rules_passed: bool,
    capture_complete: bool,
    observations_json: []const u8,
    diagnostics_json: ?[]const u8 = null,
    /// The size of the inventory this worker saw, and the goals its input reached.
    goals_declared: u64 = 0,
    goals_reached: []const []const u8 = &.{},
};
pub const Adapter = struct {
    prepare_examples: *const fn (Allocator) anyerror![]const Example,
    /// The target's declared goals, in declaration order. Absent means none.
    prepare_goals: ?*const fn (Allocator) anyerror![]const []const u8 = null,
    run_one: *const fn (Allocator, []const u8, Capture) anyerror!WorkerResult,
    show: *const fn (Allocator, []const u8) anyerror![]const u8,
    original_snapshot: ?*const fn (Allocator, []align(64) const u8) anyerror![]const u8 = null,
};

const WorkerWire = struct {
    format: []const u8,
    metric_version: []const u8,
    accepted: bool,
    metric_valid: bool,
    trace_rules_passed: bool,
    capture_complete: bool,
    observations: std.json.Value,
    diagnostics: ?std.json.Value = null,
    goals_declared: u64 = 0,
    goals_reached: []const []const u8 = &.{},
};

const PreparationWire = struct { format: []const u8, examples: []const Example, goals: []const []const u8 = &.{} };

pub const BaselineExample = struct {
    name: []const u8,
    revision: []const u8,
    input_sha256: []const u8,
    observations: std.json.Value,
};
pub const BaselineEntry = struct {
    host_target: []const u8,
    profile: []const u8,
    metric_version: []const u8,
    examples: []const BaselineExample,
};
pub const Baseline = struct {
    format: []const u8,
    target: []const u8,
    entries: []const BaselineEntry,
};

pub const Health = extern struct {
    version: u64 = 1,
    attempted: u64 = 0,
    accepted: u64 = 0,
    rejected: u64 = 0,
    input_sequence: u64 = 0,
    input_length: u64 = 0,
    input_captured: u64 = 0,
    input_sha256: [32]u8 = @splat(0),
    input: [max_input_len]u8 = @splat(0),
    breadcrumb_sequence: u64 = 0,
    breadcrumb_length: u64 = 0,
    breadcrumb_truncated: u64 = 0,
    breadcrumb: [max_breadcrumb_len]u8 = @splat(0),
    observation_initialized: u64 = 0,
    observation_input_sequence: u64 = 0,
    observation_storage: [1024 * 1024]u8 align(64) = @splat(0),
    /// The exploration worker's goal tally, indexed like the inventory.
    goal_count: u64 = 0,
    goals: [max_goals]GoalRecord = @splat(.{}),
};

/// What one exploration process knows about one goal. `inputs` is written
/// last, so a record a killed writer left half made reads as not reached.
pub const GoalRecord = extern struct {
    inputs: u64 = 0,
    first_attempt: u64 = 0,
    first_length: u64 = 0,
    first_sha256: [32]u8 = @splat(0),
    witness_saved: u64 = 0,
};
var worker_health: ?*Health = null;
var worker_leaks = true;
var goal_directory: ?[]const u8 = null;

/// Where the exploration worker keeps the first input that reaches each goal.
pub fn setGoalDirectory(path: []const u8) void {
    goal_directory = path;
}

pub fn healthGoalInventory(count: usize) void {
    const health = worker_health orelse return;
    health.goal_count = count;
}

fn goalWitnessPath(allocator: Allocator, directory: []const u8, index: usize) ![]const u8 {
    return std.fmt.allocPrint(allocator, "{s}/goal-{d}.bin", .{ directory, index });
}

/// Count a kept input toward each goal it reached. The first input to reach a
/// goal is its witness: its bytes are saved before the goal counts as reached,
/// so the supervisor can name them even if this process dies on a later input.
pub fn healthGoalsReached(indexes: []const u16, input: []const u8) void {
    const health = worker_health orelse return;
    for (indexes) |index| {
        const record = &health.goals[index];
        if (record.inputs == 0) {
            record.first_attempt = @atomicLoad(u64, &health.attempted, .monotonic);
            record.first_length = input.len;
            record.first_sha256 = health.input_sha256;
            if (goal_directory) |directory| {
                var buffer: [4200]u8 = undefined;
                var fixed = std.heap.FixedBufferAllocator.init(&buffer);
                if (goalWitnessPath(fixed.allocator(), directory, index)) |path| {
                    record.witness_saved = @intFromBool(if (atomicWrite(std.heap.c_allocator, path, input)) |_| true else |_| false);
                } else |_| {}
            }
        }
        _ = @atomicRmw(u64, &record.inputs, .Add, 1, .release);
    }
}

pub fn workerLeakDetection() bool {
    return worker_leaks;
}

/// Native observation state has fixed owned arrays, so the same bytes can be
/// inspected by the supervisor after the writer crashes or is killed.
pub fn sharedObservation(comptime T: type) ?*T {
    comptime {
        if (@sizeOf(T) > 1024 * 1024 or @alignOf(T) > 64) @compileError("observation engine exceeds shared storage");
    }
    const health = worker_health orelse return null;
    health.observation_initialized = 1;
    return @ptrCast(@alignCast(&health.observation_storage));
}

/// Call immediately after resetting shared observation state for this input.
/// A timeout before reset must not associate the previous input's trace with
/// the newly captured bytes.
pub fn healthObservationReady() void {
    const health = worker_health orelse return;
    health.observation_input_sequence = @atomicLoad(u64, &health.input_sequence, .acquire);
}

extern "c" fn fileno(*std.c.FILE) c_int;
extern "c" fn fsync(c_int) c_int;
extern "c" fn mkstemp([*:0]u8) c_int;
extern "c" fn mkdtemp([*:0]u8) ?[*:0]u8;
extern "c" fn fdopen(c_int, [*:0]const u8) ?*std.c.FILE;
extern "c" fn fflush(?*std.c.FILE) c_int;
extern "c" fn ferror(*std.c.FILE) c_int;

fn io() std.Io {
    std.Io.Threaded.global_single_threaded.allocator = std.heap.c_allocator;
    return std.Io.Threaded.global_single_threaded.io();
}

fn writeFd(fd: c_int, bytes: []const u8) void {
    var left = bytes;
    while (left.len > 0) {
        const n = std.c.write(fd, left.ptr, left.len);
        if (n <= 0) return;
        left = left[@intCast(n)..];
    }
}

fn fail(message: []const u8) noreturn {
    writeFd(2, "roc-fuzz: ");
    writeFd(2, message);
    writeFd(2, "\n");
    std.c._exit(2);
}

fn failError(err: anyerror) noreturn {
    fail(@errorName(err));
}

fn json(allocator: Allocator, value: anytype) ![]u8 {
    return std.json.Stringify.valueAlloc(allocator, value, .{});
}

fn readFile(allocator: Allocator, path: []const u8, limit: usize) ![]u8 {
    const stat = try std.Io.Dir.cwd().statFile(io(), path, .{});
    if (stat.size > limit) return error.FileTooBig;
    const bytes = try allocator.alloc(u8, @intCast(stat.size));
    errdefer allocator.free(bytes);
    const path_z = try allocator.dupeZ(u8, path);
    defer allocator.free(path_z);
    const file = std.c.fopen(path_z.ptr, "rb") orelse return error.CannotReadFile;
    defer _ = std.c.fclose(file);
    if (std.c.fread(bytes.ptr, 1, bytes.len, file) != bytes.len or ferror(file) != 0) return error.CannotReadFile;
    // Detect growth as well as truncation between stat and read.
    var extra: [1]u8 = undefined;
    if (std.c.fread(&extra, 1, 1, file) != 0) return error.FileChanged;
    return bytes;
}

fn writeFile(allocator: Allocator, path: []const u8, bytes: []const u8) !void {
    const path_z = try allocator.dupeZ(u8, path);
    defer allocator.free(path_z);
    const file = std.c.fopen(path_z.ptr, "wb") orelse return error.CannotCreateFile;
    var open = true;
    defer if (open) {
        _ = std.c.fclose(file);
    };
    if (std.c.fwrite(bytes.ptr, 1, bytes.len, file) != bytes.len or fflush(file) != 0) return error.CannotWriteFile;
    open = false;
    if (std.c.fclose(file) != 0) return error.CannotWriteFile;
}

/// Stage beside the destination, flush, and rename only the completed bytes.
/// A failed write, flush or rename leaves the previous destination untouched.
pub fn atomicWrite(allocator: Allocator, path: []const u8, bytes: []const u8) !void {
    const temporary = try std.fmt.allocPrintSentinel(allocator, "{s}.tmp-XXXXXX", .{path}, 0);
    defer allocator.free(temporary);
    const fd = mkstemp(temporary.ptr);
    if (fd < 0) return error.CannotCreateTemporaryFile;
    defer _ = std.c.unlink(temporary.ptr);
    const file = fdopen(fd, "wb") orelse {
        _ = std.c.close(fd);
        return error.CannotCreateTemporaryFile;
    };
    var open = true;
    defer if (open) {
        _ = std.c.fclose(file);
    };
    if (std.c.fwrite(bytes.ptr, 1, bytes.len, file) != bytes.len or fflush(file) != 0 or fsync(fd) != 0) return error.CannotWriteTemporaryFile;
    open = false;
    if (std.c.fclose(file) != 0) return error.CannotWriteTemporaryFile;
    try std.Io.Dir.rename(.cwd(), temporary, .cwd(), path, io());
}

fn hashBytes(bytes: []const u8) ![32]u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    return digest;
}

fn hash(allocator: Allocator, bytes: []const u8) ![]const u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    return allocator.dupe(u8, &std.fmt.bytesToHex(digest, .lower));
}

pub fn baselinePath(allocator: Allocator, target: []const u8, override: ?[]const u8) ![]const u8 {
    if (override) |path| {
        if (path.len == 0) return error.EmptyBaselinePath;
        return allocator.dupe(u8, path);
    }
    if (target.len == 0 or std.mem.indexOfAny(u8, target, "/\\\x00") != null or std.mem.eql(u8, target, ".") or std.mem.eql(u8, target, "..")) return error.InvalidTargetNameForBaseline;
    return std.fmt.allocPrint(allocator, "{s}_baseline.json", .{target});
}

pub fn hostTarget() []const u8 {
    return switch (builtin.os.tag) {
        .macos => "arm64mac",
        .linux => "x64musl",
        else => @tagName(builtin.cpu.arch) ++ "-" ++ @tagName(builtin.os.tag),
    };
}

/// Compare JSON structurally: object key order is not evidence; array order is.
pub fn jsonEqual(a: std.json.Value, b: std.json.Value) bool {
    if (std.meta.activeTag(a) != std.meta.activeTag(b)) return false;
    return switch (a) {
        .null => true,
        .bool => |v| v == b.bool,
        .integer => |v| v == b.integer,
        .float => |v| v == b.float,
        .number_string => |v| std.mem.eql(u8, v, b.number_string),
        .string => |v| std.mem.eql(u8, v, b.string),
        .array => |v| blk: {
            if (v.items.len != b.array.items.len) break :blk false;
            for (v.items, b.array.items) |left, right| if (!jsonEqual(left, right)) break :blk false;
            break :blk true;
        },
        .object => |v| blk: {
            if (v.count() != b.object.count()) break :blk false;
            var it = v.iterator();
            while (it.next()) |entry| {
                const other = b.object.get(entry.key_ptr.*) orelse break :blk false;
                if (!jsonEqual(entry.value_ptr.*, other)) break :blk false;
            }
            break :blk true;
        },
    };
}

pub fn entryEqual(a: BaselineEntry, b: BaselineEntry) bool {
    if (!std.mem.eql(u8, a.host_target, b.host_target) or !std.mem.eql(u8, a.profile, b.profile) or !std.mem.eql(u8, a.metric_version, b.metric_version) or a.examples.len != b.examples.len) return false;
    for (a.examples, b.examples) |left, right| {
        if (!std.mem.eql(u8, left.name, right.name) or !std.mem.eql(u8, left.revision, right.revision) or !std.mem.eql(u8, left.input_sha256, right.input_sha256) or !jsonEqual(left.observations, right.observations)) return false;
    }
    return true;
}

fn validateExamples(examples: []const Example) !void {
    if (examples.len > 4096) return error.TooManyExamples;
    for (examples, 0..) |example, index| {
        if (example.name.len == 0 or example.revision.len == 0 or example.bytes.len > max_input_len) return error.InvalidExample;
        for (examples[0..index]) |other| if (std.mem.eql(u8, example.name, other.name)) return error.DuplicateExampleName;
    }
}

fn validateGoals(goals: []const []const u8) !void {
    if (goals.len > max_goals) return error.TooManyGoals;
    for (goals, 0..) |goal, index| {
        if (goal.len == 0 or goal.len > max_goal_name_bytes) return error.InvalidGoalName;
        for (goals[0..index]) |other| if (std.mem.eql(u8, goal, other)) return error.DuplicateGoalName;
    }
}

fn baselineLoad(allocator: Allocator, path: []const u8, target: []const u8) !?Baseline {
    _ = std.Io.Dir.cwd().statFile(io(), path, .{}) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    const bytes = try readFile(allocator, path, max_json_len);
    const parsed = try std.json.parseFromSlice(Baseline, allocator, bytes, .{ .allocate = .alloc_always });
    const baseline = parsed.value;
    if (!std.mem.eql(u8, baseline.format, baseline_format)) return error.UnsupportedBaselineFormat;
    if (!std.mem.eql(u8, baseline.target, target)) return error.BaselineTargetMismatch;
    for (baseline.entries, 0..) |entry, index| {
        if (entry.host_target.len == 0 or entry.profile.len == 0) return error.InvalidBaselineEntry;
        for (baseline.entries[0..index]) |other| {
            if (std.mem.eql(u8, entry.host_target, other.host_target) and std.mem.eql(u8, entry.profile, other.profile)) return error.DuplicateBaselineEntry;
        }
    }
    return baseline;
}

pub fn replaceEntry(allocator: Allocator, prior: ?Baseline, target: []const u8, entry: BaselineEntry) !Baseline {
    var entries: std.ArrayList(BaselineEntry) = .empty;
    var found = false;
    if (prior) |baseline| for (baseline.entries) |old| {
        if (std.mem.eql(u8, old.host_target, entry.host_target) and std.mem.eql(u8, old.profile, entry.profile)) {
            try entries.append(allocator, entry);
            found = true;
        } else try entries.append(allocator, old);
    };
    if (!found) try entries.append(allocator, entry);
    return .{ .format = baseline_format, .target = target, .entries = try entries.toOwnedSlice(allocator) };
}

fn mapHealth(allocator: Allocator, path: []const u8, create: bool) !*Health {
    const path_z = try allocator.dupeZ(u8, path);
    defer allocator.free(path_z);
    const file = std.c.fopen(path_z.ptr, if (create) "w+b" else "r+b") orelse return error.CannotOpenSharedHealth;
    defer _ = std.c.fclose(file);
    const fd = fileno(file);
    if (create and std.c.ftruncate(fd, @sizeOf(Health)) != 0) return error.CannotSizeSharedHealth;
    const ptr = std.c.mmap(null, @sizeOf(Health), .{ .READ = true, .WRITE = true }, .{ .TYPE = .SHARED }, fd, 0);
    if (ptr == std.c.MAP_FAILED) return error.CannotMapSharedHealth;
    const health: *Health = @ptrCast(@alignCast(ptr));
    if (create) health.* = .{} else if (health.version != 1) return error.UnsupportedSharedHealth;
    return health;
}

/// Attach only in a worker. The supervisor owns the mapped file and its lifetime.
pub fn attachHealth(path: []const u8) !void {
    worker_health = try mapHealth(std.heap.c_allocator, path, false);
}

pub fn healthAttempt(input: []const u8) void {
    const health = worker_health orelse return;
    _ = @atomicRmw(u64, &health.input_sequence, .Add, 1, .acq_rel);
    _ = @atomicRmw(u64, &health.attempted, .Add, 1, .monotonic);
    const captured = @min(input.len, health.input.len);
    health.input_length = input.len;
    health.input_captured = captured;
    std.crypto.hash.sha2.Sha256.hash(input, &health.input_sha256, .{});
    @memcpy(health.input[0..captured], input[0..captured]);
    _ = @atomicRmw(u64, &health.input_sequence, .Add, 1, .release);
}

pub fn healthFinish(accepted: bool) void {
    const health = worker_health orelse return;
    _ = @atomicRmw(u64, if (accepted) &health.accepted else &health.rejected, .Add, 1, .release);
}

/// Bounded original-run evidence. Diagnostic replay must use a separate record.
pub fn breadcrumb(bytes: []const u8) void {
    const health = worker_health orelse return;
    _ = @atomicRmw(u64, &health.breadcrumb_sequence, .Add, 1, .acq_rel);
    const captured = @min(bytes.len, health.breadcrumb.len);
    health.breadcrumb_length = captured;
    health.breadcrumb_truncated = @intFromBool(bytes.len > captured);
    @memcpy(health.breadcrumb[0..captured], bytes[0..captured]);
    _ = @atomicRmw(u64, &health.breadcrumb_sequence, .Add, 1, .release);
}

const ChildResult = struct {
    exit_code: ?u8 = null,
    signal: ?u32 = null,
    timed_out: bool = false,
    fn passed(self: ChildResult) bool {
        return !self.timed_out and self.signal == null and self.exit_code == 0;
    }
};

const LogSpan = struct {
    path: []const u8 = "run.log",
    offset: u64 = 0,
    length: u64 = 0,
};

fn logSize(path: []const u8) !u64 {
    return (std.Io.Dir.cwd().statFile(io(), path, .{}) catch |err| switch (err) {
        error.FileNotFound => return 0,
        else => return err,
    }).size;
}

/// Stream only this child's span; marker overlap survives chunk boundaries.
/// Diagnostic classification never changes the preserved original log.
fn classifyFinding(allocator: Allocator, path: []const u8, span: LogSpan, termination: ChildResult) !?[]const u8 {
    if (termination.timed_out) return "timeout";
    if (termination.passed()) return null;
    const path_z = try allocator.dupeZ(u8, path);
    defer allocator.free(path_z);
    const file = std.c.fopen(path_z.ptr, "rb") orelse return error.CannotReadLog;
    defer _ = std.c.fclose(file);
    const fd = fileno(file);
    var buffer: [64 * 1024 + 128]u8 = undefined;
    var kept: usize = 0;
    var consumed: u64 = 0;
    var kind: ?[]const u8 = null;
    var strongest: usize = 0;
    while (consumed < span.length) {
        const wanted: usize = @intCast(@min(64 * 1024, span.length - consumed));
        const got = std.c.pread(fd, buffer[kept..].ptr, wanted, @intCast(span.offset + consumed));
        if (got <= 0) return error.CannotReadLog;
        const count: usize = @intCast(got);
        const bytes = buffer[0 .. kept + count];
        const markers = .{
            .{ "[roc-fuzz invalid observation]", "invalid_observation" },
            .{ "[roc-fuzz observation failure]", "invalid_observation" },
            .{ "[roc crashed]", "roc_crash" },
            .{ "[roc expect failed]", "assertion" },
            .{ "[roc-fuzz leak]", "leak" },
            .{ "out-of-memory", "oom" },
            .{ "out of memory", "oom" },
            .{ "rss_limit", "oom" },
            .{ "libFuzzer: timeout", "timeout" },
            .{ "timeout after", "timeout" },
        };
        inline for (markers, 1..) |marker, priority| {
            if (priority > strongest and std.mem.indexOf(u8, bytes, marker[0]) != null) {
                kind = marker[1];
                strongest = priority;
            }
        }
        consumed += count;
        kept = @min(128, bytes.len);
        std.mem.copyForwards(u8, buffer[0..kept], bytes[bytes.len - kept ..]);
    }
    return kind orelse if (termination.signal != null) "native_crash" else if (termination.exit_code == 2) "infrastructure_error" else "unknown";
}

fn monotonicMilliseconds() u64 {
    var now: std.c.timespec = undefined;
    if (std.c.clock_gettime(.MONOTONIC, &now) != 0) fail("could not read monotonic clock");
    return @as(u64, @intCast(now.sec)) * 1000 + @as(u64, @intCast(now.nsec)) / 1_000_000;
}

var target_argument: ?[]const u8 = null;

/// Borrow a stable selector to forward to each supervised invocation.
pub fn setTargetArgument(argument: []const u8) void {
    target_argument = argument;
}

fn runChild(allocator: Allocator, argv: []const []const u8, log_path: []const u8, deadline_ms: ?u64) !ChildResult {
    const log_z = try allocator.dupeZ(u8, log_path);
    defer allocator.free(log_z);
    const log = std.c.fopen(log_z.ptr, "ab") orelse return error.CannotCreateLog;
    defer _ = std.c.fclose(log);
    const output = std.Io.File{ .handle = fileno(log), .flags = .{ .nonblocking = false } };
    var forwarded: std.ArrayList([]const u8) = .empty;
    defer forwarded.deinit(allocator);
    if (target_argument) |argument| {
        try forwarded.appendSlice(allocator, &.{ argv[0], argument });
        try forwarded.appendSlice(allocator, argv[1..]);
    }
    const child_argv = if (target_argument != null) forwarded.items else argv;
    var child = try std.process.spawn(io(), .{ .argv = child_argv, .stdin = .ignore, .stdout = .{ .file = output }, .stderr = .{ .file = output }, .pgid = 0 });
    const process_group = child.id.?;
    defer {
        _ = std.c.kill(-process_group, .KILL);
        child.kill(io());
    }
    const started = monotonicMilliseconds();
    while (true) {
        var status: c_int = 0;
        const pid = std.c.waitpid(child.id.?, &status, std.c.W.NOHANG);
        if (pid > 0) {
            // No pipes or progress handles were created. waitpid has reaped it.
            child.id = null;
            try stopProcessGroup(process_group);
            const bits: u32 = @bitCast(status);
            if (std.c.W.IFEXITED(bits)) return .{ .exit_code = std.c.W.EXITSTATUS(bits) };
            if (std.c.W.IFSIGNALED(bits)) return .{ .signal = @intFromEnum(std.c.W.TERMSIG(bits)) };
            return .{ .signal = 0 };
        }
        if (pid < 0) return error.CannotWaitForChild;
        if (deadline_ms) |deadline| if (monotonicMilliseconds() - started >= deadline) {
            _ = std.c.kill(-process_group, .KILL);
            child.kill(io());
            try stopProcessGroup(process_group);
            return .{ .timed_out = true };
        };
        const pause = std.c.timespec{ .sec = 0, .nsec = 10_000_000 };
        _ = std.c.nanosleep(&pause, null);
    }
}

fn stopProcessGroup(process_group: std.c.pid_t) !void {
    _ = std.c.kill(-process_group, .KILL);
    const started = monotonicMilliseconds();
    while (true) {
        const alive = std.c.kill(-process_group, @enumFromInt(0));
        if (alive != 0 and std.posix.errno(alive) == .SRCH) return;
        if (monotonicMilliseconds() - started >= 5000) return error.WorkerProcessGroupDidNotTerminate;
        const pause = std.c.timespec{ .sec = 0, .nsec = 10_000_000 };
        _ = std.c.nanosleep(&pause, null);
    }
}

const ExampleReport = struct {
    name: []const u8,
    revision: []const u8,
    input_sha256: []const u8,
    input_path: []const u8,
    outcome: []const u8,
    termination: ChildResult,
    finding_kind: ?[]const u8 = null,
    log: LogSpan = .{},
    // A missing worker result leaves these unknown. Fatal outcomes remain
    // separate from the partial evidence preserved in the original snapshot.
    metric_valid: ?bool = null,
    trace_rules_passed: ?bool = null,
    capture_complete: ?bool = null,
    observations: ?std.json.Value = null,
    diagnostics: ?std.json.Value = null,
    /// The declared goals this input reached, when it was kept.
    goals_reached: ?[]const []const u8 = null,
};

/// The first input that reached a goal: a declared example, an input of the
/// corpus exploration started from (which includes copies of the examples), or
/// one the search made. `replay`, `show` and `retain` take `input_path`; it is
/// null only when the bytes could not be saved.
const GoalWitness = struct {
    source: []const u8,
    example: ?[]const u8 = null,
    attempt: ?u64 = null,
    input_path: ?[]const u8 = null,
    input_sha256: []const u8,
    input_length: u64,
};
const GoalReport = struct {
    name: []const u8,
    reached: bool = false,
    /// Kept executions that reached it: each passing example, and each kept
    /// exploration execution, the corpus replayed at its start included.
    inputs: u64 = 0,
    first: ?GoalWitness = null,
};
const GoalsReport = struct {
    status: []const u8 = "not_graded",
    required: bool = false,
    declared: u64 = 0,
    reached: u64 = 0,
    unreached: []const []const u8 = &.{},
    inventory: []const GoalReport = &.{},
};

/// The campaign's goal tally. Examples are counted first, in declaration
/// order, then exploration, so a goal's witness is the earliest input of the
/// campaign that reached it.
const GoalTally = struct {
    goals: []GoalReport,

    fn init(allocator: Allocator, names: []const []const u8) !GoalTally {
        const goals = try allocator.alloc(GoalReport, names.len);
        for (goals, names) |*goal, name| goal.* = .{ .name = name };
        return .{ .goals = goals };
    }

    fn count(self: GoalTally, name: []const u8, witness: GoalWitness, inputs: u64) void {
        for (self.goals) |*goal| {
            if (!std.mem.eql(u8, goal.name, name)) continue;
            goal.reached = true;
            goal.inputs += inputs;
            if (goal.first == null) goal.first = witness;
            return;
        }
    }

    fn example(self: GoalTally, result: ExampleReport, length: u64) void {
        if (!commandIs(result.outcome, "passed")) return;
        for (result.goals_reached orelse return) |name| {
            self.count(name, .{ .source = "example", .example = result.name, .input_path = result.input_path, .input_sha256 = result.input_sha256, .input_length = length }, 1);
        }
    }

    fn report(self: GoalTally, allocator: Allocator, required: bool) !GoalsReport {
        var unreached: std.ArrayList([]const u8) = .empty;
        for (self.goals) |goal| if (!goal.reached) try unreached.append(allocator, goal.name);
        return .{
            .status = if (self.goals.len == 0) "none_declared" else if (unreached.items.len == 0) "reached" else "unreached",
            .required = required,
            .declared = self.goals.len,
            .reached = self.goals.len - unreached.items.len,
            .unreached = try unreached.toOwnedSlice(allocator),
            .inventory = try allocator.dupe(GoalReport, self.goals),
        };
    }
};
const ExplorationReport = struct {
    status: []const u8 = "not_requested",
    skipped_reason: ?[]const u8 = null,
    attempted: u64 = 0,
    accepted: u64 = 0,
    rejected: u64 = 0,
    termination: ?ChildResult = null,
    finding_kind: ?[]const u8 = null,
    log: ?LogSpan = null,
    original_input: ?[]const u8 = null,
    original_input_length: ?u64 = null,
    original_input_sha256: ?[]const u8 = null,
    original_input_complete: bool = false,
    original_trace: ?[]const u8 = null,
    original_trace_input_matches: bool = false,
    breadcrumbs: ?[]const u8 = null,
    breadcrumb_complete: bool = true,
};
const Report = struct {
    format: []const u8 = report_format,
    metric_version: []const u8 = metric_version,
    target: []const u8,
    host_target: []const u8,
    profile: []const u8,
    command: []const u8,
    outcome: []const u8 = "passed",
    baseline_status: []const u8 = "not_checked",
    baseline_path: []const u8,
    examples: []const ExampleReport = &.{},
    exploration: ExplorationReport = .{},
    error_message: ?[]const u8 = null,
    provenance: Provenance = .{},
    preparation: PreparationReport = .{},
    configuration: Configuration = .{},
    goals: GoalsReport = .{},
};

const Configuration = struct {
    invocation_deadline_ms: u64 = 10_000,
    campaign_deadline_ms: ?u64 = null,
    leak_detection: bool = true,
    detailed_capture: bool = false,
    corpus: ?[]const u8 = null,
    exploration_options: []const []const u8 = &.{},
};

const PreparationReport = struct {
    status: []const u8 = "not_requested",
    termination: ?ChildResult = null,
    finding_kind: ?[]const u8 = null,
    log: ?LogSpan = null,
    error_message: ?[]const u8 = null,
};
const PreparedInventory = struct { examples: []const Example = &.{}, goals: []const []const u8 = &.{}, evidence: PreparationReport };

const Provenance = struct {
    source_revision: ?[]const u8 = null,
    roc_version: ?[]const u8 = null,
    platform_release: ?[]const u8 = null,
    platform_sha256: ?[]const u8 = null,
};

const Options = struct {
    command: []const u8,
    arguments: []const []const u8 = &.{},
    report_dir: ?[]const u8 = null,
    baseline: ?[]const u8 = null,
    profile: []const u8 = "default",
    timeout_ms: u64 = 10_000,
    detailed: bool = false,
    no_detect_leaks: bool = false,
    allow_unreached_goals: bool = false,
    corpus: []const u8 = ".roc-fuzz/corpus",
    exploration_options: []const []const u8 = &.{},
    campaign_deadline_ms: ?u64 = 75_000,
    time_seconds: ?u64 = null,
    provenance: Provenance = .{},
};

fn valueAfter(arg: []const u8, prefix: []const u8) ?[]const u8 {
    return if (std.mem.startsWith(u8, arg, prefix)) arg[prefix.len..] else null;
}

fn parseOptions(allocator: Allocator, argc: usize, argv: [*][*:0]u8) !Options {
    var options = Options{ .command = if (argc < 2 or std.mem.startsWith(u8, std.mem.span(argv[1]), "--")) "run" else std.mem.span(argv[1]) };
    var next: usize = if (argc < 2 or std.mem.startsWith(u8, std.mem.span(argv[1]), "--")) 1 else 2;
    var positional: std.ArrayList([]const u8) = .empty;
    var exploration_args: std.ArrayList([]const u8) = .empty;
    var time: ?u64 = null;
    var has_runs = false;
    while (next < argc) : (next += 1) {
        const arg = std.mem.span(argv[next]);
        if (valueAfter(arg, "--report-dir=")) |v| {
            if (options.report_dir != null or v.len == 0) return error.InvalidReportDirectory;
            options.report_dir = v;
        } else if (valueAfter(arg, "--baseline=")) |v| {
            if (options.baseline != null or v.len == 0) return error.InvalidBaselinePath;
            options.baseline = v;
        } else if (valueAfter(arg, "--profile=")) |v| {
            if (v.len == 0) return error.InvalidProfile;
            options.profile = v;
        } else if (valueAfter(arg, "--timeout=")) |v| {
            const seconds = try std.fmt.parseUnsigned(u64, v, 10);
            if (seconds == 0) return error.InvalidInvocationDeadline;
            options.timeout_ms = try std.math.mul(u64, seconds, 1000);
            try exploration_args.append(allocator, arg);
        } else if (valueAfter(arg, "--time=")) |v| {
            time = try std.fmt.parseUnsigned(u64, v, 10);
            try exploration_args.append(allocator, arg);
        } else if (valueAfter(arg, "--runs=")) |v| {
            _ = try std.fmt.parseUnsigned(u64, v, 10);
            has_runs = true;
            try exploration_args.append(allocator, arg);
        } else if (std.mem.eql(u8, arg, "--detailed")) {
            options.detailed = true;
        } else if (std.mem.eql(u8, arg, "--no-detect-leaks")) {
            options.no_detect_leaks = true;
            try exploration_args.append(allocator, arg);
        } else if (std.mem.eql(u8, arg, "--allow-unreached-goals")) {
            options.allow_unreached_goals = true;
        } else if (valueAfter(arg, "--max-input-size=")) |value| {
            const length = try std.fmt.parseUnsigned(usize, value, 10);
            if (length == 0 or length > max_input_len) return error.InvalidMaximumInputSize;
            try exploration_args.append(allocator, arg);
        } else if (valueAfter(arg, "--source-revision=")) |v| {
            if (v.len == 0 or options.provenance.source_revision != null) return error.InvalidProvenance;
            options.provenance.source_revision = v;
        } else if (valueAfter(arg, "--roc-version=")) |v| {
            if (v.len == 0 or options.provenance.roc_version != null) return error.InvalidProvenance;
            options.provenance.roc_version = v;
        } else if (valueAfter(arg, "--platform-release=")) |v| {
            if (v.len == 0 or options.provenance.platform_release != null) return error.InvalidProvenance;
            options.provenance.platform_release = v;
        } else if (valueAfter(arg, "--platform-sha256=")) |v| {
            if (v.len != 64 or options.provenance.platform_sha256 != null) return error.InvalidProvenance;
            for (v) |byte| if (!std.ascii.isHex(byte)) return error.InvalidProvenance;
            options.provenance.platform_sha256 = v;
        } else if (std.mem.startsWith(u8, arg, "--memory-limit=") or std.mem.startsWith(u8, arg, "--dictionary=") or std.mem.startsWith(u8, arg, "--seed=")) {
            try exploration_args.append(allocator, arg);
        } else if (std.mem.eql(u8, arg, "--print-final-stats")) {
            // The exploration worker always records final counters.
        } else if (std.mem.startsWith(u8, arg, "-")) return error.UnknownQualityOption else try positional.append(allocator, arg);
    }
    if (time) |seconds| {
        options.campaign_deadline_ms = if (seconds == 0) null else try std.math.add(u64, try std.math.mul(u64, seconds, 1000), try std.math.add(u64, options.timeout_ms, 5000));
    } else if (has_runs) options.campaign_deadline_ms = null else options.campaign_deadline_ms = try std.math.add(u64, 65_000, options.timeout_ms);
    options.time_seconds = time;
    options.arguments = try positional.toOwnedSlice(allocator);
    options.exploration_options = try exploration_args.toOwnedSlice(allocator);
    if (std.mem.eql(u8, options.command, "run") or std.mem.eql(u8, options.command, "explore")) {
        if (options.arguments.len > 1) return error.TooManyCorpusDirectories;
        if (options.arguments.len == 1) options.corpus = options.arguments[0];
    }
    return options;
}

fn configuration(allocator: Allocator, options: Options) !Configuration {
    const exploring = commandIs(options.command, "run") or commandIs(options.command, "explore");
    var native_options: std.ArrayList([]const u8) = .empty;
    var bounded = false;
    if (exploring) {
        for (options.exploration_options) |argument| {
            const translations = .{
                .{ "--time=", "-max_total_time=" },
                .{ "--runs=", "-runs=" },
                .{ "--timeout=", "-timeout=" },
                .{ "--max-input-size=", "-max_len=" },
                .{ "--memory-limit=", "-rss_limit_mb=" },
                .{ "--dictionary=", "-dict=" },
                .{ "--seed=", "-seed=" },
            };
            inline for (translations) |translation| {
                if (valueAfter(argument, translation[0])) |value| {
                    try native_options.append(allocator, try std.fmt.allocPrint(allocator, "{s}{s}", .{ translation[1], value }));
                    if (comptime std.mem.eql(u8, translation[0], "--time=") or std.mem.eql(u8, translation[0], "--runs=")) bounded = true;
                }
            }
        }
        if (options.timeout_ms == 10_000) try native_options.append(allocator, "-timeout=10");
        if (!bounded) try native_options.append(allocator, "-max_total_time=60");
    }
    return .{
        .invocation_deadline_ms = options.timeout_ms,
        .campaign_deadline_ms = if (exploring) options.campaign_deadline_ms else null,
        .leak_detection = !options.no_detect_leaks,
        .detailed_capture = options.detailed,
        .corpus = if (exploring) options.corpus else null,
        .exploration_options = try native_options.toOwnedSlice(allocator),
    };
}

fn commandIs(command: []const u8, expected: []const u8) bool {
    return std.mem.eql(u8, command, expected);
}

fn pathsOverlap(allocator: Allocator, left: []const u8, right: []const u8) !bool {
    const a = try canonicalPath(allocator, left);
    const b = try canonicalPath(allocator, right);
    return std.mem.eql(u8, a, b) or std.mem.eql(u8, a, "/") or std.mem.eql(u8, b, "/") or
        (std.mem.startsWith(u8, a, b) and a.len > b.len and a[b.len] == std.fs.path.sep) or
        (std.mem.startsWith(u8, b, a) and b.len > a.len and b[a.len] == std.fs.path.sep);
}

fn createReportDirectory(allocator: Allocator, override: ?[]const u8) ![]const u8 {
    const path = override orelse try std.fmt.allocPrint(allocator, ".roc-fuzz/reports/{d}-{d}", .{ std.c.getpid(), monotonicMilliseconds() });
    if (override != null) {
        var dir = std.Io.Dir.cwd().openDir(io(), path, .{ .iterate = true }) catch |err| switch (err) {
            error.FileNotFound => {
                try std.Io.Dir.createDirPath(.cwd(), io(), path);
                return path;
            },
            else => return err,
        };
        defer dir.close(io());
        var iterator = dir.iterate();
        if (try iterator.next(io()) != null) return error.ReportDirectoryNotEmpty;
    } else try std.Io.Dir.createDirPath(.cwd(), io(), path);
    return path;
}

fn worker(allocator: Allocator, argc: usize, argv: [*][*:0]u8, adapter: Adapter) noreturn {
    if (argc < 5 or argc > 8) fail("invalid worker protocol");
    if (argc == 8) attachHealth(std.mem.span(argv[7])) catch |err| failError(err);
    if (argc >= 7) worker_leaks = !commandIs(std.mem.span(argv[6]), "no-leaks");
    const input = readFile(allocator, std.mem.span(argv[2]), max_input_len) catch |err| failError(err);
    const output = std.mem.span(argv[3]);
    const mode = std.mem.span(argv[4]);
    var capture: Capture = .normal;
    if (argc >= 6 and commandIs(std.mem.span(argv[5]), "detailed")) capture = .detailed;
    if (commandIs(mode, "show")) {
        const shown = adapter.show(allocator, input) catch |err| failError(err);
        atomicWrite(allocator, output, shown) catch |err| failError(err);
        std.c._exit(0);
    }
    if (!commandIs(mode, "run")) fail("invalid worker mode");
    const result = adapter.run_one(allocator, input, capture) catch |err| failError(err);
    const observations = std.json.parseFromSlice(std.json.Value, allocator, result.observations_json, .{}) catch |err| failError(err);
    const diagnostic = if (result.diagnostics_json) |bytes| (std.json.parseFromSlice(std.json.Value, allocator, bytes, .{}) catch |err| failError(err)).value else null;
    const wire = WorkerWire{
        .format = worker_format,
        .metric_version = metric_version,
        .accepted = result.accepted,
        .metric_valid = result.metric_valid,
        .trace_rules_passed = result.trace_rules_passed,
        .capture_complete = result.capture_complete,
        .observations = observations.value,
        .diagnostics = diagnostic,
        .goals_declared = result.goals_declared,
        .goals_reached = result.goals_reached,
    };
    const encoded = json(allocator, wire) catch |err| failError(err);
    atomicWrite(allocator, output, encoded) catch |err| failError(err);
    std.c._exit(0);
}

fn prepareWorker(allocator: Allocator, argc: usize, argv: [*][*:0]u8, adapter: Adapter) noreturn {
    if (argc != 3) fail("invalid preparation protocol");
    const examples = adapter.prepare_examples(allocator) catch |err| failError(err);
    validateExamples(examples) catch |err| failError(err);
    const goals: []const []const u8 = if (adapter.prepare_goals) |prepare| prepare(allocator) catch |err| failError(err) else &.{};
    validateGoals(goals) catch |err| failError(err);
    const encoded = json(allocator, PreparationWire{ .format = preparation_format, .examples = examples, .goals = goals }) catch |err| failError(err);
    if (encoded.len > max_json_len) fail("prepared example inventory exceeds transport budget");
    atomicWrite(allocator, std.mem.span(argv[2]), encoded) catch |err| failError(err);
    std.c._exit(0);
}

fn prepareSupervised(allocator: Allocator, executable: []const u8, report_dir: []const u8, log_path: []const u8, timeout_ms: u64) !PreparedInventory {
    const output = try std.fs.path.join(allocator, &.{ report_dir, "prepared-examples.json" });
    const arguments = [_][]const u8{ executable, "__quality-prepare", output };
    const log_start = try logSize(log_path);
    const termination = try runChild(allocator, &arguments, log_path, timeout_ms);
    const span = LogSpan{ .offset = log_start, .length = (try logSize(log_path)) - log_start };
    const evidence = PreparationReport{ .status = if (termination.passed()) "passed" else "failed", .termination = termination, .finding_kind = try classifyFinding(allocator, log_path, span, termination), .log = span, .error_message = if (termination.timed_out) "ExamplePreparationTimeout" else if (termination.signal != null) "ExamplePreparationCrash" else if (!termination.passed()) "ExamplePreparationFailed" else null };
    if (!termination.passed()) return .{ .evidence = evidence };
    const bytes = try readFile(allocator, output, max_json_len);
    const prepared = try std.json.parseFromSlice(PreparationWire, allocator, bytes, .{ .allocate = .alloc_always });
    if (!std.mem.eql(u8, prepared.value.format, preparation_format)) return error.UnsupportedPreparationFormat;
    try validateExamples(prepared.value.examples);
    try validateGoals(prepared.value.goals);
    return .{ .examples = prepared.value.examples, .goals = prepared.value.goals, .evidence = evidence };
}

fn unsigned(value: std.json.Value) ?u64 {
    return switch (value) {
        .integer => |number| if (number >= 0) @intCast(number) else null,
        .number_string => |number| std.fmt.parseUnsigned(u64, number, 10) catch null,
        else => null,
    };
}

fn unsignedField(object: std.json.Value, name: []const u8) ?u64 {
    if (object != .object) return null;
    return unsigned(object.object.get(name) orelse return null);
}

fn wireValid(wire: WorkerWire) bool {
    if (!std.mem.eql(u8, wire.format, worker_format) or !std.mem.eql(u8, wire.metric_version, metric_version) or !wire.accepted or !wire.metric_valid or !wire.trace_rules_passed) return false;
    if (wire.observations != .array or wire.observations.array.items.len == 0) return false;
    for (wire.observations.array.items, 0..) |region, index| {
        if (region != .object) return false;
        const complete = region.object.get("complete") orelse return false;
        if (complete != .bool or !complete.bool) return false;
        const id = unsignedField(region, "id") orelse return false;
        const parent = unsignedField(region, "parent_id") orelse return false;
        const occurrence = unsignedField(region, "occurrence") orelse return false;
        const name = region.object.get("name") orelse return false;
        if (name != .string or name.string.len == 0 or id != index + 1 or parent >= id) return false;
        if (index == 0) {
            if (parent != 0 or occurrence != 1 or !std.mem.eql(u8, name.string, "$property")) return false;
        } else if (parent == 0) return false;
        var expected_occurrence: u64 = 1;
        for (wire.observations.array.items[0..index]) |previous| {
            if ((unsignedField(previous, "parent_id") orelse return false) == parent and std.mem.eql(u8, previous.object.get("name").?.string, name.string)) expected_occurrence += 1;
        }
        if (occurrence != expected_occurrence) return false;
        const stats = region.object.get("stats") orelse return false;
        if (stats != .object or stats.object.count() != 9) return false;
        inline for (.{ "allocs", "reallocs", "deallocs", "requested_bytes", "entry_live_allocs", "entry_live_bytes", "exit_live_allocs", "exit_live_bytes", "peak_live_bytes" }) |key| {
            _ = unsignedField(stats, key) orelse return false;
        }
        const entry_allocs = unsignedField(stats, "entry_live_allocs").?;
        const exit_allocs = unsignedField(stats, "exit_live_allocs").?;
        const allocs = unsignedField(stats, "allocs").?;
        const deallocs = unsignedField(stats, "deallocs").?;
        if (@as(u128, entry_allocs) + allocs != @as(u128, exit_allocs) + deallocs) return false;
        const peak_bytes = unsignedField(stats, "peak_live_bytes").?;
        if (peak_bytes < unsignedField(stats, "entry_live_bytes").? or peak_bytes < unsignedField(stats, "exit_live_bytes").?) return false;
    }
    return true;
}

/// `goals_declared` receives the size of the inventory the worker saw, when
/// it returned a result.
fn runExample(allocator: Allocator, executable: []const u8, example: Example, index: usize, report_dir: []const u8, log_path: []const u8, options: Options, adapter: Adapter, goals_declared: ?*u64) !ExampleReport {
    const input_path = try std.fmt.allocPrint(allocator, "{s}/example-{d}.bin", .{ report_dir, index });
    const result_path = try std.fmt.allocPrint(allocator, "{s}/example-{d}.json", .{ report_dir, index });
    try writeFile(allocator, input_path, example.bytes);
    const shared_path = try std.fmt.allocPrint(allocator, "{s}/example-{d}.shared", .{ report_dir, index });
    const health = try mapHealth(allocator, shared_path, true);
    defer _ = std.c.munmap(@ptrCast(@alignCast(health)), @sizeOf(Health));
    const argv = [_][]const u8{ executable, "__quality-worker", input_path, result_path, "run", if (options.detailed) "detailed" else "normal", if (options.no_detect_leaks) "no-leaks" else "leaks", shared_path };
    const log_start = try logSize(log_path);
    const termination = try runChild(allocator, &argv, log_path, options.timeout_ms);
    const log_span = LogSpan{ .offset = log_start, .length = (try logSize(log_path)) - log_start };
    var report = ExampleReport{ .name = example.name, .revision = example.revision, .input_sha256 = try hash(allocator, example.bytes), .input_path = input_path, .outcome = if (termination.timed_out) "timeout" else if (termination.signal != null) "crash" else "failed", .termination = termination, .finding_kind = try classifyFinding(allocator, log_path, log_span, termination), .log = log_span };
    if (health.observation_initialized != 0) if (adapter.original_snapshot) |snapshot| {
        const snapshot_json = try snapshot(allocator, &health.observation_storage);
        const trace_path = try std.fmt.allocPrint(allocator, "{s}/example-{d}-original-trace.json", .{ report_dir, index });
        try atomicWrite(allocator, trace_path, snapshot_json);
        report.diagnostics = (try std.json.parseFromSlice(std.json.Value, allocator, snapshot_json, .{})).value;
    };
    if (!termination.passed()) return report;
    const bytes = readFile(allocator, result_path, max_json_len) catch {
        report.outcome = "incomplete_observations";
        report.finding_kind = "invalid_observation";
        return report;
    };
    const parsed = std.json.parseFromSlice(WorkerWire, allocator, bytes, .{ .allocate = .alloc_always }) catch {
        report.outcome = "invalid_observations";
        report.finding_kind = "invalid_observation";
        return report;
    };
    const wire = parsed.value;
    report.metric_valid = wire.metric_valid;
    report.trace_rules_passed = wire.trace_rules_passed;
    report.capture_complete = wire.capture_complete;
    report.observations = wire.observations;
    if (wire.diagnostics != null) report.diagnostics = wire.diagnostics;
    // Only a kept input reaches a goal; a rejected one is outside the domain.
    report.goals_reached = if (wire.accepted) wire.goals_reached else &.{};
    if (goals_declared) |declared| declared.* = wire.goals_declared;
    report.outcome = if (!wire.accepted) "rejected" else if (!wire.metric_valid) "invalid_metrics" else if (!wire.trace_rules_passed) "trace_violation" else if (!wireValid(wire)) "incomplete_observations" else "passed";
    report.finding_kind = if (!wire.accepted) null else if (!wire.metric_valid) "invalid_observation" else if (!wire.trace_rules_passed) "trace_violation" else if (!wireValid(wire)) "invalid_observation" else null;
    return report;
}

/// The SHA-256 of each input exploration starts from, so a goal the saved
/// corpus reached is not reported as one the search found.
fn corpusDigests(allocator: Allocator, corpus: []const u8) ![]const [32]u8 {
    var digests: std.ArrayList([32]u8) = .empty;
    var directory = try std.Io.Dir.cwd().openDir(io(), corpus, .{ .iterate = true });
    defer directory.close(io());
    var iterator = directory.iterate();
    while (try iterator.next(io())) |entry| {
        if (entry.kind != .file) continue;
        const path = try std.fs.path.join(allocator, &.{ corpus, entry.name });
        const bytes = readFile(std.heap.c_allocator, path, max_input_len) catch continue;
        defer std.heap.c_allocator.free(bytes);
        try digests.append(allocator, try hashBytes(bytes));
    }
    return digests.toOwnedSlice(allocator);
}

fn containsDigest(digests: []const [32]u8, digest: [32]u8) bool {
    for (digests) |candidate| if (std.mem.eql(u8, &candidate, &digest)) return true;
    return false;
}

fn exploration(allocator: Allocator, executable: []const u8, report_dir: []const u8, log_path: []const u8, options: Options, examples: []const Example, tally: GoalTally, adapter: Adapter) !ExplorationReport {
    try std.Io.Dir.createDirPath(.cwd(), io(), options.corpus);
    // Source-authored examples are real seeds. Their declarations are checked
    // independently, so a corpus merge may drop these copies without losing tests.
    for (examples) |example| {
        const digest = try hash(allocator, example.bytes);
        const seed_path = try std.fs.path.join(allocator, &.{ options.corpus, digest });
        try writeFile(allocator, seed_path, example.bytes);
    }
    const shared_path = try std.fs.path.join(allocator, &.{ report_dir, "original-run.shared" });
    const health = try mapHealth(allocator, shared_path, true);
    defer _ = std.c.munmap(@ptrCast(@alignCast(health)), @sizeOf(Health));
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.appendSlice(allocator, &.{ executable, "__quality-explore", shared_path, options.corpus });
    try argv.appendSlice(allocator, options.exploration_options);
    if (options.timeout_ms == 10_000) try argv.append(allocator, "--timeout=10");
    const failures = try std.fs.path.join(allocator, &.{ report_dir, "failures" });
    try argv.append(allocator, try std.fmt.allocPrint(allocator, "--artifact-dir={s}", .{failures}));
    const witnesses = try std.fs.path.join(allocator, &.{ report_dir, "goals" });
    var corpus: []const [32]u8 = &.{};
    if (tally.goals.len != 0) {
        try std.Io.Dir.createDirPath(.cwd(), io(), witnesses);
        try argv.append(allocator, try std.fmt.allocPrint(allocator, "--goal-dir={s}", .{witnesses}));
        corpus = try corpusDigests(allocator, options.corpus);
    }
    try argv.append(allocator, "--print-final-stats");
    const log_start = try logSize(log_path);
    const termination = try runChild(allocator, argv.items, log_path, options.campaign_deadline_ms);
    const log_span = LogSpan{ .offset = log_start, .length = (try logSize(log_path)) - log_start };
    var report = ExplorationReport{
        .attempted = @atomicLoad(u64, &health.attempted, .acquire),
        .accepted = @atomicLoad(u64, &health.accepted, .acquire),
        .rejected = @atomicLoad(u64, &health.rejected, .acquire),
        .termination = termination,
        .finding_kind = try classifyFinding(allocator, log_path, log_span, termination),
        .log = log_span,
    };
    report.status = if (!termination.passed()) "finding" else if (report.accepted == 0) "inconclusive" else "passed";
    // The worker counted inputs it kept, so the tally stands however it ended.
    // An inventory of another size means it never reached its first input.
    if (health.goal_count == tally.goals.len) for (tally.goals, 0..) |goal, index| {
        const record = health.goals[index];
        const inputs = @atomicLoad(u64, &health.goals[index].inputs, .acquire);
        if (inputs == 0) continue;
        const path = try goalWitnessPath(allocator, witnesses, index);
        const saved = record.witness_saved != 0 and if (readFile(allocator, path, max_input_len)) |bytes| std.mem.eql(u8, &(try hashBytes(bytes)), &record.first_sha256) else |_| false;
        tally.count(goal.name, .{
            .source = if (containsDigest(corpus, record.first_sha256)) "corpus" else "exploration",
            .attempt = record.first_attempt,
            .input_path = if (saved) path else null,
            .input_sha256 = try allocator.dupe(u8, &std.fmt.bytesToHex(record.first_sha256, .lower)),
            .input_length = record.first_length,
        }, inputs);
    };
    if (health.observation_initialized != 0) if (adapter.original_snapshot) |snapshot| {
        const original_path = try std.fs.path.join(allocator, &.{ report_dir, "original-trace.json" });
        try atomicWrite(allocator, original_path, try snapshot(allocator, &health.observation_storage));
        report.original_trace = original_path;
        report.original_trace_input_matches = health.observation_input_sequence == health.input_sequence and health.input_sequence % 2 == 0;
        if (!termination.passed() and report.original_trace_input_matches and report.finding_kind != null and std.mem.eql(u8, report.finding_kind.?, "invalid_observation")) {
            const snapshot_value = (try std.json.parseFromSlice(std.json.Value, allocator, try snapshot(allocator, &health.observation_storage), .{})).value;
            if (snapshot_value == .object) if (snapshot_value.object.get("trace_rules_passed")) |passed| {
                if (passed == .bool and !passed.bool) report.finding_kind = "trace_violation";
            };
        }
    };
    // The child is terminated before reads, so no concurrent writer remains.
    // A killed writer can leave an odd sequence: mark that capture incomplete.
    if (health.attempted != 0) {
        const input_path = try std.fs.path.join(allocator, &.{ report_dir, "original-input.bin" });
        const count: usize = @intCast(@min(health.input_captured, health.input.len));
        try writeFile(allocator, input_path, health.input[0..count]);
        report.original_input = input_path;
        report.original_input_length = health.input_length;
        report.original_input_sha256 = try allocator.dupe(u8, &std.fmt.bytesToHex(health.input_sha256, .lower));
        report.original_input_complete = health.input_sequence % 2 == 0 and health.input_captured == health.input_length;
    }
    if (health.breadcrumb_length != 0) {
        const breadcrumb_path = try std.fs.path.join(allocator, &.{ report_dir, "original-breadcrumbs.json" });
        const count: usize = @intCast(@min(health.breadcrumb_length, health.breadcrumb.len));
        try writeFile(allocator, breadcrumb_path, health.breadcrumb[0..count]);
        report.breadcrumbs = breadcrumb_path;
        report.breadcrumb_complete = health.breadcrumb_sequence % 2 == 0 and health.breadcrumb_truncated == 0;
    }
    return report;
}

/// How many unreached goals the console names; the report names them all.
const printed_goal_limit = 8;

fn printResult(allocator: Allocator, report: Report, report_dir: []const u8) !void {
    var message: std.ArrayList(u8) = .empty;
    try message.print(allocator, "{s}: {s}; baseline {s}; examples {d}; exploration {s} (attempted {d}, accepted {d}, rejected {d})", .{ report.target, report.outcome, report.baseline_status, report.examples.len, report.exploration.status, report.exploration.attempted, report.exploration.accepted, report.exploration.rejected });
    if (report.goals.declared != 0) try message.print(allocator, "; {s} {d} of {d} goals", .{ if (commandIs(report.goals.status, "not_graded")) "this input reached" else "reached", report.goals.reached, report.goals.declared });
    try message.append(allocator, '\n');
    if (report.goals.unreached.len != 0) try message.print(allocator, "Never reached ({d}):\n", .{report.goals.unreached.len});
    for (report.goals.unreached, 0..) |goal, index| {
        if (index == printed_goal_limit) {
            try message.print(allocator, "  and {d} more, listed in summary.md\n", .{report.goals.unreached.len - index});
            break;
        }
        try message.print(allocator, "  {s}\n", .{goal});
    }
    // One replayed input is no campaign, so it is told what it reached.
    if (commandIs(report.goals.status, "not_graded") and report.examples.len == 1) {
        const reached = report.examples[0].goals_reached orelse &.{};
        if (reached.len != 0) try message.appendSlice(allocator, "Reached:\n");
        for (reached) |goal| try message.print(allocator, "  {s}\n", .{goal});
    }
    try message.print(allocator, "Report: {s}/report.json\n", .{report_dir});
    writeFd(2, message.items);
}

/// A goal name inside a Markdown table cell or list item.
fn markdownText(allocator: Allocator, text: []const u8) ![]const u8 {
    var escaped: std.ArrayList(u8) = .empty;
    for (text) |byte| {
        if (byte == '|' or byte == '`' or byte == '\\') try escaped.append(allocator, '\\');
        try escaped.append(allocator, if (byte == '\n' or byte == '\r') ' ' else byte);
    }
    return escaped.toOwnedSlice(allocator);
}

/// The Goals section of `summary.md`. Goals never reached come first, as the
/// part a reader acts on, and each goal appears once: unreached ones in the
/// list, reached ones in the table.
fn goalSummary(allocator: Allocator, goals: GoalsReport) ![]const u8 {
    if (goals.declared == 0) return "";
    var text: std.ArrayList(u8) = .empty;
    try text.print(allocator, "\n## Goals\n\nReached {d} of {d} declared {s}.", .{ goals.reached, goals.declared, if (goals.declared == 1) "goal" else "goals" });
    if (goals.unreached.len != 0) {
        try text.appendSlice(allocator, if (goals.required) " A campaign that breaks no rule and leaves a goal unreached is `inconclusive`." else " Unreached goals do not change this outcome.");
        try text.print(allocator, "\n\nNever reached ({d}):\n\n", .{goals.unreached.len});
        for (goals.unreached) |goal| try text.print(allocator, "- {s}\n", .{try markdownText(allocator, goal)});
    } else try text.append(allocator, '\n');
    if (goals.reached == 0) return text.toOwnedSlice(allocator);
    try text.appendSlice(allocator, "\n| Reached goal | Kept inputs | First reached by | Witness |\n| --- | ---: | --- | --- |\n");
    for (goals.inventory) |goal| {
        const first = goal.first orelse continue;
        const by = if (first.example) |example|
            try std.fmt.allocPrint(allocator, "example {s}", .{try markdownText(allocator, example)})
        else
            try std.fmt.allocPrint(allocator, "{s} input {d}", .{ if (commandIs(first.source, "corpus")) "corpus" else "exploration", first.attempt orelse 0 });
        const witness = if (first.input_path) |path| try std.fmt.allocPrint(allocator, "`{s}`", .{try markdownText(allocator, path)}) else "not saved";
        try text.print(allocator, "| {s} | {d} | {s} | {s} |\n", .{ try markdownText(allocator, goal.name), goal.inputs, by, witness });
    }
    return text.toOwnedSlice(allocator);
}

fn writeReportFiles(allocator: Allocator, report: Report, report_dir: []const u8) !void {
    const path = try std.fs.path.join(allocator, &.{ report_dir, "report.json" });
    try atomicWrite(allocator, path, try json(allocator, report));
    const summary_path = try std.fs.path.join(allocator, &.{ report_dir, "summary.md" });
    const summary = try std.fmt.allocPrint(allocator, "# roc-fuzz: {s}\n\nOutcome: **{s}**. Baseline: **{s}**.\n\nDeclared examples: {d}. Exploration: **{s}**.\n\nAttempted: {d}; accepted: {d}; rejected: {d}.\n{s}", .{ report.target, report.outcome, report.baseline_status, report.examples.len, report.exploration.status, report.exploration.attempted, report.exploration.accepted, report.exploration.rejected, try goalSummary(allocator, report.goals) });
    try atomicWrite(allocator, summary_path, summary);
}

fn saveReport(allocator: Allocator, report: Report, report_dir: []const u8) !void {
    try writeReportFiles(allocator, report, report_dir);
    if (!commandIs(report.command, "measure")) try printResult(allocator, report, report_dir);
}

fn checkAndExplore(allocator: Allocator, executable: []const u8, target: []const u8, options: Options, adapter: Adapter) !u8 {
    if (!commandIs(options.command, "run") and !commandIs(options.command, "explore") and options.arguments.len != 0) return error.UnexpectedCommandArgument;
    const report_dir = try createReportDirectory(allocator, options.report_dir);
    const log_path = try std.fs.path.join(allocator, &.{ report_dir, "run.log" });
    try writeFile(allocator, log_path, "");
    const baseline_path = try baselinePath(allocator, target, options.baseline);
    if (try pathsOverlap(allocator, report_dir, baseline_path)) return error.BaselineOverlapsReportDirectory;
    if ((commandIs(options.command, "run") or commandIs(options.command, "explore")) and try pathsOverlap(allocator, report_dir, options.corpus)) return error.CorpusOverlapsReportDirectory;
    var report = Report{ .target = target, .host_target = hostTarget(), .profile = options.profile, .command = options.command, .baseline_path = baseline_path, .provenance = options.provenance, .configuration = try configuration(allocator, options) };
    const prepared = prepareSupervised(allocator, executable, report_dir, log_path, options.timeout_ms) catch |err| {
        report.outcome = "infrastructure_error";
        report.error_message = @errorName(err);
        report.exploration = .{ .status = "skipped", .skipped_reason = "example_preparation_failed" };
        try saveReport(allocator, report, report_dir);
        return 2;
    };
    report.preparation = prepared.evidence;
    if (commandIs(prepared.evidence.status, "failed")) {
        // The reason, such as an invalid goal inventory, is in the child's
        // output, which is all the log holds so far.
        if (try logSize(log_path) <= 16 * 1024) printLog(log_path, allocator) catch {};
        report.outcome = "infrastructure_error";
        report.error_message = prepared.evidence.error_message;
        report.exploration = .{ .status = "skipped", .skipped_reason = "example_preparation_failed" };
        try saveReport(allocator, report, report_dir);
        return 2;
    }
    const examples = prepared.examples;
    validateExamples(examples) catch |err| {
        report.outcome = "infrastructure_error";
        report.error_message = @errorName(err);
        report.exploration = .{ .status = "skipped", .skipped_reason = "invalid_example_inventory" };
        try saveReport(allocator, report, report_dir);
        return 2;
    };
    // Goals grade the campaign this command runs: its examples, then its
    // exploration. Acceptance is about allocation observations alone.
    const tally = try GoalTally.init(allocator, prepared.goals);
    const goals_required = !options.allow_unreached_goals and !commandIs(options.command, "accept");
    report.goals = try tally.report(allocator, goals_required);
    const checking = !commandIs(options.command, "explore");
    if (checking) {
        var example_reports: std.ArrayList(ExampleReport) = .empty;
        var accepted: std.ArrayList(BaselineExample) = .empty;
        var valid = true;
        for (examples, 0..) |example, index| {
            const result = try runExample(allocator, executable, example, index, report_dir, log_path, options, adapter, null);
            try example_reports.append(allocator, result);
            tally.example(result, example.bytes.len);
            if (!commandIs(result.outcome, "passed")) valid = false else try accepted.append(allocator, .{ .name = example.name, .revision = example.revision, .input_sha256 = result.input_sha256, .observations = result.observations.? });
        }
        report.examples = try example_reports.toOwnedSlice(allocator);
        report.goals = try tally.report(allocator, goals_required);
        if (!valid) {
            report.outcome = "finding";
            report.baseline_status = "not_checked";
            report.exploration = .{ .status = "skipped", .skipped_reason = "example_checks_failed" };
            try saveReport(allocator, report, report_dir);
            return 1;
        }
        const current = BaselineEntry{ .host_target = hostTarget(), .profile = options.profile, .metric_version = metric_version, .examples = accepted.items };
        if (commandIs(options.command, "accept") and examples.len == 0) {
            report.outcome = "infrastructure_error";
            report.baseline_status = "not_checked";
            report.error_message = "CannotAcceptEmptyExampleInventory";
            try saveReport(allocator, report, report_dir);
            return 2;
        }
        const prior = baselineLoad(allocator, baseline_path, target) catch |err| {
            report.outcome = "infrastructure_error";
            report.baseline_status = "invalid";
            report.error_message = @errorName(err);
            report.exploration = .{ .status = "skipped", .skipped_reason = "baseline_unreadable" };
            try saveReport(allocator, report, report_dir);
            return 2;
        };
        if (commandIs(options.command, "accept")) {
            const updated = try replaceEntry(allocator, prior, target, current);
            const updated_bytes = try json(allocator, updated);
            report.baseline_status = "accepted";
            // Complete every fallible evidence write before committing the
            // baseline. There are no required filesystem writes after commit.
            writeReportFiles(allocator, report, report_dir) catch |err| {
                report.outcome = "infrastructure_error";
                report.baseline_status = "write_failed";
                report.error_message = @errorName(err);
                const failed_report_path = try std.fs.path.join(allocator, &.{ report_dir, "report.json" });
                atomicWrite(allocator, failed_report_path, try json(allocator, report)) catch {};
                printResult(allocator, report, report_dir) catch {};
                return 2;
            };
            atomicWrite(allocator, baseline_path, updated_bytes) catch |err| {
                report.outcome = "infrastructure_error";
                report.baseline_status = "write_failed";
                report.error_message = @errorName(err);
                try saveReport(allocator, report, report_dir);
                return 2;
            };
            // A console allocation failure cannot turn a committed acceptance
            // into a failed transaction. All durable outputs already exist.
            printResult(allocator, report, report_dir) catch {};
            return 0;
        } else {
            report.baseline_status = "unbaselined";
            if (prior) |baseline| for (baseline.entries) |entry| {
                if (commandIs(entry.host_target, current.host_target) and commandIs(entry.profile, current.profile)) {
                    report.baseline_status = if (entryEqual(entry, current)) "matched" else "changed";
                    break;
                }
            };
            if (commandIs(report.baseline_status, "changed")) {
                report.outcome = "baseline_changed";
                report.exploration = .{ .status = "skipped", .skipped_reason = "baseline_changed" };
                try saveReport(allocator, report, report_dir);
                return 1;
            }
        }
    }
    if (commandIs(options.command, "run") or commandIs(options.command, "explore")) {
        report.exploration = try exploration(allocator, executable, report_dir, log_path, options, examples, tally, adapter);
        report.goals = try tally.report(allocator, goals_required);
        if (!commandIs(report.exploration.status, "passed")) report.outcome = if (commandIs(report.exploration.status, "inconclusive")) "inconclusive" else "finding";
    }
    // No rule broke, and the campaign did not exercise what the target says a
    // campaign must. That is missing evidence, never a finding.
    if (commandIs(report.outcome, "passed") and report.goals.required and commandIs(report.goals.status, "unreached")) report.outcome = "inconclusive";
    try saveReport(allocator, report, report_dir);
    return if (commandIs(report.outcome, "passed")) 0 else 1;
}

fn runInputCommand(allocator: Allocator, executable: []const u8, target: []const u8, options: Options, adapter: Adapter) !u8 {
    if (options.arguments.len != 1) return error.ExpectedOneInput;
    const report_dir = try createReportDirectory(allocator, options.report_dir);
    const log_path = try std.fs.path.join(allocator, &.{ report_dir, "run.log" });
    const bytes = try readFile(allocator, options.arguments[0], max_input_len);
    const example = Example{ .name = options.arguments[0], .revision = "replay", .bytes = bytes };
    if (commandIs(options.command, "show")) {
        const input_path = try std.fs.path.join(allocator, &.{ report_dir, "input.bin" });
        const shown_path = try std.fs.path.join(allocator, &.{ report_dir, "shown.txt" });
        try writeFile(allocator, input_path, bytes);
        const argv = [_][]const u8{ executable, "__quality-worker", input_path, shown_path, "show" };
        const result = try runChild(allocator, &argv, log_path, options.timeout_ms);
        if (!result.passed()) return 1;
        writeFd(1, try readFile(allocator, shown_path, max_json_len));
        writeFd(1, "\n");
        return 0;
    }
    var goals_declared: u64 = 0;
    const result = try runExample(allocator, executable, example, 0, report_dir, log_path, options, adapter, &goals_declared);
    if (commandIs(options.command, "measure")) {
        if (result.observations) |observations| {
            writeFd(1, try json(allocator, observations));
            writeFd(1, "\n");
        }
    }
    if (options.detailed) if (result.diagnostics) |diagnostic| {
        const trace_path = try std.fs.path.join(allocator, &.{ report_dir, "trace.json" });
        try atomicWrite(allocator, trace_path, try json(allocator, diagnostic));
    };
    const passed = commandIs(result.outcome, "passed");
    const reports = try allocator.alloc(ExampleReport, 1);
    reports[0] = result;
    const report = Report{
        .target = target,
        .host_target = hostTarget(),
        .profile = options.profile,
        .command = options.command,
        .outcome = if (passed) "passed" else "finding",
        .baseline_path = try baselinePath(allocator, target, options.baseline),
        .examples = reports,
        .provenance = options.provenance,
        .configuration = try configuration(allocator, options),
        .goals = .{
            // One input is not a campaign: `examples[0].goals_reached` names what
            // it reached, and no goal is graded.
            .declared = goals_declared,
            .reached = if (result.goals_reached) |reached| reached.len else 0,
        },
    };
    try saveReport(allocator, report, report_dir);
    return if (passed) 0 else 1;
}

fn retain(allocator: Allocator, argc: usize, argv: [*][*:0]u8, executable: []const u8) !u8 {
    if (argc < 5 or argc > 7) return error.RetainRequiresInputNameOutput;
    const input = std.mem.span(argv[2]);
    var name: ?[]const u8 = null;
    var output: ?[]const u8 = null;
    var i: usize = 3;
    while (i < argc) : (i += 1) {
        const flag = std.mem.span(argv[i]);
        if (valueAfter(flag, "--name=")) |value| {
            if (name != null) return error.InvalidRetainOption;
            name = value;
        } else if (valueAfter(flag, "--output=")) |value| {
            if (output != null) return error.InvalidRetainOption;
            output = value;
        } else if (commandIs(flag, "--name") and name == null and i + 1 < argc) {
            i += 1;
            name = std.mem.span(argv[i]);
        } else if (commandIs(flag, "--output") and output == null and i + 1 < argc) {
            i += 1;
            output = std.mem.span(argv[i]);
        } else return error.InvalidRetainOption;
    }
    const retained_name = name orelse return error.MissingRetainName;
    const directory = output orelse return error.MissingRetainOutput;
    if (retained_name.len == 0 or directory.len == 0 or commandIs(retained_name, ".") or commandIs(retained_name, "..")) return error.InvalidRetainName;
    for (retained_name) |byte| if (!std.ascii.isAlphanumeric(byte) and byte != '-' and byte != '_' and byte != '.') return error.InvalidRetainName;
    const bytes = try readFile(allocator, input, max_input_len);
    try std.Io.Dir.createDirPath(.cwd(), io(), directory);
    const path = try std.fmt.allocPrint(allocator, "{s}/{s}.bin", .{ directory, retained_name });
    // Retention must not silently replace a witness with a different input.
    const existing = readFile(allocator, path, max_input_len) catch |err| switch (err) {
        error.FileNotFound => null,
        else => return err,
    };
    if (existing) |old| if (!std.mem.eql(u8, old, bytes)) return error.RetainedWitnessAlreadyExists;
    try atomicWrite(allocator, path, bytes);
    // Save the original before attempting arbitrary target rendering. Rendering
    // has the same fresh-process isolation and deadline as replay and checking.
    const report_dir = try createReportDirectory(allocator, null);
    const shown_path = try std.fs.path.join(allocator, &.{ report_dir, "shown.txt" });
    const log_path = try std.fs.path.join(allocator, &.{ report_dir, "run.log" });
    const child_arguments = [_][]const u8{ executable, "__quality-worker", path, shown_path, "show" };
    const rendering = try runChild(allocator, &child_arguments, log_path, 10_000);
    writeFd(1, "Fuzz.saved({\n    name: ");
    writeFd(1, try json(allocator, retained_name));
    writeFd(1, ",\n    revision: \"1\",\n    bytes: [");
    for (bytes, 0..) |byte, index| {
        if (index != 0) writeFd(1, ", ");
        writeFd(1, try std.fmt.allocPrint(allocator, "{d}", .{byte}));
    }
    writeFd(1, "],\n})\n\nDecoded representative:\n");
    if (rendering.passed()) writeFd(1, try readFile(allocator, shown_path, max_json_len)) else writeFd(1, "unavailable: rendering failed or exceeded its deadline; original bytes are retained");
    writeFd(1, "\nOriginal witness: ");
    writeFd(1, path);
    writeFd(1, "\n");
    return if (rendering.passed()) 0 else 1;
}

/// Resolve existing parents too, so a new output below a symlink cannot hide
/// that it overlaps the input directory.
fn canonicalPath(allocator: Allocator, path: []const u8) ![]const u8 {
    const absolute = if (std.fs.path.isAbsolute(path)) try allocator.dupe(u8, path) else try std.fs.path.join(allocator, &.{ try std.process.currentPathAlloc(io(), allocator), path });
    return std.Io.Dir.cwd().realPathFileAlloc(io(), absolute, allocator) catch |err| switch (err) {
        error.FileNotFound => {
            const parent = std.fs.path.dirname(absolute) orelse return err;
            return std.fs.path.resolve(allocator, &.{ try canonicalPath(allocator, parent), std.fs.path.basename(absolute) });
        },
        else => return err,
    };
}

fn sameFile(allocator: Allocator, input: []const u8, output: []const u8) !bool {
    if (std.mem.eql(u8, try canonicalPath(allocator, input), try canonicalPath(allocator, output))) return true;
    const input_z = try allocator.dupeZ(u8, input);
    const output_z = try allocator.dupeZ(u8, output);
    if (builtin.os.tag == .linux) {
        const linux = std.os.linux;
        var first = std.mem.zeroes(linux.Statx);
        var second = std.mem.zeroes(linux.Statx);
        while (true) switch (linux.errno(linux.statx(linux.AT.FDCWD, input_z.ptr, 0, .{ .INO = true }, &first))) {
            .SUCCESS => break,
            .INTR => continue,
            else => return error.CannotInspectInput,
        };
        while (true) switch (linux.errno(linux.statx(linux.AT.FDCWD, output_z.ptr, 0, .{ .INO = true }, &second))) {
            .SUCCESS => break,
            .INTR => continue,
            .NOENT => return false,
            else => return error.CannotInspectOutput,
        };
        if (!first.mask.INO or !second.mask.INO) return error.FileIdentityUnavailable;
        return first.dev_major == second.dev_major and first.dev_minor == second.dev_minor and first.ino == second.ino;
    } else {
        var first: std.c.Stat = undefined;
        var second: std.c.Stat = undefined;
        if (std.c.fstatat(std.c.AT.FDCWD, input_z.ptr, &first, 0) != 0) return error.CannotInspectInput;
        if (std.c.fstatat(std.c.AT.FDCWD, output_z.ptr, &second, 0) != 0) {
            return switch (std.posix.errno(@as(c_int, -1))) {
                .NOENT => false,
                else => error.CannotInspectOutput,
            };
        }
        return first.dev == second.dev and first.ino == second.ino;
    }
}

fn requireEmptyDirectory(path: []const u8) !void {
    var directory = std.Io.Dir.cwd().openDir(io(), path, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    defer directory.close(io());
    var iterator = directory.iterate();
    if (try iterator.next(io()) != null) return error.OutputDirectoryNotEmpty;
}

fn printLog(path: []const u8, allocator: Allocator) !void {
    const path_z = try allocator.dupeZ(u8, path);
    const file = std.c.fopen(path_z.ptr, "rb") orelse return error.CannotReadLog;
    defer _ = std.c.fclose(file);
    var buffer: [64 * 1024]u8 = undefined;
    while (true) {
        const count = std.c.fread(&buffer, 1, buffer.len, file);
        if (count == 0) break;
        writeFd(2, buffer[0..count]);
    }
    if (ferror(file) != 0) return error.CannotReadLog;
}

fn findingCommand(allocator: Allocator, executable: []const u8, options: Options) !u8 {
    if (options.arguments.len != 2) return error.ExpectedInputAndOutput;
    if (options.baseline != null or !commandIs(options.profile, "default") or options.detailed or options.no_detect_leaks) return error.UnsupportedFindingOption;
    const input = options.arguments[0];
    const output = options.arguments[1];
    const minimizing = commandIs(options.command, "minimize");
    const input_path = try canonicalPath(allocator, input);
    const output_path = try canonicalPath(allocator, output);
    if (minimizing) {
        if (try sameFile(allocator, input, output)) return error.InputAndOutputAreSameFile;
    } else {
        if (try pathsOverlap(allocator, input_path, output_path)) return error.InputAndOutputDirectoriesOverlap;
        var directory = try std.Io.Dir.cwd().openDir(io(), input_path, .{});
        directory.close(io());
        try requireEmptyDirectory(output_path);
    }
    const original = if (minimizing) try readFile(allocator, input, max_input_len) else &.{};
    const report_dir = try createReportDirectory(allocator, options.report_dir);
    const report_path = try canonicalPath(allocator, report_dir);
    if (try pathsOverlap(allocator, report_path, input_path) or try pathsOverlap(allocator, report_path, output_path)) return error.FindingPathsOverlapReportDirectory;
    const log_path = try std.fs.path.join(allocator, &.{ report_dir, "run.log" });
    const seconds = options.time_seconds orelse 60;
    if (seconds == 0) return error.FindingBudgetMustBePositive;
    const deadline = try std.math.add(u64, try std.math.mul(u64, seconds, 1000), try std.math.add(u64, options.timeout_ms, 5000));
    var arguments: std.ArrayList([]const u8) = .empty;
    try arguments.appendSlice(allocator, &.{ executable, "raw" });
    try arguments.append(allocator, try std.fmt.allocPrint(allocator, "-timeout={d}", .{options.timeout_ms / 1000}));
    // libFuzzer's crash minimizer otherwise silently substitutes 600 seconds,
    // including when a run bound is provided. Always supply the campaign bound.
    try arguments.append(allocator, try std.fmt.allocPrint(allocator, "-max_total_time={d}", .{seconds}));
    for (options.exploration_options) |argument| {
        if (valueAfter(argument, "--runs=")) |value| {
            try arguments.append(allocator, try std.fmt.allocPrint(allocator, "-runs={s}", .{value}));
        } else if (!std.mem.startsWith(u8, argument, "--time=") and !std.mem.startsWith(u8, argument, "--timeout=")) return error.UnsupportedFindingOption;
    }
    if (!minimizing) {
        try std.Io.Dir.createDirPath(.cwd(), io(), output_path);
        try arguments.appendSlice(allocator, &.{ "-merge=1", output_path, input_path });
        const result = try runChild(allocator, arguments.items, log_path, deadline);
        try printLog(log_path, allocator);
        return if (result.passed()) 0 else 1;
    }
    if (std.fs.path.dirname(output_path)) |parent| try std.Io.Dir.createDirPath(.cwd(), io(), parent);
    const staging = try std.fmt.allocPrintSentinel(allocator, "{s}.minimize-XXXXXX", .{output_path}, 0);
    if (mkdtemp(staging.ptr) == null) return error.CannotCreateMinimizationDirectory;
    defer std.Io.Dir.cwd().deleteTree(io(), staging) catch {};
    const staged_input = try std.fs.path.join(allocator, &.{ staging, "input.bin" });
    const staged_output = try std.fs.path.join(allocator, &.{ staging, "output.bin" });
    try writeFile(allocator, staged_input, original);
    try arguments.appendSlice(allocator, &.{ "-minimize_crash=1", try std.fmt.allocPrint(allocator, "-exact_artifact_path={s}", .{staged_output}), staged_input });
    const result = try runChild(allocator, arguments.items, log_path, deadline);
    try printLog(log_path, allocator);
    if (!result.passed()) return 1;
    const reduced = readFile(allocator, staged_output, max_input_len) catch |err| switch (err) {
        error.FileNotFound => original,
        else => return err,
    };
    // libFuzzer may succeed without writing a smaller witness. The command's
    // output contract still holds, with the exact original storage witness.
    try atomicWrite(allocator, output, if (reduced.len < original.len) reduced else original);
    return 0;
}

/// Returns false for help, advanced libFuzzer modes, and the exploration worker.
/// Handled commands terminate the process after the durable report is complete.
pub fn dispatch(argc: usize, argv: [*][*:0]u8, target_name: []const u8, adapter: Adapter) bool {
    const command = if (argc > 1) std.mem.span(argv[1]) else "run";
    if (commandIs(command, "__quality-explore")) {
        if (argc < 3) fail("invalid exploration protocol");
        attachHealth(std.mem.span(argv[2])) catch |err| failError(err);
        return false;
    }
    if (commandIs(command, "raw") or commandIs(command, "--help") or commandIs(command, "-h") or commandIs(command, "help") or (std.mem.startsWith(u8, command, "-") and !std.mem.startsWith(u8, command, "--"))) return false;
    var arena = std.heap.ArenaAllocator.init(std.heap.c_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    if (commandIs(command, "__quality-worker")) worker(allocator, argc, argv, adapter);
    if (commandIs(command, "__quality-prepare")) prepareWorker(allocator, argc, argv, adapter);
    const executable = std.process.executablePathAlloc(io(), allocator) catch |err| failError(err);
    if (commandIs(command, "retain")) std.c._exit(retain(allocator, argc, argv, executable) catch |err| failError(err));
    if (commandIs(command, "examples")) {
        if (argc != 2) fail("examples takes no arguments");
        const report_dir = createReportDirectory(allocator, null) catch |err| failError(err);
        const log_path = std.fs.path.join(allocator, &.{ report_dir, "run.log" }) catch |err| failError(err);
        const prepared = prepareSupervised(allocator, executable, report_dir, log_path, 10_000) catch |err| {
            const report = Report{ .target = target_name, .host_target = hostTarget(), .profile = "default", .command = "examples", .outcome = "infrastructure_error", .baseline_path = baselinePath(allocator, target_name, null) catch "", .error_message = @errorName(err) };
            saveReport(allocator, report, report_dir) catch {};
            failError(err);
        };
        if (commandIs(prepared.evidence.status, "failed")) {
            const report = Report{ .target = target_name, .host_target = hostTarget(), .profile = "default", .command = "examples", .outcome = "infrastructure_error", .baseline_path = baselinePath(allocator, target_name, null) catch "", .error_message = prepared.evidence.error_message, .preparation = prepared.evidence };
            saveReport(allocator, report, report_dir) catch {};
            std.c._exit(2);
        }
        const examples = prepared.examples;
        for (examples) |example| {
            writeFd(1, example.name);
            writeFd(1, "\trevision ");
            writeFd(1, example.revision);
            writeFd(1, "\tSHA-256 ");
            writeFd(1, hash(allocator, example.bytes) catch |err| failError(err));
            writeFd(1, "\n");
        }
        std.c._exit(0);
    }
    const options = parseOptions(allocator, argc, argv) catch |err| failError(err);
    if (commandIs(command, "minimize") or commandIs(command, "reduce-corpus")) std.c._exit(findingCommand(allocator, executable, options) catch |err| failError(err));
    if (commandIs(options.command, "run") or commandIs(options.command, "check") or commandIs(options.command, "accept") or commandIs(options.command, "explore")) std.c._exit(checkAndExplore(allocator, executable, target_name, options, adapter) catch |err| failError(err));
    if (commandIs(options.command, "replay") or commandIs(options.command, "measure") or commandIs(options.command, "show")) std.c._exit(runInputCommand(allocator, executable, target_name, options, adapter) catch |err| failError(err));
    return false;
}

test "baseline filenames use declared target and explicit override" {
    const allocator = std.testing.allocator;
    const default = try baselinePath(allocator, "my_target", null);
    defer allocator.free(default);
    try std.testing.expectEqualStrings("my_target_baseline.json", default);
    const explicit = try baselinePath(allocator, "ignored", "profiles/accepted.json");
    defer allocator.free(explicit);
    try std.testing.expectEqualStrings("profiles/accepted.json", explicit);
    try std.testing.expectError(error.InvalidTargetNameForBaseline, baselinePath(allocator, "../target", null));
}

test "exact ratchets reject both cost directions and complete inventory drift" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const original = try std.json.parseFromSlice(std.json.Value, allocator, "[{\"complete\":true,\"stats\":{\"allocs\":2,\"peak_live_bytes\":32}}]", .{});
    const increase = try std.json.parseFromSlice(std.json.Value, allocator, "[{\"complete\":true,\"stats\":{\"allocs\":3,\"peak_live_bytes\":32}}]", .{});
    const reduction = try std.json.parseFromSlice(std.json.Value, allocator, "[{\"complete\":true,\"stats\":{\"allocs\":1,\"peak_live_bytes\":32}}]", .{});
    const reordered = try std.json.parseFromSlice(std.json.Value, allocator, "[{\"stats\":{\"peak_live_bytes\":32,\"allocs\":2},\"complete\":true}]", .{});
    const example = BaselineExample{ .name = "empty", .revision = "1", .input_sha256 = "abc", .observations = original.value };
    const entry = BaselineEntry{ .host_target = "arm64mac", .profile = "default", .metric_version = metric_version, .examples = &.{example} };
    try std.testing.expect(entryEqual(entry, entry));
    var changed_examples = [_]BaselineExample{example};
    const changed_example = &changed_examples[0];
    changed_example.observations = increase.value;
    var changed = entry;
    changed.examples = &changed_examples;
    try std.testing.expect(!entryEqual(entry, changed));
    changed_example.observations = reduction.value;
    try std.testing.expect(!entryEqual(entry, changed));
    changed_example.observations = reordered.value;
    try std.testing.expect(entryEqual(entry, changed));
    changed_example.revision = "2";
    try std.testing.expect(!entryEqual(entry, changed));
    changed_example.* = example;
    changed_example.input_sha256 = "different";
    try std.testing.expect(!entryEqual(entry, changed));
    changed = entry;
    changed.metric_version = "other";
    try std.testing.expect(!entryEqual(entry, changed));
    changed = entry;
    changed.examples = &.{};
    try std.testing.expect(!entryEqual(entry, changed));
}

test "accept replaces only the relevant host and profile" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const a = BaselineEntry{ .host_target = "arm64mac", .profile = "default", .metric_version = metric_version, .examples = &.{} };
    const b = BaselineEntry{ .host_target = "x64musl", .profile = "default", .metric_version = metric_version, .examples = &.{} };
    const c = BaselineEntry{ .host_target = "arm64mac", .profile = "optimised", .metric_version = metric_version, .examples = &.{} };
    const prior = Baseline{ .format = baseline_format, .target = "test", .entries = &.{ a, b, c } };
    const replacement = BaselineEntry{ .host_target = "arm64mac", .profile = "default", .metric_version = "new", .examples = &.{} };
    const result = try replaceEntry(allocator, prior, "test", replacement);
    try std.testing.expectEqual(@as(usize, 3), result.entries.len);
    try std.testing.expectEqualStrings("new", result.entries[0].metric_version);
    try std.testing.expect(entryEqual(b, result.entries[1]));
    try std.testing.expect(entryEqual(c, result.entries[2]));
}

test "duplicate declared examples fail before execution" {
    const a = Example{ .name = "same", .revision = "1", .bytes = &.{} };
    try std.testing.expectError(error.DuplicateExampleName, validateExamples(&.{ a, a }));
}

test "atomic rename failure leaves an existing destination intact" {
    const allocator = std.testing.allocator;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const root = try temporary.dir.realPathFileAlloc(std.testing.io, ".", allocator);
    defer allocator.free(root);
    const destination = try std.fs.path.join(allocator, &.{ root, "accepted" });
    defer allocator.free(destination);
    try std.Io.Dir.createDirPath(.cwd(), io(), destination);
    const marker = try std.fs.path.join(allocator, &.{ destination, "prior" });
    defer allocator.free(marker);
    try writeFile(allocator, marker, "original accepted bytes");
    if (atomicWrite(allocator, destination, "replacement bytes")) |_| {
        return error.ExpectedRenameFailure;
    } else |_| {}
    const preserved = try readFile(allocator, marker, 1024);
    defer allocator.free(preserved);
    try std.testing.expectEqualStrings("original accepted bytes", preserved);
    var directory = try std.Io.Dir.cwd().openDir(io(), root, .{ .iterate = true });
    defer directory.close(io());
    var iterator = directory.iterate();
    while (try iterator.next(io())) |entry| try std.testing.expect(std.mem.indexOf(u8, entry.name, ".tmp-") == null);
}

test "missing transport versions and incomplete statistics never pass acceptance" {
    const allocator = std.testing.allocator;
    try std.testing.expectError(error.MissingField, std.json.parseFromSlice(Baseline, allocator, "{\"target\":\"test\",\"entries\":[]}", .{}));
    try std.testing.expectError(error.MissingField, std.json.parseFromSlice(WorkerWire, allocator, "{\"accepted\":true,\"metric_valid\":true,\"trace_rules_passed\":true,\"capture_complete\":true,\"observations\":[]}", .{}));
    const incomplete = try std.json.parseFromSlice(std.json.Value, allocator, "[{\"complete\":true}]", .{});
    defer incomplete.deinit();
    const wire = WorkerWire{ .format = worker_format, .metric_version = metric_version, .accepted = true, .metric_valid = true, .trace_rules_passed = true, .capture_complete = true, .observations = incomplete.value };
    try std.testing.expect(!wireValid(wire));
}

test "campaign grace respects an explicitly increased invocation deadline" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var arguments = [_][*:0]u8{ @constCast("TARGET".ptr), @constCast("run".ptr), @constCast("--timeout=30".ptr) };
    const options = try parseOptions(arena.allocator(), arguments.len, &arguments);
    try std.testing.expectEqual(@as(u64, 30_000), options.timeout_ms);
    try std.testing.expectEqual(@as(?u64, 95_000), options.campaign_deadline_ms);
}

test "the goal summary names each goal once and reads well at any size" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    try std.testing.expectEqualStrings("", try goalSummary(allocator, .{ .status = "none_declared" }));
    const witness = GoalWitness{ .source = "example", .example = "empty", .input_path = "r/example-0.bin", .input_sha256 = "", .input_length = 0 };
    const one = try goalSummary(allocator, .{ .status = "reached", .required = true, .declared = 1, .reached = 1, .inventory = &.{.{ .name = "parsed", .reached = true, .inputs = 2, .first = witness }} });
    try std.testing.expectEqualStrings("\n## Goals\n\nReached 1 of 1 declared goal.\n\n| Reached goal | Kept inputs | First reached by | Witness |\n| --- | ---: | --- | --- |\n| parsed | 2 | example empty | `r/example-0.bin` |\n", one);
    for ([_]usize{ 11, 73 }) |count| {
        var inventory: std.ArrayList(GoalReport) = .empty;
        var unreached: std.ArrayList([]const u8) = .empty;
        for (0..count) |index| {
            const name = try std.fmt.allocPrint(allocator, "goal <{d}>", .{index});
            // Every third goal is reached, by exploration from the corpus or the search.
            if (index % 3 == 0) {
                try inventory.append(allocator, .{ .name = name, .reached = true, .inputs = index + 1, .first = .{ .source = if (index % 2 == 0) "corpus" else "exploration", .attempt = index + 1, .input_path = null, .input_sha256 = "", .input_length = 1 } });
            } else {
                try inventory.append(allocator, .{ .name = name });
                try unreached.append(allocator, name);
            }
        }
        const reached = count - unreached.items.len;
        const text = try goalSummary(allocator, .{ .status = "unreached", .required = true, .declared = count, .reached = reached, .unreached = unreached.items, .inventory = inventory.items });
        try std.testing.expect(std.mem.indexOf(u8, text, try std.fmt.allocPrint(allocator, "Reached {d} of {d} declared goals. A campaign", .{ reached, count })) != null);
        try std.testing.expect(std.mem.indexOf(u8, text, try std.fmt.allocPrint(allocator, "Never reached ({d}):\n\n- goal <1>\n", .{unreached.items.len})) != null);
        try std.testing.expect(std.mem.indexOf(u8, text, "| goal <0> | 1 | corpus input 1 | not saved |\n") != null);
        try std.testing.expect(std.mem.indexOf(u8, text, "| goal <3> | 4 | exploration input 4 | not saved |\n") != null);
        for (0..count) |index| {
            const needle = try std.fmt.allocPrint(allocator, "goal <{d}>", .{index});
            var occurrences: usize = 0;
            var at: usize = 0;
            // Count whole names only: "goal <1>" must not match "goal <10>".
            while (std.mem.indexOfPos(u8, text, at, needle)) |found| : (at = found + needle.len) occurrences += 1;
            try std.testing.expectEqual(@as(usize, 1), occurrences);
        }
        // One table row per reached goal, after a two-line header.
        try std.testing.expectEqual(reached + 2, std.mem.count(u8, text, "\n|"));
    }
    const none = try goalSummary(allocator, .{ .status = "unreached", .required = false, .declared = 2, .reached = 0, .unreached = &.{ "a|b", "c" }, .inventory = &.{ .{ .name = "a|b" }, .{ .name = "c" } } });
    try std.testing.expectEqualStrings("\n## Goals\n\nReached 0 of 2 declared goals. Unreached goals do not change this outcome.\n\nNever reached (2):\n\n- a\\|b\n- c\n", none);
}
