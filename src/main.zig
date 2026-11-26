//! Native adapter for the self-contained roc-fuzz executable.

const std = @import("std");
const abi = @import("roc_platform_abi.zig");
const observation = @import("observation.zig");
const quality = @import("quality_runner.zig");
const bookkeeping = @import("allocation_bookkeeping.zig");
const goals = @import("goals.zig");
var return_box: bookkeeping.ReturnBox = .{};

/// The selected target's goal inventory and the goals the current input has
/// reached. See `registerGoalCoverage` for how libFuzzer reads the counters.
var goal_tracker: goals.Tracker = .{};
var goals_loaded = false;
/// libFuzzer pairs every counter with a PC table entry of two words.
var goal_pcs: [goals.max_goals][2]usize = undefined;
extern "c" fn __sanitizer_cov_8bit_counters_init(start: [*]u8, stop: [*]u8) void;
extern "c" fn __sanitizer_cov_pcs_init(begin: [*]const usize, end: [*]const usize) void;

var local_engine: observation.Engine = .{};
var engine: *observation.Engine = &local_engine;

comptime {
    // Replace the RSS-ratcheting malloc from zig's bundled libc; see c_malloc.zig.
    _ = @import("c_malloc.zig");
    if (!std.mem.eql(u8, observation.metric_version, quality.metric_version)) {
        @compileError("observation and supervisor metric versions must agree");
    }
    // The supervisor validates the inventory the host declares, and a goal is
    // reached by an event, so the three limits must agree.
    if (goals.max_goals != quality.max_goals or goals.max_name_bytes != quality.max_goal_name_bytes or goals.max_name_bytes != observation.max_name_bytes) {
        @compileError("goal limits must agree with the supervisor and the event name limit");
    }
}

const max_input_len = quality.max_input_len;
const max_args = 256;

var roc_host: abi.RocHost = undefined;
var host_initialized = false;
/// The application's target, built once by `roc_fuzz_build` in `initHost`.
/// The host owns one reference for the life of the process and lends Roc one
/// more for each call; see `heldTarget`. Everything allocated while it is
/// built is bookkeeping, so no input and no observation sees it.
var held_target: ?*abi.Target = null;
var building_target = false;
var selected_target: u64 = 0;
var selected_name: [1025]u8 = undefined;
var target_argument: [1040]u8 = undefined;
extern "c" fn getenv(name: [*:0]const u8) ?[*:0]u8;
extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
var translated_argv: [max_args][*:0]u8 = undefined;
var runs_arg: [128]u8 = undefined;
var time_arg: [128]u8 = undefined;
var max_input_size_arg: [128]u8 = undefined;
var memory_limit_arg: [128]u8 = undefined;
var timeout_arg: [128]u8 = undefined;
var dictionary_arg: [2048]u8 = undefined;
var seed_arg: [128]u8 = undefined;
var artifact_prefix_arg: [4096]u8 = undefined;
var sanitizer_crash_state: u8 = 0;
var sanitizer_death_callback: ?*const fn () callconv(.c) void = null;
var executable_name: []const u8 = "TARGET";
var current_input_ptr: ?[*]const u8 = null;
var current_input_len: usize = 0;
var friendly_run_active = false;
var leak_detection_enabled = true;
var artifact_directory: []const u8 = ".roc-fuzz";
/// Standalone workers report a nonzero exit; libFuzzer workers save artifacts.
var standalone_worker = false;

/// The Roc ABI requires an allocation to succeed or not return. A request the
/// allocator cannot serve ends the run the way a crash does, so the input that
/// asked for it is saved.
fn outOfMemory() noreturn {
    writeErr("[roc crashed] out of memory\n");
    finishRocFailure();
}

fn hostAlloc(_: *abi.RocHost, length: usize, alignment: usize) callconv(.c) *anyopaque {
    return roc_alloc(length, alignment);
}

fn hostDealloc(_: *abi.RocHost, ptr: *anyopaque, alignment: usize) callconv(.c) void {
    roc_dealloc(ptr, alignment);
}

fn hostRealloc(_: *abi.RocHost, ptr: *anyopaque, length: usize, alignment: usize) callconv(.c) *anyopaque {
    return roc_realloc(ptr, length, alignment);
}

fn hostDbg(_: *abi.RocHost, bytes: [*]const u8, len: usize) callconv(.c) void {
    roc_dbg(bytes, len);
}

fn hostExpectFailed(_: *abi.RocHost, bytes: [*]const u8, len: usize) callconv(.c) void {
    roc_expect_failed(bytes, len);
}

fn hostCrashed(_: *abi.RocHost, bytes: [*]const u8, len: usize) callconv(.c) void {
    roc_crashed(bytes, len);
}

fn initHost() void {
    if (host_initialized) return;
    roc_host = .{
        .env = @ptrFromInt(1),
        .roc_alloc = &hostAlloc,
        .roc_dealloc = &hostDealloc,
        .roc_realloc = &hostRealloc,
        .roc_dbg = &hostDbg,
        .roc_expect_failed = &hostExpectFailed,
        .roc_crashed = &hostCrashed,
    };
    host_initialized = true;
    // Before any input or measured region, so the live balance each input
    // samples already includes the target. A crash here ends the process
    // before the first command runs.
    building_target = true;
    held_target = abi.roc_fuzz_build();
    building_target = false;
}

