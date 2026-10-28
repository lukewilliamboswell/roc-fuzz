//! Native supervisor fixture; no Roc compiler or libFuzzer dependency.
const std = @import("std");
const quality = @import("quality_runner");
const Allocator = std.mem.Allocator;

var call_count: usize = 0;
var worker_output_directory: ?[]const u8 = null;

fn env(name: [*:0]const u8) []const u8 {
    return if (std.c.getenv(name)) |value| std.mem.span(value) else "";
}

fn modeIs(expected: []const u8) bool {
    return std.mem.eql(u8, env("ROCFUZZ_FIXTURE_CASE"), expected);
}

fn examples(allocator: Allocator) ![]const quality.Example {
    if (modeIs("prepare-crash")) std.c.abort();
    if (modeIs("prepare-timeout")) {
        const delay = std.c.timespec{ .sec = 20, .nsec = 0 };
        _ = std.c.nanosleep(&delay, null);
    }
    const output = try allocator.alloc(quality.Example, if (modeIs("empty")) 0 else 2);
    if (output.len == 0) return output;
    output[0] = .{ .name = "first", .revision = if (modeIs("revision")) "2" else "1", .bytes = if (modeIs("input")) "changed" else "one" };
    output[1] = .{ .name = "second", .revision = "1", .bytes = "two" };
    return output;
}

fn runOne(allocator: Allocator, input: []const u8, capture: quality.Capture) !quality.WorkerResult {
    _ = capture;
    call_count += 1;
    if (call_count != 1) return error.WorkerReused;
    const count_path = env("ROCFUZZ_FIXTURE_COUNT");
    if (count_path.len != 0) {
        const path = try allocator.dupeZ(u8, count_path);
        const file = std.c.fopen(path.ptr, "ab") orelse return error.CannotOpenCountFile;
        defer _ = std.c.fclose(file);
        const line = try std.fmt.allocPrint(allocator, "{d}:{s}\n", .{ std.c.getpid(), input });
        if (std.c.fwrite(line.ptr, 1, line.len, file) != line.len) return error.CannotWriteCountFile;
    }
    quality.healthAttempt(input);
    const storage = quality.sharedObservation(u64) orelse return error.MissingSharedObservationStorage;
    storage.* = 17;
    quality.healthObservationReady();
    const first = std.mem.eql(u8, input, "one");
    if (modeIs("mixed-failures") or (first and (modeIs("assertion") or modeIs("roc-crash") or modeIs("leak") or modeIs("oom")))) {
        const message: []const u8 = if (modeIs("assertion") or (modeIs("mixed-failures") and !first)) "[roc expect failed] fixture assertion\n" else if (modeIs("roc-crash")) "[roc crashed] fixture panic\n" else if (modeIs("oom")) "[roc crashed] out of memory\n" else "[roc-fuzz leak] fixture leak\n";
        _ = std.c.write(2, message.ptr, message.len);
        std.c._exit(1);
    }
    if (modeIs("report-write-failure")) {
        const summary_path = try std.fs.path.join(allocator, &.{ worker_output_directory.?, "summary.md" });
        try std.Io.Dir.createDirPath(.cwd(), std.Io.Threaded.global_single_threaded.io(), summary_path);
    }
    if (modeIs("crash") and std.mem.eql(u8, input, "one")) std.c.abort();
    if (modeIs("timeout") and std.mem.eql(u8, input, "one")) {
        const delay = std.c.timespec{ .sec = 20, .nsec = 0 };
        _ = std.c.nanosleep(&delay, null);
    }
    const cost: usize = if (modeIs("increase")) 3 else if (modeIs("reduction")) 1 else 2;
    quality.healthFinish(!modeIs("reject"));
    return .{
        .accepted = !modeIs("reject"),
        .metric_valid = !modeIs("invalid"),
        .trace_rules_passed = !modeIs("trace"),
        .capture_complete = !modeIs("truncated"),
        .observations_json = try std.json.Stringify.valueAlloc(allocator, &.{.{
            .id = @as(u64, 1),
            .parent_id = @as(u64, 0),
            .name = "$property",
            .occurrence = @as(u64, 1),
            .complete = !modeIs("unfinished"),
            .stats = .{
                .allocs = cost,
                .reallocs = @as(u64, 0),
                .deallocs = cost,
                .requested_bytes = @as(u64, 16),
                .entry_live_allocs = @as(u64, 1),
                .entry_live_bytes = @as(u64, 8),
                .exit_live_allocs = @as(u64, 1),
                .exit_live_bytes = @as(u64, 8),
                .peak_live_bytes = @as(u64, 24),
            },
        }}, .{}),
    };
}

fn show(allocator: Allocator, input: []const u8) ![]const u8 {
    if (modeIs("show-crash")) std.c.abort();
    return std.fmt.allocPrint(allocator, "representative({s})", .{input});
}

fn snapshot(allocator: Allocator, storage: []align(64) const u8) ![]const u8 {
    const value: *const u64 = @ptrCast(storage.ptr);
    return std.fmt.allocPrint(allocator, "{{\"original\":{d}}}", .{value.*});
}

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    const args = try init.minimal.args.toSlice(allocator);
    if (args.len >= 4 and std.mem.eql(u8, args[1], "__quality-worker")) worker_output_directory = std.fs.path.dirname(args[3]);
    const argv = try allocator.alloc([*:0]u8, args.len);
    for (args, argv) |argument, *slot| slot.* = (try allocator.dupeZ(u8, argument)).ptr;
    const adapter = quality.Adapter{ .prepare_examples = examples, .run_one = runOne, .show = show, .original_snapshot = snapshot };
    if (quality.dispatch(argv.len, argv.ptr, "fixture_target", adapter)) return;
    if (args.len >= 2 and std.mem.eql(u8, args[1], "raw")) {
        const encoded = try std.json.Stringify.valueAlloc(allocator, args, .{});
        _ = std.c.write(2, encoded.ptr, encoded.len);
        _ = std.c.write(2, "\n", 1);
        for (args) |argument| {
            if (std.mem.startsWith(u8, argument, "-exact_artifact_path=")) {
                if (modeIs("minimize-smaller") or modeIs("raw-failure")) try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = argument[21..], .data = "m" });
            }
        }
        if (modeIs("reduce-copy")) {
            const path = try std.fs.path.join(allocator, &.{ args[args.len - 2], "retained" });
            try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = path, .data = "useful" });
        }
        if (modeIs("raw-failure")) std.c._exit(1);
        return;
    }
    if (args.len >= 2 and std.mem.eql(u8, args[1], "__quality-explore")) {
        const storage = quality.sharedObservation(u64).?;
        storage.* = 31;
        quality.healthAttempt("original entropy");
        quality.healthObservationReady();
        quality.healthFinish(!modeIs("all-rejected"));
        quality.breadcrumb("{\"mark\":\"original-run\"}");
        if (modeIs("explore-crash")) std.c.abort();
        return;
    }
    return error.UnhandledCommand;
}
