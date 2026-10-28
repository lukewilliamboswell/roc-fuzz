//! Native adapter for the self-contained roc-fuzz executable.

const std = @import("std");
const abi = @import("roc_platform_abi.zig");
const observation = @import("observation.zig");
const quality = @import("quality_runner.zig");

var local_engine: observation.Engine = .{};
var engine: *observation.Engine = &local_engine;

comptime {
    // Replace the RSS-ratcheting malloc from zig's bundled libc; see c_malloc.zig.
    _ = @import("c_malloc.zig");
}

const max_input_len = 1024 * 1024;
const max_args = 256;

var roc_host: abi.RocHost = undefined;
var host_initialized = false;
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
}

fn allocImpl(length: usize, alignment: usize) ?*anyopaque {
    const actual_alignment = @max(alignment, @alignOf(usize));
    const header_len = actual_alignment;
    const total = std.math.add(usize, length, header_len) catch return null;
    var base: ?*anyopaque = null;
    if (std.c.posix_memalign(&base, actual_alignment, total) != 0) return null;
    const base_bytes: [*]u8 = @ptrCast(base.?);
    const size_ptr: *usize = @ptrFromInt(@intFromPtr(base_bytes) + header_len - @sizeOf(usize));
    size_ptr.* = total;
    return @ptrFromInt(@intFromPtr(base_bytes) + header_len);
}

/// Allocation counters served to the running Roc target. `Fuzz.alloc_count!`
/// and `Fuzz.live_alloc_count!` read these, so a target can assert how many
/// allocations a region performed and whether that region left anything
/// outstanding.
///
/// `g_alloc_count` counts every `roc_alloc` and `roc_realloc` served, matching
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

fn checkedAdd(value: *u64, amount: u64) void {
    value.* = std.math.add(u64, value.*, amount) catch {
        engine.metric_valid = false;
        observationFailure(error.Overflow);
    };
}

fn observationFailure(err: anyerror) noreturn {
    writeErr("[roc-fuzz invalid observation] ");
    writeErr(@errorName(err));
    writeErr("\n");
    finishRocFailure();
}

fn allocationLength(ptr: *anyopaque, alignment: usize) usize {
    const header_len = @max(alignment, @alignOf(usize));
    const size: *const usize = @ptrFromInt(@intFromPtr(ptr) - @sizeOf(usize));
    return size.* - header_len;
}

fn deallocImpl(ptr: *anyopaque, alignment: usize) void {
    const header_len = @max(alignment, @alignOf(usize));
    std.c.free(@ptrFromInt(@intFromPtr(ptr) - header_len));
}

pub export fn roc_alloc(length: usize, alignment: usize) callconv(.c) *anyopaque {
    const ptr = allocImpl(length, alignment) orelse outOfMemory();
    {
        checkedAdd(&g_alloc_count, 1);
        checkedAdd(&g_live_alloc_count, 1);
        checkedAdd(&g_requested_bytes, length);
        engine.alloc(length) catch |err| observationFailure(err);
    }
    return ptr;
}

pub export fn roc_dealloc(ptr: *anyopaque, alignment: usize) callconv(.c) void {
    const old_length = allocationLength(ptr, alignment);
    engine.dealloc(old_length) catch |err| observationFailure(err);
    if (g_live_alloc_count == 0) observationFailure(error.InvalidAllocation);
    g_live_alloc_count -= 1;
    checkedAdd(&g_dealloc_count, 1);
    deallocImpl(ptr, alignment);
}

pub export fn roc_realloc(ptr: *anyopaque, new_length: usize, alignment: usize) callconv(.c) *anyopaque {
    const header_len = @max(alignment, @alignOf(usize));
    const old_size_ptr: *const usize = @ptrFromInt(@intFromPtr(ptr) - @sizeOf(usize));
    const old_length = old_size_ptr.* - header_len;
    const new_ptr = allocImpl(new_length, alignment) orelse outOfMemory();
    checkedAdd(&g_alloc_count, 1);
    checkedAdd(&g_realloc_count, 1);
    checkedAdd(&g_requested_bytes, new_length);
    engine.realloc(old_length, new_length) catch |err| observationFailure(err);
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
    if (bytes.len > copy.len) observationFailure(error.NameTooLong);
    const len = bytes.len;
    @memcpy(copy[0..len], bytes);
    label.decref(&roc_host);
    return engine.start(copy[0..len]) catch |err| observationFailure(err);
}