/// The held target for one call into Roc. A provided function consumes the
/// box it is passed, so each call gets a reference of its own and the host's
/// stays: the box is never unique in Roc, is never freed, and nothing it holds
/// is mutated in place.
fn heldTarget() *abi.Target {
    const built = held_target.?;
    abi.increfBox(built, 1);
    return built;
}

fn allocImpl(length: usize, alignment: usize, internal: bool) ?*anyopaque {
    const metadata = bookkeeping.pack(length, internal) catch |err| invalidMetric(err);
    const actual_alignment = @max(alignment, @alignOf(usize));
    const header_len = actual_alignment;
    const total = std.math.add(usize, length, header_len) catch return null;
    var base: ?*anyopaque = null;
    if (std.c.posix_memalign(&base, actual_alignment, total) != 0) return null;
    const base_bytes: [*]u8 = @ptrCast(base.?);
    const size_ptr: *usize = @ptrFromInt(@intFromPtr(base_bytes) + header_len - @sizeOf(usize));
    size_ptr.* = metadata;
    return @ptrFromInt(@intFromPtr(base_bytes) + header_len);
}

/// Allocation counters served to the running Roc target. `Fuzz.alloc_count!`
/// and `Fuzz.live_alloc_count!` read these, so a target can assert how many
/// allocations a region performed and whether that region left anything
/// outstanding.
///
/// Private measurement ownership containers and the held target are excluded
/// from these counters.
/// `g_alloc_count` counts application `roc_alloc` and `roc_realloc` calls, matching
/// the roc test platform's `Host.alloc_count!`. `g_live_alloc_count` is the
/// number of allocations still outstanding: a realloc replaces one block with
/// another and so leaves the balance unchanged, which is why the reallocation
/// path frees through the uncounted `deallocImpl` rather than `roc_dealloc`.
///
/// `g_realloc_count` and `g_dealloc_count` count `roc_realloc` and
/// `roc_dealloc` calls alone, so `g_alloc_count - g_realloc_count` is the
/// number of `roc_alloc` calls. `g_requested_bytes` adds each allocation's
/// length and each reallocation's full new length, failing on overflow. Only
/// served requests are counted: one that fails ends the run.
var g_alloc_count: u64 = 0;
var g_live_alloc_count: u64 = 0;
var g_realloc_count: u64 = 0;
var g_dealloc_count: u64 = 0;
var g_requested_bytes: u64 = 0;
// Include private ownership containers and the held target in the
// invocation-wide leak check; each input samples it before and after.
var physical_live_allocs: u64 = 0;
var physical_live_bytes: u64 = 0;

fn checkedAdd(value: *u64, amount: u64) void {
    value.* = std.math.add(u64, value.*, amount) catch {
        engine.metric_valid = false;
        observationFailure(error.Overflow);
    };
}

fn invalidMetric(err: anyerror) noreturn {
    engine.metric_valid = false;
    observationFailure(err);
}

fn observationFailure(err: anyerror) noreturn {
    writeErr("[roc-fuzz invalid observation] ");
    writeErr(@errorName(err));
    writeErr("\n");
    finishRocFailure();
}

fn allocationMetadata(ptr: *anyopaque) usize {
    const size: *const usize = @ptrFromInt(@intFromPtr(ptr) - @sizeOf(usize));
    return size.*;
}

fn deallocImpl(ptr: *anyopaque, alignment: usize) void {
    const header_len = @max(alignment, @alignOf(usize));
    std.c.free(@ptrFromInt(@intFromPtr(ptr) - header_len));
}

pub export fn roc_alloc(length: usize, alignment: usize) callconv(.c) *anyopaque {
    const ptr = allocImpl(length, alignment, false) orelse outOfMemory();
    const internal = building_target or (return_box.claim(@intFromPtr(ptr), length) catch |err| invalidMetric(err));
    if (internal) {
        const metadata: *usize = @ptrFromInt(@intFromPtr(ptr) - @sizeOf(usize));
        metadata.* = bookkeeping.pack(length, true) catch |err| invalidMetric(err);
    }
    checkedAdd(&physical_live_allocs, 1);
    checkedAdd(&physical_live_bytes, length);
    if (!internal) {
        checkedAdd(&g_alloc_count, 1);
        checkedAdd(&g_live_alloc_count, 1);
        checkedAdd(&g_requested_bytes, length);
        engine.alloc(length) catch |err| observationFailure(err);
    }
    return ptr;
}

pub export fn roc_dealloc(ptr: *anyopaque, alignment: usize) callconv(.c) void {
    const metadata = allocationMetadata(ptr);
    const old_length = bookkeeping.length(metadata);
    if (physical_live_allocs == 0 or physical_live_bytes < old_length) invalidMetric(error.InvalidAllocation);
    physical_live_allocs -= 1;
    physical_live_bytes -= old_length;
    if (!bookkeeping.isBookkeeping(metadata)) {
        engine.dealloc(old_length) catch |err| observationFailure(err);
        if (g_live_alloc_count == 0) invalidMetric(error.InvalidAllocation);
        g_live_alloc_count -= 1;
        checkedAdd(&g_dealloc_count, 1);
    }
    deallocImpl(ptr, alignment);
}

