//! Build quality_runner_fixture first, then run this executable with its path.
//! Exercises the public CLI through real execs, crash signals and hard deadlines.
const std = @import("std");
const Allocator = std.mem.Allocator;

const Suite = struct {
    allocator: Allocator,
    io: std.Io,
    fixture: []const u8,
    root: []const u8,
    environ: *const std.process.Environ.Map,

    fn path(self: Suite, relative: []const u8) ![]const u8 {
        return std.fs.path.join(self.allocator, &.{ self.root, relative });
    }

    fn read(self: Suite, relative: []const u8) ![]const u8 {
        return std.Io.Dir.cwd().readFileAlloc(self.io, try self.path(relative), self.allocator, .limited(32 * 1024 * 1024));
    }

    fn run(self: Suite, label: []const u8, arguments: []const []const u8, mode: []const u8, expected_exit: u8) !std.json.Value {
        var environ = try self.environ.clone(self.allocator);
        try environ.put("ROCFUZZ_FIXTURE_CASE", mode);
        try environ.put("ROCFUZZ_FIXTURE_COUNT", try self.path("calls.txt"));
        var argv: std.ArrayList([]const u8) = .empty;
        try argv.append(self.allocator, self.fixture);
        try argv.appendSlice(self.allocator, arguments);
        try argv.append(self.allocator, try std.fmt.allocPrint(self.allocator, "--report-dir={s}", .{try self.path(label)}));
        const result = try std.process.run(self.allocator, self.io, .{ .argv = argv.items, .cwd = .{ .path = self.root }, .environ_map = &environ, .timeout = .{ .duration = .{ .raw = .fromSeconds(30), .clock = .awake } } });
        if (result.term != .exited or result.term.exited != expected_exit) {
            std.debug.print("{s}: unexpected termination {any}; stdout={s}; stderr={s}\n", .{ label, result.term, result.stdout, result.stderr });
            return error.UnexpectedExitStatus;
        }
        const report_path = try std.fmt.allocPrint(self.allocator, "{s}/report.json", .{label});
        const report = try std.json.parseFromSlice(std.json.Value, self.allocator, try self.read(report_path), .{});
        return report.value;
    }

    fn expectBaselineUnchanged(self: Suite, prior: []const u8) !void {
        try std.testing.expectEqualStrings(prior, try self.read("fixture_target_baseline.json"));
    }
};

fn field(value: std.json.Value, key: []const u8) !std.json.Value {
    return value.object.get(key) orelse error.MissingReportField;
}

fn expectString(value: std.json.Value, key: []const u8, expected: []const u8) !void {
    const actual = try field(value, key);
    try std.testing.expectEqualStrings(expected, actual.string);
}