fn hostedScopeFinish(id: u64) callconv(.c) abi.FuzzScope_finish {
    const stats = engine.finish(id) catch |err| observationFailure(err);
    var result: abi.FuzzScope_finish = undefined;
    inline for (@typeInfo(observation.Stats).@"struct".fields) |field| {
        @field(result, field.name) = @field(stats, field.name);
    }
    return result;
}

fn hostedMark(label: abi.RocStr) callconv(.c) void {
    defer label.decref(&roc_host);
    engine.mark(label.asSlice()) catch |err| observationFailure(err);
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
    const name = abi.roc_fuzz_name();
    writeOut(name.asSlice());
    name.decref(&roc_host);
}

fn prepareExamples(allocator: std.mem.Allocator) ![]const quality.Example {
    const count = abi.roc_fuzz_example_count();
    if (count > 4096) return error.TooManyExamples;
    const examples = try allocator.alloc(quality.Example, @intCast(count));
    for (examples, 0..) |*example, index| {
        const prepared = abi.roc_fuzz_example(@intCast(index));
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

fn showInput(allocator: std.mem.Allocator, input: []const u8) ![]const u8 {
    const shown = abi.roc_fuzz_show(makeInput(input));
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
    current_input_ptr = if (input.len > 0) input.ptr else null;
    current_input_len = input.len;
    quality.healthAttempt(input);
    engine.reset(engine.live_allocs, engine.live_bytes);
    quality.healthObservationReady();
    const live_before = g_live_alloc_count;
    const bytes_before = engine.live_bytes;
    const status = abi.roc_fuzz_run(makeInput(input));
    if (quality.workerLeakDetection() and (g_live_alloc_count > live_before or engine.live_bytes > bytes_before)) {
        reportLeak(g_live_alloc_count -| live_before);
    }
    quality.healthFinish(status == 0);
    return .{
        .accepted = status == 0,
        .metric_valid = engine.complete() and (status != 0 or engine.region_count > 0),
        .trace_rules_passed = engine.trace_rules_passed,
        .capture_complete = engine.capture_complete,
        .observations_json = try engine.observationsJson(allocator),
        .diagnostics_json = if (capture == .detailed) try engine.traceJson(allocator) else null,
    };
}

fn dispatchQuality(argc: *c_int, argv: *[*][*:0]u8) void {
    const name = abi.roc_fuzz_name();
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
        \\  --baseline=PATH     override <target-name>_baseline.json in the working directory
        \\  --profile=NAME      select the named allocation profile (default: default)
        \\  --report-dir=DIR    write one report and original-run evidence to an empty directory
        \\  --time=SECONDS      campaign budget (default: 60; 0: unbounded)
        \\  --runs=COUNT        bound exploration by executions
        \\  --timeout=SECONDS   invocation deadline (default: 10)
        \\  --max-input-size=BYTES  input size bound
        \\  --memory-limit=MB   process memory limit
        \\  --dictionary=FILE   mutation tokens
        \\  --seed=NUMBER       exploration seed
        \\  --no-detect-leaks   disable the invocation leak check
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
    const translated = std.fmt.bufPrintZ(buffer, "{s}{s}", .{ native_prefix, value }) catch {
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
    const artifact_prefix = std.fmt.bufPrintZ(&artifact_prefix_arg, "-artifact_prefix={s}{s}", .{ directory, separator }) catch {
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

pub export fn LLVMFuzzerInitialize(argc: *c_int, argv: *[*][*:0]u8) callconv(.c) c_int {
    if (argc.* > 0) executable_name = std.mem.span(argv.*[0]);
    initHost();
    dispatchQuality(argc, argv);
    translateFriendlyArgs(argc, argv);
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
    quality.healthObservationReady();
    const live_before = g_live_alloc_count;
    const bytes_before = engine.live_bytes;
    const status = abi.roc_fuzz_run(makeInput(input));
    if (leak_detection_enabled and (g_live_alloc_count > live_before or engine.live_bytes > bytes_before)) {
        reportLeak(g_live_alloc_count -| live_before);
    }
    quality.healthFinish(status == 0);
    if (!engine.complete() or !engine.trace_rules_passed or (status == 0 and engine.region_count == 0)) {
        writeErr("[roc-fuzz observation failure] invalid metrics, unfinished region or trace rule violation\n");
        finishRocFailure();
    }
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