pub export fn roc_realloc(ptr: *anyopaque, new_length: usize, alignment: usize) callconv(.c) *anyopaque {
    const metadata = allocationMetadata(ptr);
    const old_length = bookkeeping.length(metadata);
    const internal = bookkeeping.isBookkeeping(metadata);
    const new_ptr = allocImpl(new_length, alignment, internal) orelse outOfMemory();
    if (physical_live_allocs == 0 or physical_live_bytes < old_length) invalidMetric(error.InvalidAllocation);
    physical_live_bytes -= old_length;
    checkedAdd(&physical_live_bytes, new_length);
    if (!internal) {
        checkedAdd(&g_alloc_count, 1);
        checkedAdd(&g_realloc_count, 1);
        checkedAdd(&g_requested_bytes, new_length);
        engine.realloc(old_length, new_length) catch |err| observationFailure(err);
    }
    const copy_len = @min(old_length, new_length);
    @memcpy(@as([*]u8, @ptrCast(new_ptr))[0..copy_len], @as([*]const u8, @ptrCast(ptr))[0..copy_len]);
    deallocImpl(ptr, alignment);
    return new_ptr;
}

/// Fuzz.alloc_count! (hosted): () => U64 involves no refcounted values, so
/// under the hosted C ABI it takes no parameters.
fn hostedAllocCount() callconv(.c) u64 {
    return g_alloc_count;
}

/// Fuzz.live_alloc_count! (hosted): () => U64.
fn hostedLiveAllocCount() callconv(.c) u64 {
    return g_live_alloc_count;
}

/// Fuzz.realloc_count! (hosted): () => U64.
fn hostedReallocCount() callconv(.c) u64 {
    return g_realloc_count;
}

/// Fuzz.dealloc_count! (hosted): () => U64.
fn hostedDeallocCount() callconv(.c) u64 {
    return g_dealloc_count;
}

/// Fuzz.requested_bytes! (hosted): () => U64.
fn hostedRequestedBytes() callconv(.c) u64 {
    return g_requested_bytes;
}

fn hostedScopeStart(label: abi.RocStr) callconv(.c) u64 {
    var copy: [observation.max_name_bytes]u8 = undefined;
    const bytes = label.asSlice();
    if (bytes.len > copy.len) invalidMetric(error.NameTooLong);
    const len = bytes.len;
    @memcpy(copy[0..len], bytes);
    label.decref(&roc_host);
    return engine.start(copy[0..len]) catch |err| observationFailure(err);
}

fn hostedScopeFinish(id: u64) callconv(.c) abi.FuzzScope_finish {
    if (return_box.scope != null) invalidMetric(error.UnfinishedReturnBox);
    const stats = engine.finish(id) catch |err| observationFailure(err);
    // A completed child region is an event in its parent, as a mark is.
    if (goal_tracker.count != 0 and engine.depth != 0) goal_tracker.event(engine.regionName(id));
    var result: abi.FuzzScope_finish = undefined;
    inline for (@typeInfo(observation.Stats).@"struct".field_names) |name| {
        @field(result, name) = @field(stats, name);
    }
    return result;
}

fn hostedPrepareReturnBox() callconv(.c) void {
    if (engine.depth == 0) invalidMetric(error.NoActiveScope);
    const id = engine.regions[engine.stack[engine.depth - 1]].id;
    return_box.prepare(id) catch |err| invalidMetric(err);
}

fn hostedScopeFinishReturn(id: u64, value: abi.RocBox) callconv(.c) abi.FuzzScope_finish_return {
    return_box.finish(id, @intFromPtr(value)) catch |err| invalidMetric(err);
    // Transfer the opaque owned box back to Roc unchanged. Its payload remains
    // alive through finish even when the caller projects only the statistics.
    return .{ .value = value, .stats = hostedScopeFinish(id) };
}

fn hostedMark(label: abi.RocStr) callconv(.c) void {
    defer label.decref(&roc_host);
    engine.mark(label.asSlice()) catch |err| observationFailure(err);
    goal_tracker.event(label.asSlice());
}

fn hostedBefore(first: abi.RocStr, second: abi.RocStr) callconv(.c) void {
    defer first.decref(&roc_host);
    defer second.decref(&roc_host);
    engine.before(first.asSlice(), second.asSlice()) catch |err| observationFailure(err);
}

fn hostedCount(label: abi.RocStr, expected: u64) callconv(.c) void {
    defer label.decref(&roc_host);
    engine.count(label.asSlice(), expected) catch |err| observationFailure(err);
}

fn hostedForbidden(label: abi.RocStr) callconv(.c) void {
    defer label.decref(&roc_host);
    engine.forbidden(label.asSlice()) catch |err| observationFailure(err);
}