fn assertFreshCalls(bytes: []const u8, count: usize) !void {
    var lines = std.mem.tokenizeScalar(u8, bytes, '\n');
    var pids: [128][]const u8 = undefined;
    var index: usize = 0;
    while (lines.next()) |line| {
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse return error.InvalidInvocationRecord;
        const pid = line[0..colon];
        for (pids[0..index]) |other| try std.testing.expect(!std.mem.eql(u8, pid, other));
        pids[index] = pid;
        index += 1;
    }
    try std.testing.expectEqual(count, index);
}

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    const args = try init.minimal.args.toSlice(allocator);
    if (args.len != 2) return error.ExpectedFixtureExecutablePath;
    const fixture = try std.Io.Dir.cwd().realPathFileAlloc(init.io, args[1], allocator);
    const cwd = try std.process.currentPathAlloc(init.io, allocator);
    const root = try std.fmt.allocPrint(allocator, "{s}/.zig-cache/quality-runner-{d}", .{ cwd, std.c.getpid() });
    try std.Io.Dir.createDirPath(.cwd(), init.io, root);
    defer std.Io.Dir.cwd().deleteTree(init.io, root) catch {};
    const suite = Suite{ .allocator = allocator, .io = init.io, .fixture = fixture, .root = root, .environ = init.environ_map };

    const unbaselined = try suite.run("unbaselined", &.{"check"}, "", 0);
    try expectString(unbaselined, "baseline_status", "unbaselined");
    try assertFreshCalls(try suite.read("calls.txt"), 2);
    const accepted = try suite.run("accepted", &.{"accept"}, "", 0);
    try expectString(accepted, "baseline_status", "accepted");
    try assertFreshCalls(try suite.read("calls.txt"), 4);
    const baseline = try suite.read("fixture_target_baseline.json");
    const matched = try suite.run("matched", &.{"check"}, "", 0);
    try expectString(matched, "baseline_status", "matched");
    try assertFreshCalls(try suite.read("calls.txt"), 6);
    const write_failure = try suite.run("report-write-failure", &.{"accept"}, "report-write-failure", 2);
    try expectString(write_failure, "baseline_status", "write_failed");
    try suite.expectBaselineUnchanged(baseline);

    for ([_][]const u8{ "increase", "reduction", "revision", "input" }) |mode| {
        const label = try std.fmt.allocPrint(allocator, "drift-{s}", .{mode});
        const drift = try suite.run(label, &.{ "run", "--runs=5" }, mode, 1);
        try expectString(drift, "baseline_status", "changed");
        const exploration = try field(drift, "exploration");
        try expectString(exploration, "status", "skipped");
        try expectString(exploration, "skipped_reason", "baseline_changed");
        try suite.expectBaselineUnchanged(baseline);
    }

    for ([_][]const u8{ "reject", "invalid", "trace", "unfinished", "crash", "timeout" }) |mode| {
        const label = try std.fmt.allocPrint(allocator, "failed-accept-{s}", .{mode});
        const rejected = try suite.run(label, &.{ "accept", "--timeout=1" }, mode, 1);
        try expectString(rejected, "baseline_status", "not_checked");
        const examples = try field(rejected, "examples");
        try std.testing.expectEqual(@as(usize, 2), examples.array.items.len);
        if (std.mem.eql(u8, mode, "timeout") or std.mem.eql(u8, mode, "crash")) {
            const original = try suite.read(try std.fmt.allocPrint(allocator, "{s}/example-0-original-trace.json", .{label}));
            try std.testing.expectEqualStrings("{\"original\":17}", original);
        }
        try suite.expectBaselineUnchanged(baseline);
    }

    // Diagnostic truncation is independent of metric and trace-rule validity.
    const truncated = try suite.run("truncated", &.{"check"}, "truncated", 0);
    try expectString(truncated, "baseline_status", "matched");
    const truncated_examples = try field(truncated, "examples");
    try std.testing.expect(!(try field(truncated_examples.array.items[0], "capture_complete")).bool);

    // An explicit path must not affect the default file or other profiles.
    const profile = try suite.run("profile", &.{ "accept", "--profile=optimised" }, "", 0);
    try expectString(profile, "baseline_status", "accepted");
    const multiple = try std.json.parseFromSlice(std.json.Value, allocator, try suite.read("fixture_target_baseline.json"), .{});
    try std.testing.expectEqual(@as(usize, 2), (try field(multiple.value, "entries")).array.items.len);
    const default_again = try suite.run("default-again", &.{"check"}, "", 0);
    try expectString(default_again, "baseline_status", "matched");
    const explicit = try suite.run("explicit", &.{ "accept", "--baseline=explicit.json" }, "", 0);
    try expectString(explicit, "baseline_path", "explicit.json");
    _ = try suite.read("explicit.json");

    // A full valid run checks both examples and starts one exploration worker.
    const run = try suite.run("run", &.{ "run", "--runs=5" }, "", 0);
    try expectString(run, "baseline_status", "matched");
    const campaign = try field(run, "exploration");
    try expectString(campaign, "status", "passed");
    try std.testing.expectEqual(@as(i64, 1), (try field(campaign, "accepted")).integer);
    try std.testing.expectEqualStrings("one", try suite.read(".roc-fuzz/corpus/7692c3ad3540bb803c020b3aee66cd8887123234ea0c6e7143c0add73ff431ed"));
    try std.testing.expectEqualStrings("two", try suite.read(".roc-fuzz/corpus/3fc4ccfe745870e2c0d99f71f30ff0656c8dedd41cc1d7d3d376b0dbe685e2f3"));
    const default_run = try suite.run("default-run", &.{"--runs=5"}, "", 0);
    try expectString(default_run, "command", "run");
    try expectString(default_run, "baseline_status", "matched");
    const rejection = try suite.run("all-rejected", &.{ "run", "--runs=5" }, "all-rejected", 1);
    try expectString(rejection, "outcome", "inconclusive");
    const rejected_campaign = try field(rejection, "exploration");
    try std.testing.expectEqual(@as(i64, 1), (try field(rejected_campaign, "attempted")).integer);
    try std.testing.expectEqual(@as(i64, 0), (try field(rejected_campaign, "accepted")).integer);
    try std.testing.expectEqual(@as(i64, 1), (try field(rejected_campaign, "rejected")).integer);
    const crashed = try suite.run("explore-crash", &.{ "explore", "--runs=5" }, "explore-crash", 1);
    try expectString(crashed, "outcome", "finding");
    try std.testing.expect((try field(try field(crashed, "exploration"), "original_trace_input_matches")).bool);
    try std.testing.expectEqualStrings("original entropy", try suite.read("explore-crash/original-input.bin"));
    try std.testing.expectEqualStrings("{\"original\":31}", try suite.read("explore-crash/original-trace.json"));
    try std.testing.expectEqualStrings("{\"mark\":\"original-run\"}", try suite.read("explore-crash/original-breadcrumbs.json"));
    const replay = try suite.run("replay", &.{ "replay", "run/example-0.bin", "--detailed" }, "", 0);
    try expectString(replay, "outcome", "passed");
    _ = try suite.read("replay/trace.json");
    _ = try suite.run("measure", &.{ "measure", "run/example-0.bin" }, "", 0);
    const retained = try std.process.run(allocator, init.io, .{
        .argv = &.{ fixture, "retain", "run/example-0.bin", "--name", "previous-crash", "--output", "witnesses" },
        .cwd = .{ .path = root },
    });
    try std.testing.expect(retained.term == .exited and retained.term.exited == 0);
    try std.testing.expect(std.mem.indexOf(u8, retained.stdout, "Fuzz.saved({") != null);
    try std.testing.expect(std.mem.indexOf(u8, retained.stdout, "representative(one)") != null);
    try std.testing.expectEqualStrings("one", try suite.read("witnesses/previous-crash.bin"));
    var render_crash_environment = try init.environ_map.clone(allocator);
    try render_crash_environment.put("ROCFUZZ_FIXTURE_CASE", "show-crash");
    const rendering_crash = try std.process.run(allocator, init.io, .{
        .argv = &.{ fixture, "retain", "run/example-0.bin", "--name", "render-crash", "--output", "witnesses" },
        .cwd = .{ .path = root },
        .environ_map = &render_crash_environment,
    });
    try std.testing.expect(rendering_crash.term == .exited and rendering_crash.term.exited == 1);
    try std.testing.expectEqualStrings("one", try suite.read("witnesses/render-crash.bin"));
    try std.testing.expect(std.mem.indexOf(u8, rendering_crash.stdout, "Fuzz.saved({") != null);
    const conflicting_witness = try std.process.run(allocator, init.io, .{
        .argv = &.{ fixture, "retain", "run/example-1.bin", "--name", "previous-crash", "--output", "witnesses" },
        .cwd = .{ .path = root },
    });
    try std.testing.expect(conflicting_witness.term == .exited and conflicting_witness.term.exited == 2);
    try std.testing.expectEqualStrings("one", try suite.read("witnesses/previous-crash.bin"));

    // The exact old file survives a failed atomic rename, even after every
    // declared example completed successfully.
    const bad_baseline = try suite.path("baseline-directory");
    try std.Io.Dir.createDirPath(.cwd(), init.io, bad_baseline);
    const invalid_baseline = try suite.run("invalid-baseline", &.{ "accept", try std.fmt.allocPrint(allocator, "--baseline={s}", .{bad_baseline}) }, "", 2);
    try expectString(invalid_baseline, "baseline_status", "invalid");
    const empty = try suite.run("empty-accept", &.{"accept"}, "empty", 2);
    try expectString(empty, "error_message", "CannotAcceptEmptyExampleInventory");
    std.debug.print("quality runner integration: all checks passed\n", .{});
}
