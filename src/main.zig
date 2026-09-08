//! Native adapter for the self-contained roc-fuzz executable.

const std = @import("std");
const abi = @import("roc_platform_abi.zig");
const ci_report = @import("ci_report.zig");

comptime {
    // Replace the RSS-ratcheting malloc from zig's bundled libc; see c_malloc.zig.
    _ = @import("c_malloc.zig");
}

const max_input_len = 1024 * 1024;
const max_args = 256;

var roc_host: abi.RocHost = undefined;
var host_initialized = false;
var translated_argv: [max_args][*:0]u8 = undefined;
var exact_artifact_arg: [2048]u8 = undefined;
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

fn hostAlloc(_: *abi.RocHost, length: usize, alignment: usize) callconv(.c) ?*anyopaque {
    return roc_alloc(length, alignment);
}

fn hostDealloc(_: *abi.RocHost, ptr: *anyopaque, alignment: usize) callconv(.c) void {
    roc_dealloc(ptr, alignment);
}

fn hostRealloc(_: *abi.RocHost, ptr: *anyopaque, length: usize, alignment: usize) callconv(.c) ?*anyopaque {
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
var g_alloc_count: u64 = 0;
var g_live_alloc_count: u64 = 0;

fn deallocImpl(ptr: *anyopaque, alignment: usize) void {
    const header_len = @max(alignment, @alignOf(usize));
    std.c.free(@ptrFromInt(@intFromPtr(ptr) - header_len));
}

pub export fn roc_alloc(length: usize, alignment: usize) callconv(.c) ?*anyopaque {
    const ptr = allocImpl(length, alignment);
    if (ptr != null) {
        g_alloc_count += 1;
        g_live_alloc_count += 1;
    }
    return ptr;
}

pub export fn roc_dealloc(ptr: *anyopaque, alignment: usize) callconv(.c) void {
    if (g_live_alloc_count > 0) g_live_alloc_count -= 1;
    deallocImpl(ptr, alignment);
}

pub export fn roc_realloc(ptr: *anyopaque, new_length: usize, alignment: usize) callconv(.c) ?*anyopaque {
    const header_len = @max(alignment, @alignOf(usize));
    const old_size_ptr: *const usize = @ptrFromInt(@intFromPtr(ptr) - @sizeOf(usize));
    const old_length = old_size_ptr.* - header_len;
    const new_ptr = allocImpl(new_length, alignment) orelse return null;
    g_alloc_count += 1;
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

comptime {
    @export(&hostedAllocCount, .{ .name = "roc_fuzz_alloc_count", .visibility = .hidden });
    @export(&hostedLiveAllocCount, .{ .name = "roc_fuzz_live_alloc_count", .visibility = .hidden });
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

fn readFile(path: [*:0]const u8, buffer: []u8) ?[]u8 {
    const file = std.c.fopen(path, "rb") orelse return null;
    defer _ = std.c.fclose(file);
    const len = std.c.fread(buffer.ptr, 1, buffer.len, file);
    return buffer[0..len];
}

fn showCommand(path: [*:0]const u8) noreturn {
    var buffer: [max_input_len]u8 = undefined;
    const input = readFile(path, &buffer) orelse {
        writeErr("could not read input\n");
        std.c._exit(2);
    };
    const rendered = abi.roc_fuzz_show(makeInput(input));
    writeOut(rendered.asSlice());
    writeOut("\n");
    rendered.decref(&roc_host);
    std.c._exit(0);
}

fn printHelp() void {
    writeOut("roc-fuzz: self-contained typed fuzz runner for ");
    printName();
    writeOut(
        \\
        \\USAGE:
        \\  TARGET run [CORPUS] [OPTION...]       fuzz with libFuzzer
        \\  TARGET ci REPORT_DIR [CORPUS] [OPTION...] supervise a run and write CI evidence
        \\  TARGET show INPUT                    render the generated typed value
        \\  TARGET replay INPUT                  run one saved input
        \\  TARGET minimize INPUT OUTPUT         minimize a reproducing failure
        \\  TARGET reduce-corpus INPUT OUTPUT    merge useful inputs into OUTPUT
        \\  TARGET raw [LIBFUZZER_ARG...]         use the native libFuzzer CLI
        \\  TARGET --help                        show this help
        \\
        \\Friendly run options:
        \\  --time=SECONDS          total run time; defaults to 60 (0 is unbounded)
        \\  --runs=COUNT            stop after this many inputs
        \\  --max-input-size=BYTES  bound the raw bytes passed to the generator
        \\  --memory-limit=MB       bound process memory
        \\  --timeout=SECONDS       bound one target call
        \\  --dictionary=FILE       load useful input tokens
        \\  --seed=NUMBER           make a bounded run reproducible
        \\  --artifact-dir=DIR      save failures under DIR
        \\  --no-detect-leaks       allow an input to leave allocations unfreed
        \\  --print-final-stats     print libFuzzer's final counters
        \\
        \\CI provenance options:
        \\  --source-revision=VALUE identify the downstream source revision
        \\  --roc-version=VALUE     identify the Roc compiler
        \\  --platform-release=VALUE identify the roc-fuzz release
        \\  --platform-sha256=HEX   identify the release bundle digest
        \\
        \\Use TARGET raw -help=1 for native libFuzzer flags.
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

fn ciCommand(original_count: usize, original: [*][*:0]u8) noreturn {
    const name = abi.roc_fuzz_name();
    var name_buffer: [1024]u8 = undefined;
    const bytes = name.asSlice();
    if (bytes.len > name_buffer.len) {
        name.decref(&roc_host);
        writeErr("target name is too long for CI reporting\n");
        std.c._exit(2);
    }
    @memcpy(name_buffer[0..bytes.len], bytes);
    name.decref(&roc_host);
    ci_report.run(original_count, original, name_buffer[0..bytes.len]);
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
    if (std.mem.eql(u8, command, "show")) {
        if (original_count != 3) {
            writeErr("show requires exactly one input file\n");
            std.c._exit(2);
        }
        showCommand(original[2]);
    }
    if (std.mem.eql(u8, command, "ci")) ciCommand(original_count, original);

    var count: usize = 0;
    pushArg(&count, original[0]);

    if (std.mem.eql(u8, command, "run")) {
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

    if (std.mem.eql(u8, command, "replay")) {
        if (original_count != 3) {
            writeErr("replay requires exactly one input file\n");
            std.c._exit(2);
        }
        pushArg(&count, mutableLiteral("-runs=1"));
        pushCommonFuzzArgs(&count, ".roc-fuzz");
        pushArg(&count, original[2]);
        setTranslatedArgs(argc, argv_ptr, count);
        return;
    }

    if (std.mem.eql(u8, command, "minimize")) {
        if (original_count != 4) {
            writeErr("minimize requires INPUT and OUTPUT files\n");
            std.c._exit(2);
        }
        const exact = std.fmt.bufPrintZ(&exact_artifact_arg, "-exact_artifact_path={s}", .{std.mem.span(original[3])}) catch {
            writeErr("output path is too long\n");
            std.c._exit(2);
        };
        pushArg(&count, mutableLiteral("-minimize_crash=1"));
        pushArg(&count, exact.ptr);
        pushCommonFuzzArgs(&count, ".roc-fuzz");
        pushArg(&count, original[2]);
        setTranslatedArgs(argc, argv_ptr, count);
        return;
    }

    if (std.mem.eql(u8, command, "reduce-corpus")) {
        if (original_count != 4) {
            writeErr("reduce-corpus requires INPUT and OUTPUT directories\n");
            std.c._exit(2);
        }
        _ = std.c.mkdir(original[3], 0o755);
        pushArg(&count, mutableLiteral("-merge=1"));
        pushArg(&count, mutableLiteral("-create_missing_dirs=1"));
        pushArg(&count, original[3]);
        pushArg(&count, original[2]);
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
    const live_before = g_live_alloc_count;
    _ = abi.roc_fuzz_run(makeInput(input));
    if (leak_detection_enabled and g_live_alloc_count > live_before) {
        reportLeak(g_live_alloc_count - live_before);
    }
    current_input_ptr = null;
    current_input_len = 0;
    return 0;
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