comptime {
    @export(&hostedScopeStart, .{ .name = "roc_fuzz_scope_start", .visibility = .hidden });
    @export(&hostedScopeFinish, .{ .name = "roc_fuzz_scope_finish", .visibility = .hidden });
    @export(&hostedPrepareReturnBox, .{ .name = "roc_fuzz_prepare_return_box", .visibility = .hidden });
    @export(&hostedScopeFinishReturn, .{ .name = "roc_fuzz_scope_finish_return", .visibility = .hidden });
    @export(&hostedMark, .{ .name = "roc_fuzz_mark", .visibility = .hidden });
    @export(&hostedBefore, .{ .name = "roc_fuzz_before", .visibility = .hidden });
    @export(&hostedCount, .{ .name = "roc_fuzz_count", .visibility = .hidden });
    @export(&hostedForbidden, .{ .name = "roc_fuzz_forbidden", .visibility = .hidden });
}

comptime {
    @export(&hostedAllocCount, .{ .name = "roc_fuzz_alloc_count", .visibility = .hidden });
    @export(&hostedLiveAllocCount, .{ .name = "roc_fuzz_live_alloc_count", .visibility = .hidden });
    @export(&hostedReallocCount, .{ .name = "roc_fuzz_realloc_count", .visibility = .hidden });
    @export(&hostedDeallocCount, .{ .name = "roc_fuzz_dealloc_count", .visibility = .hidden });
    @export(&hostedRequestedBytes, .{ .name = "roc_fuzz_requested_bytes", .visibility = .hidden });
}

pub export fn roc_dbg(bytes: [*]const u8, len: usize) callconv(.c) void {
    writeErr("[roc dbg] ");
    writeErr(bytes[0..len]);
    writeErr("\n");
}

pub export fn roc_expect_failed(bytes: [*]const u8, len: usize) callconv(.c) void {
    writeErr("[roc expect failed] ");
    writeErr(bytes[0..len]);
    writeErr("\n");
    finishRocFailure();
}

pub export fn roc_crashed(bytes: [*]const u8, len: usize) callconv(.c) void {
    writeErr("[roc crashed] ");
    writeErr(bytes[0..len]);
    writeErr("\n");
    finishRocFailure();
}

fn writeFd(fd: std.c.fd_t, bytes: []const u8) void {
    var rest = bytes;
    while (rest.len > 0) {
        const written = std.c.write(fd, rest.ptr, rest.len);
        if (written <= 0) return;
        rest = rest[@intCast(written)..];
    }
}

fn writeOut(bytes: []const u8) void {
    writeFd(1, bytes);
}

fn writeErr(bytes: []const u8) void {
    writeFd(2, bytes);
}

fn printFailureSuggestions() void {
    const input: []const u8 = if (current_input_len == 0) &.{} else current_input_ptr.?[0..current_input_len];
    var digest: [20]u8 = undefined;
    std.crypto.hash.Sha1.hash(input, &digest, .{});
    const digest_hex = std.fmt.bytesToHex(digest, .lower);
    var artifact_buffer: [4096]u8 = undefined;
    const artifact = std.fmt.bufPrint(&artifact_buffer, "{s}/crash-{s}", .{ artifact_directory, &digest_hex }) catch return;

    writeErr("\nNext steps:\n  ");
    writeErr(executable_name);
    writeErr(" show ");
    writeErr(artifact);
    writeErr("\n  ");
    writeErr(executable_name);
    writeErr(" replay ");
    writeErr(artifact);
    writeErr("\n  ");
    writeErr(executable_name);
    writeErr(" minimize ");
    writeErr(artifact);
    writeErr(" .roc-fuzz/minimized-crash\n\n");
}

fn finishRocFailure() noreturn {
    // A single-input worker runs outside libFuzzer. The supervisor owns its
    // original bytes and observation storage, including on a fatal exit.
    if (standalone_worker) std.c._exit(1);
    if (friendly_run_active) {
        if (sanitizer_death_callback) |callback| {
            // libFuzzer owns artifact formatting and persistence. Its death
            // callback writes the current unit before we print the friendly
            // follow-up commands.
            callback();
            printFailureSuggestions();
            std.c._exit(77);
        }
    }
    std.c.abort();
}

fn makeInput(bytes: []const u8) abi.RocListWith(u8, false) {
    return abi.RocListWith(u8, false).fromSlice(bytes, &roc_host);
}

fn printName() void {
    const name = abi.roc_fuzz_name(heldTarget(), selected_target);
    writeOut(name.asSlice());
    name.decref(&roc_host);
}

fn prepareExamples(allocator: std.mem.Allocator) ![]const quality.Example {
    const count = abi.roc_fuzz_example_count(heldTarget(), selected_target);
    if (count > 4096) return error.TooManyExamples;
    const examples = try allocator.alloc(quality.Example, @intCast(count));
    for (examples, 0..) |*example, index| {
        const prepared = abi.roc_fuzz_example(heldTarget(), selected_target, @intCast(index));
        defer prepared.decref(&roc_host);
        if (prepared.bytes.items().len > max_input_len) return error.ExampleTooLarge;
        example.* = .{
            .name = try allocator.dupe(u8, prepared.name.asSlice()),
            .revision = try allocator.dupe(u8, prepared.revision.asSlice()),
            .bytes = try allocator.dupe(u8, prepared.bytes.items()),
        };
    }
    return examples;
}

/// Copy the selected target's goal inventory out of Roc once per process.
fn loadGoals() void {
    if (goals_loaded) return;
    goals_loaded = true;
    const names = abi.roc_fuzz_goals(heldTarget(), selected_target);
    defer names.deinit(&roc_host);
    for (names.items()) |name| _ = goal_tracker.declare(name.asSlice()) catch |err| goalInventoryError(err, name.asSlice());
}

fn goalInventoryError(err: goals.Error, name: []const u8) noreturn {
    var buffer: [512]u8 = undefined;
    writeErr(goals.describe(&buffer, err, name));
    std.c._exit(2);
}

fn prepareGoals(allocator: std.mem.Allocator) ![]const []const u8 {
    loadGoals();
    const names = try allocator.alloc([]const u8, goal_tracker.count);
    for (names, 0..) |*name, index| name.* = try allocator.dupe(u8, goal_tracker.name(index));
    return names;
}

/// Make a goal's first reach new coverage, so libFuzzer keeps that input.
///
/// libFuzzer treats each registered counter region as one module of inline
/// 8-bit counters and requires a PC table of the same length beside it. It
/// clears every region before an input and reads it after, so a byte set while
/// an input runs is a feature of that input, and a feature seen for the first
/// time adds the input to the corpus. Both entry points are libFuzzer's public
/// sanitizer-coverage interface on every target, which is why this needs no
/// linker section and no change to libfuzzer.a. A target that declares no
/// goal registers nothing, and its coverage is exactly what it was.
fn registerGoalCoverage() void {
    const count = goal_tracker.count;
    if (count == 0) return;
    for (goal_pcs[0..count], 0..) |*entry, index| {
        // The table's first entry must be a function entry; the rest are
        // blocks of it. The addresses are never executed or dereferenced.
        entry.* = .{ @intFromPtr(&goal_tracker.counters[index]), @intFromBool(index == 0) };
    }
    const counters: [*]u8 = &goal_tracker.counters;
    const pcs: [*]const usize = @ptrCast(&goal_pcs);
    __sanitizer_cov_8bit_counters_init(counters, counters + count);
    __sanitizer_cov_pcs_init(pcs, pcs + 2 * count);
}

fn showInput(allocator: std.mem.Allocator, input: []const u8) ![]const u8 {
    const shown = abi.roc_fuzz_show(heldTarget(), selected_target, makeInput(input));
    defer shown.decref(&roc_host);
    return allocator.dupe(u8, shown.asSlice());
}

fn bindSharedEngine() void {
    if (quality.sharedObservation(observation.Engine)) |shared| {
        const live_allocs = engine.live_allocs;
        const live_bytes = engine.live_bytes;
        shared.* = .{};
        shared.reset(live_allocs, live_bytes);
        engine = shared;
    }
}

fn originalSnapshot(allocator: std.mem.Allocator, storage: []align(64) const u8) ![]const u8 {
    if (storage.len < @sizeOf(observation.Engine)) return error.InvalidObservationStorage;
    const original: *const observation.Engine = @ptrCast(@alignCast(storage.ptr));
    return original.traceJson(allocator);
}

fn runOne(allocator: std.mem.Allocator, input: []const u8, capture: quality.Capture) !quality.WorkerResult {
    bindSharedEngine();
    standalone_worker = true;
    loadGoals();
    current_input_ptr = if (input.len > 0) input.ptr else null;
    current_input_len = input.len;
    quality.healthAttempt(input);
    engine.reset(engine.live_allocs, engine.live_bytes);
    goal_tracker.begin();
    quality.healthObservationReady();
    const live_before = physical_live_allocs;
    const bytes_before = physical_live_bytes;
    const status = abi.roc_fuzz_run(heldTarget(), selected_target, makeInput(input));
    if (quality.workerLeakDetection() and (physical_live_allocs > live_before or physical_live_bytes > bytes_before)) {
        reportLeak(physical_live_allocs -| live_before);
    }
    quality.healthFinish(status == 0);
    // Only a kept input reaches a goal: a rejected one is outside the domain.
    const reached = try allocator.alloc([]const u8, if (status == 0) goal_tracker.reached().len else 0);
    for (reached, 0..) |*name, index| name.* = goal_tracker.name(goal_tracker.reached()[index]);
    return .{
        .accepted = status == 0,
        .metric_valid = engine.complete() and (status != 0 or engine.region_count > 0),
        .trace_rules_passed = engine.trace_rules_passed,
        .capture_complete = engine.capture_complete,
        .observations_json = try engine.observationsJson(allocator),
        .diagnostics_json = if (capture == .detailed) try engine.traceJson(allocator) else null,
        .goals_declared = goal_tracker.count,
        .goals_reached = reached,
    };
}

fn dispatchQuality(argc: *c_int, argv: *[*][*:0]u8) void {
    const name = abi.roc_fuzz_name(heldTarget(), selected_target);
    var buffer: [1024]u8 = undefined;
    const len = name.asSlice().len;
    if (len > buffer.len) {
        name.decref(&roc_host);
        writeErr("target name is too long\n");
        std.c._exit(2);
    }
    @memcpy(buffer[0..len], name.asSlice());
    name.decref(&roc_host);
    _ = quality.dispatch(@intCast(argc.*), argv.*, buffer[0..len], .{
        .prepare_examples = &prepareExamples,
        .prepare_goals = &prepareGoals,
        .show = &showInput,
        .run_one = &runOne,
        .original_snapshot = &originalSnapshot,
    });
    if (argc.* >= 3 and std.mem.eql(u8, std.mem.span(argv.*[1]), "__quality-explore")) {
        bindSharedEngine();
        argv.*[1] = mutableLiteral("explore");
        var i: usize = 2;
        const count: usize = @intCast(argc.*);
        while (i + 1 < count) : (i += 1) argv.*[i] = argv.*[i + 1];
        argc.* -= 1;
    }
}

fn printHelp() void {
    writeOut("roc-fuzz: pure quality checks for ");
    printName();
    writeOut(
        \\
        \\  TARGET [run] [CORPUS] [OPTION...]  check examples and baseline, then explore
        \\  TARGET check [OPTION...]           check each declared example once
        \\  TARGET accept [OPTION...]          explicitly accept exact allocation observations
        \\  TARGET explore [CORPUS] [OPTION...] explore with coverage feedback
        \\  TARGET examples                    list declared examples
        \\  TARGET show INPUT                  render a decoded representative
        \\  TARGET replay INPUT [--detailed]    reproduce with optional logical trace
        \\  TARGET measure INPUT               collect named allocation observations
        \\  TARGET retain INPUT --name NAME --output DIR  preserve original witness
        \\  TARGET minimize INPUT OUTPUT [OPTIONS] minimize within the campaign budget
        \\  TARGET reduce-corpus INPUT OUTPUT  retain a coverage corpus
        \\  TARGET raw [LIBFUZZER_ARG...]       advanced native controls
        \\
        \\  --target=NAME       select one property from a suite
        \\  --list-targets      list independently selectable properties
        \\  --baseline=PATH     override <target-name>_baseline.json in the working directory
        \\  --profile=NAME      select the named allocation profile (default: default)
        \\  --report-dir=DIR    write one report and original-run evidence to an empty directory
        \\  --time=SECONDS      campaign budget (default: 60; exploration 0: unbounded)
        \\  --runs=COUNT        bound exploration by executions
        \\  --timeout=SECONDS   invocation deadline (default: 10)
        \\  --max-input-size=BYTES  input size bound
        \\  --memory-limit=MB   process memory limit
        \\  --dictionary=FILE   mutation tokens
        \\  --seed=NUMBER       exploration seed
        \\  --no-detect-leaks   disable the invocation leak check
        \\  --allow-unreached-goals  report unreached goals without failing the run
        \\  --detailed          record bounded logical traces
        \\
    );
}

fn mutableLiteral(comptime value: [:0]const u8) [*:0]u8 {
    return @constCast(value.ptr);
}

fn setTranslatedArgs(argc: *c_int, argv: *[*][*:0]u8, count: usize) void {
    argc.* = @intCast(count);
    argv.* = translated_argv[0..count].ptr;
}

fn pushArg(count: *usize, value: [*:0]u8) void {
    if (count.* == max_args) {
        writeErr("too many command-line arguments\n");
        std.c._exit(2);
    }
    translated_argv[count.*] = value;
    count.* += 1;
}

fn pushTranslatedArg(count: *usize, buffer: []u8, native_prefix: []const u8, value: []const u8) void {
    const translated = std.mem.printSentinel(buffer, "{s}{s}", .{ native_prefix, value }, 0) catch {
        writeErr("command-line option is too long\n");
        std.c._exit(2);
    };
    pushArg(count, translated.ptr);
}

fn pushCommonFuzzArgs(count: *usize, directory: []const u8) void {
    std.Io.Threaded.global_single_threaded.allocator = std.heap.c_allocator;
    std.Io.Dir.createDirPath(.cwd(), std.Io.Threaded.global_single_threaded.io(), directory) catch {
        writeErr("could not create artifact directory\n");
        std.c._exit(2);
    };
    const separator = if (std.mem.endsWith(u8, directory, "/")) "" else "/";
    const artifact_prefix = std.mem.printSentinel(&artifact_prefix_arg, "-artifact_prefix={s}{s}", .{ directory, separator }, 0) catch {
        writeErr("artifact directory path is too long\n");
        std.c._exit(2);
    };
    pushArg(count, artifact_prefix.ptr);
    pushArg(count, mutableLiteral("-create_missing_dirs=1"));
}

fn translateFriendlyArgs(argc: *c_int, argv_ptr: *[*][*:0]u8) void {
    const original_count: usize = @intCast(argc.*);
    const original = argv_ptr.*;
    if (original_count < 2) {
        printHelp();
        std.c._exit(0);
    }

    const command = std.mem.span(original[1]);
    if (std.mem.eql(u8, command, "--help") or std.mem.eql(u8, command, "-h") or std.mem.eql(u8, command, "help")) {
        printHelp();
        std.c._exit(0);
    }

    var count: usize = 0;
    pushArg(&count, original[0]);

    if (std.mem.eql(u8, command, "explore")) {
        var next: usize = 2;
        var has_bound = false;
        var using_default_corpus = false;
        if (next < original_count and !std.mem.startsWith(u8, std.mem.span(original[next]), "-")) {
            pushArg(&count, original[next]);
            next += 1;
        } else {
            pushArg(&count, mutableLiteral(".roc-fuzz/corpus"));
            using_default_corpus = true;
        }
        while (next < original_count) : (next += 1) {
            const arg = std.mem.span(original[next]);
            if (std.mem.startsWith(u8, arg, "--runs=")) {
                has_bound = true;
                pushTranslatedArg(&count, &runs_arg, "-runs=", arg[7..]);
            } else if (std.mem.startsWith(u8, arg, "--time=")) {
                has_bound = true;
                pushTranslatedArg(&count, &time_arg, "-max_total_time=", arg[7..]);
            } else if (std.mem.startsWith(u8, arg, "--max-input-size=")) {
                pushTranslatedArg(&count, &max_input_size_arg, "-max_len=", arg[17..]);
            } else if (std.mem.startsWith(u8, arg, "--memory-limit=")) {
                pushTranslatedArg(&count, &memory_limit_arg, "-rss_limit_mb=", arg[15..]);
            } else if (std.mem.startsWith(u8, arg, "--timeout=")) {
                pushTranslatedArg(&count, &timeout_arg, "-timeout=", arg[10..]);
            } else if (std.mem.startsWith(u8, arg, "--dictionary=")) {
                pushTranslatedArg(&count, &dictionary_arg, "-dict=", arg[13..]);
            } else if (std.mem.startsWith(u8, arg, "--seed=")) {
                pushTranslatedArg(&count, &seed_arg, "-seed=", arg[7..]);
            } else if (std.mem.eql(u8, arg, "--no-detect-leaks")) {
                leak_detection_enabled = false;
            } else if (std.mem.startsWith(u8, arg, "--goal-dir=")) {
                quality.setGoalDirectory(arg[11..]);
            } else if (std.mem.startsWith(u8, arg, "--artifact-dir=")) {
                artifact_directory = arg[15..];
                if (artifact_directory.len == 0) {
                    writeErr("--artifact-dir must not be empty\n");
                    std.c._exit(2);
                }
            } else if (std.mem.eql(u8, arg, "--print-final-stats")) {
                pushArg(&count, mutableLiteral("-print_final_stats=1"));
            } else if (std.mem.eql(u8, arg, "--help")) {
                printHelp();
                std.c._exit(0);
            } else {
                writeErr("unknown run option: ");
                writeErr(arg);
                writeErr("\nUse TARGET --help for friendly options or TARGET raw for native libFuzzer flags.\n");
                std.c._exit(2);
            }
        }
        if (using_default_corpus) {
            _ = std.c.mkdir(".roc-fuzz", 0o755);
            _ = std.c.mkdir(".roc-fuzz/corpus", 0o755);
        }
        pushCommonFuzzArgs(&count, artifact_directory);
        if (!has_bound) pushArg(&count, mutableLiteral("-max_total_time=60"));
        friendly_run_active = true;
        setTranslatedArgs(argc, argv_ptr, count);
        return;
    }

    if (std.mem.eql(u8, command, "raw")) {
        var index: usize = 2;
        while (index < original_count) : (index += 1) pushArg(&count, original[index]);
        setTranslatedArgs(argc, argv_ptr, count);
        return;
    }

    // libFuzzer workers re-exec this binary with an already translated native
    // argument list. Passing unknown commands through also keeps that native
    // interface available for debugging and future libFuzzer flags.
}

fn selectionError(message: []const u8) noreturn {
    writeErr(message);
    writeErr("\nUse --list-targets to list available properties.\n");
    std.c._exit(2);
}

fn listTargets(count: u64) void {
    for (0..@intCast(count)) |index| {
        const name = abi.roc_fuzz_name(heldTarget(), @intCast(index));
        writeOut(name.asSlice());
        writeOut("\n");
        name.decref(&roc_host);
    }
}

// Selection happens before the quality supervisor or libFuzzer sees argv.
// The inherited name keeps the same property selected across supervisor,
// replay, minimization and raw libFuzzer exec workers.
fn selectTarget(argc: *c_int, argv: *[*][*:0]u8) void {
    const count = abi.roc_fuzz_target_count(heldTarget());
    if (count == 0 or count > 4096) selectionError("invalid fuzz target inventory");
    var requested: ?[]const u8 = null;
    var list = false;
    var input: usize = 1;
    var output: usize = 1;
    const original_count: usize = @intCast(argc.*);
    while (input < original_count) : (input += 1) {
        const argument = std.mem.span(argv.*[input]);
        if (std.mem.eql(u8, argument, "--list-targets")) {
            list = true;
        } else if (std.mem.eql(u8, argument, "--target") or std.mem.startsWith(u8, argument, "--target=")) {
            if (requested != null) selectionError("select exactly one --target");
            if (std.mem.eql(u8, argument, "--target")) {
                input += 1;
                if (input >= original_count) selectionError("--target needs a name");
                requested = std.mem.span(argv.*[input]);
            } else requested = argument[9..];
            if (requested.?.len == 0) selectionError("--target needs a name");
        } else {
            argv.*[output] = argv.*[input];
            output += 1;
        }
    }
    argc.* = @intCast(output);
    if (list) {
        listTargets(count);
        std.c._exit(0);
    }
    if (requested == null) {
        if (getenv("ROC_FUZZ_SELECTED_TARGET")) |inherited| requested = std.mem.span(inherited);
    }
    if (requested == null and count > 1) {
        if (output == 2 and (std.mem.eql(u8, std.mem.span(argv.*[1]), "--help") or std.mem.eql(u8, std.mem.span(argv.*[1]), "help") or std.mem.eql(u8, std.mem.span(argv.*[1]), "-h"))) {
            writeOut("Select a property with --target=NAME, then use its normal runner commands.\n");
            listTargets(count);
            std.c._exit(0);
        }
        selectionError("this executable has multiple properties; select --target=NAME");
    }
    selected_target = 0;
    if (requested) |wanted| {
        var found = false;
        for (0..@intCast(count)) |index| {
            const name = abi.roc_fuzz_name(heldTarget(), @intCast(index));
            defer name.decref(&roc_host);
            if (std.mem.eql(u8, wanted, name.asSlice())) {
                if (found) selectionError("ambiguous fuzz target name");
                selected_target = @intCast(index);
                found = true;
            }
        }
        if (!found) selectionError("unknown fuzz target name");
    }
    const name = abi.roc_fuzz_name(heldTarget(), selected_target);
    defer name.decref(&roc_host);
    if (name.asSlice().len > selected_name.len - 1) selectionError("fuzz target name is too long");
    @memcpy(selected_name[0..name.asSlice().len], name.asSlice());
    selected_name[name.asSlice().len] = 0;
    const argument = std.fmt.bufPrint(&target_argument, "--target={s}", .{name.asSlice()}) catch selectionError("fuzz target name is too long");
    quality.setTargetArgument(argument);
    if (setenv("ROC_FUZZ_SELECTED_TARGET", @ptrCast(&selected_name), 1) != 0) selectionError("cannot pass target selection to workers");
}

pub export fn LLVMFuzzerInitialize(argc: *c_int, argv: *[*][*:0]u8) callconv(.c) c_int {
    if (argc.* > 0) executable_name = std.mem.span(argv.*[0]);
    initHost();
    selectTarget(argc, argv);
    dispatchQuality(argc, argv);
    translateFriendlyArgs(argc, argv);
    // Only a process that libFuzzer will drive reaches this point.
    loadGoals();
    quality.healthGoalInventory(goal_tracker.count);
    registerGoalCoverage();
    return 0;
}

pub export fn LLVMFuzzerTestOneInput(data: ?[*]const u8, size: usize) callconv(.c) c_int {
    initHost();
    const input: []const u8 = if (size == 0) &.{} else data.?[0..size];
    current_input_ptr = data;
    current_input_len = size;
    // A completed iteration must free everything it allocated, including the
    // input list built below. Sampling the balance here rather than inside the
    // target keeps this honest for every target, pure ones included, without
    // any target having to opt in.
    quality.healthAttempt(input);
    engine.reset(engine.live_allocs, engine.live_bytes);
    goal_tracker.begin();
    quality.healthObservationReady();
    const live_before = physical_live_allocs;
    const bytes_before = physical_live_bytes;
    const status = abi.roc_fuzz_run(heldTarget(), selected_target, makeInput(input));
    if (leak_detection_enabled and (physical_live_allocs > live_before or physical_live_bytes > bytes_before)) {
        reportLeak(physical_live_allocs -| live_before);
    }
    quality.healthFinish(status == 0);
    if (!engine.complete() or !engine.trace_rules_passed or (status == 0 and engine.region_count == 0)) {
        writeErr("[roc-fuzz observation failure] invalid metrics, unfinished region or trace rule violation\n");
        finishRocFailure();
    }
    // Only a kept input reaches a goal. Its counters stay set until the next
    // input, which is when libFuzzer reads them.
    if (status == 0) quality.healthGoalsReached(goal_tracker.reached(), input) else goal_tracker.begin();
    current_input_ptr = null;
    current_input_len = 0;
    return if (status == 0) 0 else -1;
}

fn reportLeak(leaked: u64) void {
    var buffer: [128]u8 = undefined;
    const message = std.fmt.bufPrint(
        &buffer,
        "[roc-fuzz leak] {d} allocation(s) from this input were never freed\n",
        .{leaked},
    ) catch "[roc-fuzz leak] allocations from this input were never freed\n";
    writeErr(message);
    finishRocFailure();
}

// libFuzzer normally receives these hooks from a sanitizer runtime. Roc fuzz
// mode is coverage-only, so the standalone executable supplies the small
// coordination subset the driver needs for clean crash reporting.
pub export fn __sanitizer_acquire_crash_state() callconv(.c) c_int {
    return if (@cmpxchgStrong(u8, &sanitizer_crash_state, 0, 1, .seq_cst, .seq_cst) == null) 1 else 0;
}

pub export fn __sanitizer_print_stack_trace() callconv(.c) void {}

pub export fn __sanitizer_set_death_callback(callback: ?*const fn () callconv(.c) void) callconv(.c) void {
    sanitizer_death_callback = callback;
}
