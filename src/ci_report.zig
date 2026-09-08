//! Supervised CI execution and durable evidence for a compiled roc-fuzz target.

const std = @import("std");

const Allocator = std.mem.Allocator;
const Io = std.Io;

const max_metadata_len = 4096;

extern "c" fn fflush(stream: *std.c.FILE) c_int;
extern "c" fn ferror(stream: *std.c.FILE) c_int;

const Provenance = struct {
    source_revision: ?[]const u8 = null,
    roc_version: ?[]const u8 = null,
    platform_release: ?[]const u8 = null,
    platform_sha256: ?[]const u8 = null,
};

const Configuration = struct {
    time: ?[]const u8 = null,
    runs: ?[]const u8 = null,
    max_input_size: ?[]const u8 = null,
    memory_limit: ?[]const u8 = null,
    timeout: ?[]const u8 = null,
    dictionary: ?[]const u8 = null,
    seed: ?[]const u8 = null,
    leak_detection: bool = true,
};

const Stats = struct {
    executed_units: ?u64 = null,
    average_exec_per_sec: ?u64 = null,
    new_units_added: ?u64 = null,
    slowest_unit_time_sec: ?u64 = null,
    peak_rss_mb: ?u64 = null,
    coverage_edges: ?u64 = null,
    coverage_features: ?u64 = null,
};

const ManifestEntry = struct {
    path: []u8,
    size: u64,
    sha256: [64]u8,
};

const Outcome = enum { passed, finding, infrastructure_error };

const FindingKind = enum {
    none,
    roc_expectation,
    roc_crash,
    roc_leak,
    native_crash,
    timeout,
    oom,
    slow_unit,
    unknown,
};

const Termination = struct {
    exit_code: ?u8 = null,
    signal: ?u32 = null,
};

fn io() Io {
    return std.Io.Threaded.global_single_threaded.io();
}

fn fail(message: []const u8) noreturn {
    writeFd(2, "roc-fuzz ci: ");
    writeFd(2, message);
    writeFd(2, "\n");
    std.c._exit(2);
}

fn writeFd(fd: std.c.fd_t, bytes: []const u8) void {
    var rest = bytes;
    while (rest.len > 0) {
        const written = std.c.write(fd, rest.ptr, rest.len);
        if (written <= 0) return;
        rest = rest[@intCast(written)..];
    }
}

fn fileWrite(file: *std.c.FILE, bytes: []const u8) bool {
    return std.c.fwrite(bytes.ptr, 1, bytes.len, file) == bytes.len;
}

fn filePrint(file: *std.c.FILE, comptime format: []const u8, args: anytype) bool {
    var buffer: [8192]u8 = undefined;
    const rendered = std.fmt.bufPrint(&buffer, format, args) catch return false;
    return fileWrite(file, rendered);
}

fn jsonString(file: *std.c.FILE, value: []const u8) bool {
    if (!fileWrite(file, "\"")) return false;
    for (value) |byte| {
        switch (byte) {
            '"' => if (!fileWrite(file, "\\\"")) return false,
            '\\' => if (!fileWrite(file, "\\\\")) return false,
            '\n' => if (!fileWrite(file, "\\n")) return false,
            '\r' => if (!fileWrite(file, "\\r")) return false,
            '\t' => if (!fileWrite(file, "\\t")) return false,
            0...8, 11...12, 14...0x1f => {
                const hex = "0123456789abcdef";
                const escaped = [_]u8{ '\\', 'u', '0', '0', hex[byte >> 4], hex[byte & 0xf] };
                if (!fileWrite(file, &escaped)) return false;
            },
            else => {
                const one = [_]u8{byte};
                if (!fileWrite(file, &one)) return false;
            },
        }
    }
    return fileWrite(file, "\"");
}

fn jsonOptionalString(file: *std.c.FILE, value: ?[]const u8) bool {
    return if (value) |present| jsonString(file, present) else fileWrite(file, "null");
}

fn jsonOptionalInt(file: *std.c.FILE, value: ?u64) bool {
    return if (value) |present| filePrint(file, "{d}", .{present}) else fileWrite(file, "null");
}

fn sha256File(path: []const u8) !struct { size: u64, digest: [64]u8 } {
    const allocator = std.heap.c_allocator;
    const path_z = try allocator.dupeZ(u8, path);
    defer allocator.free(path_z);
    const file = std.c.fopen(path_z.ptr, "rb") orelse return error.FileNotFound;
    defer _ = std.c.fclose(file);

    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    var size: u64 = 0;
    var buffer: [64 * 1024]u8 = undefined;
    while (true) {
        const read = std.c.fread(&buffer, 1, buffer.len, file);
        if (read == 0) break;
        hash.update(buffer[0..read]);
        size += read;
    }
    var digest_bytes: [32]u8 = undefined;
    hash.final(&digest_bytes);
    return .{ .size = size, .digest = std.fmt.bytesToHex(digest_bytes, .lower) };
}

fn manifestLessThan(_: void, left: ManifestEntry, right: ManifestEntry) bool {
    return std.mem.lessThan(u8, left.path, right.path);
}

fn collectManifest(allocator: Allocator, root: []const u8) !std.ArrayList(ManifestEntry) {
    var result: std.ArrayList(ManifestEntry) = .empty;
    errdefer {
        for (result.items) |entry| allocator.free(entry.path);
        result.deinit(allocator);
    }

    var directory = std.Io.Dir.cwd().openDir(io(), root, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return result,
        else => return err,
    };
    defer directory.close(io());
    var walker = try directory.walk(allocator);
    defer walker.deinit();
    while (try walker.next(io())) |entry| {
        if (entry.kind != .file) continue;
        const relative = try allocator.dupe(u8, entry.path);
        errdefer allocator.free(relative);
        const full_path = try std.fs.path.join(allocator, &.{ root, entry.path });
        defer allocator.free(full_path);
        const hashed = try sha256File(full_path);
        try result.append(allocator, .{
            .path = relative,
            .size = hashed.size,
            .sha256 = hashed.digest,
        });
    }
    std.mem.sort(ManifestEntry, result.items, {}, manifestLessThan);
    return result;
}

fn freeManifest(allocator: Allocator, manifest: *std.ArrayList(ManifestEntry)) void {
    for (manifest.items) |entry| allocator.free(entry.path);
    manifest.deinit(allocator);
}

fn directoryIsEmpty(path: []const u8) !bool {
    var directory = std.Io.Dir.cwd().openDir(io(), path, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return true,
        else => return err,
    };
    defer directory.close(io());
    var iterator = directory.iterate();
    return (try iterator.next(io())) == null;
}

fn pathsOverlap(allocator: Allocator, left: []const u8, right: []const u8) !bool {
    const resolved_left = try std.fs.path.resolve(allocator, &.{left});
    defer allocator.free(resolved_left);
    const resolved_right = try std.fs.path.resolve(allocator, &.{right});
    defer allocator.free(resolved_right);
    if (std.mem.eql(u8, resolved_left, resolved_right)) return true;
    const separator = std.fs.path.sep;
    return (std.mem.startsWith(u8, resolved_left, resolved_right) and resolved_left.len > resolved_right.len and resolved_left[resolved_right.len] == separator) or
        (std.mem.startsWith(u8, resolved_right, resolved_left) and resolved_right.len > resolved_left.len and resolved_right[resolved_left.len] == separator);
}

fn optionValue(argument: []const u8, prefix: []const u8) ?[]const u8 {
    return if (std.mem.startsWith(u8, argument, prefix)) argument[prefix.len..] else null;
}

fn setMetadata(field: *?[]const u8, value: []const u8, name: []const u8) void {
    if (value.len == 0 or value.len > max_metadata_len) {
        writeFd(2, "roc-fuzz ci: invalid ");
        writeFd(2, name);
        writeFd(2, " metadata\n");
        std.c._exit(2);
    }
    if (field.* != null) fail("a provenance option was supplied more than once");
    field.* = value;
}

fn validateSha256(value: []const u8) bool {
    if (value.len != 64) return false;
    for (value) |byte| switch (byte) {
        '0'...'9', 'a'...'f', 'A'...'F' => {},
        else => return false,
    };
    return true;
}

fn parseNumberAfter(text: []const u8, marker: []const u8) ?u64 {
    const start = std.mem.lastIndexOf(u8, text, marker) orelse return null;
    var index = start + marker.len;
    while (index < text.len and text[index] == ' ') : (index += 1) {}
    const number_start = index;
    while (index < text.len and text[index] >= '0' and text[index] <= '9') : (index += 1) {}
    if (index == number_start) return null;
    return std.fmt.parseUnsigned(u64, text[number_start..index], 10) catch null;
}

fn parseStats(log: []const u8) Stats {
    return .{
        .executed_units = parseNumberAfter(log, "stat::number_of_executed_units:"),
        .average_exec_per_sec = parseNumberAfter(log, "stat::average_exec_per_sec:"),
        .new_units_added = parseNumberAfter(log, "stat::new_units_added:"),
        .slowest_unit_time_sec = parseNumberAfter(log, "stat::slowest_unit_time_sec:"),
        .peak_rss_mb = parseNumberAfter(log, "stat::peak_rss_mb:"),
        .coverage_edges = parseNumberAfter(log, " cov:"),
        .coverage_features = parseNumberAfter(log, " ft:"),
    };
}

fn classifyFinding(log: []const u8, termination: Termination, failures: []const ManifestEntry) FindingKind {
    if (std.mem.indexOf(u8, log, "[roc-fuzz leak]") != null) return .roc_leak;
    if (std.mem.indexOf(u8, log, "[roc expect failed]") != null) return .roc_expectation;
    if (std.mem.indexOf(u8, log, "[roc crashed]") != null) return .roc_crash;
    if (std.mem.indexOf(u8, log, "timeout after") != null or std.mem.indexOf(u8, log, "libFuzzer: timeout") != null) return .timeout;
    if (std.mem.indexOf(u8, log, "out-of-memory") != null or std.mem.indexOf(u8, log, "out of memory") != null or std.mem.indexOf(u8, log, "rss_limit") != null) return .oom;
    if (std.mem.indexOf(u8, log, "slow-unit-") != null) return .slow_unit;
    if (termination.signal != null) return .native_crash;
    if (failures.len > 0 or termination.exit_code != 0) return .unknown;
    return .none;
}

fn outcomeFor(termination: Termination, failures: []const ManifestEntry) Outcome {
    if (termination.exit_code == 2 and termination.signal == null and failures.len == 0) return .infrastructure_error;
    if (termination.signal != null or termination.exit_code == null or termination.exit_code.? != 0 or failures.len > 0) return .finding;
    return .passed;
}

fn readWholeFile(allocator: Allocator, path: []const u8) ![]u8 {
    const stat = try std.Io.Dir.cwd().statFile(io(), path, .{});
    const size: usize = std.math.cast(usize, stat.size) orelse return error.FileTooBig;
    const bytes = try allocator.alloc(u8, size);
    errdefer allocator.free(bytes);
    const path_z = try allocator.dupeZ(u8, path);
    defer allocator.free(path_z);
    const file = std.c.fopen(path_z.ptr, "rb") orelse return error.FileNotFound;
    defer _ = std.c.fclose(file);
    const read = std.c.fread(bytes.ptr, 1, bytes.len, file);
    if (read != bytes.len) return error.UnexpectedEof;
    return bytes;
}

fn clock(clock_id: std.c.clockid_t) std.c.timespec {
    var value: std.c.timespec = undefined;
    if (std.c.clock_gettime(clock_id, &value) != 0) fail("could not read the system clock");
    return value;
}

fn unixMilliseconds(value: std.c.timespec) i64 {
    return @as(i64, @intCast(value.sec)) * 1000 + @divFloor(@as(i64, @intCast(value.nsec)), 1_000_000);
}

fn elapsedMilliseconds(start: std.c.timespec, finish: std.c.timespec) u64 {
    const start_ns = @as(i128, start.sec) * 1_000_000_000 + start.nsec;
    const finish_ns = @as(i128, finish.sec) * 1_000_000_000 + finish.nsec;
    return @intCast(@max(finish_ns - start_ns, 0) / 1_000_000);
}

fn outcomeName(outcome: Outcome) []const u8 {
    return switch (outcome) {
        .passed => "passed",
        .finding => "finding",
        .infrastructure_error => "infrastructure_error",
    };
}

fn findingName(kind: FindingKind) ?[]const u8 {
    return switch (kind) {
        .none => null,
        .roc_expectation => "roc_expectation",
        .roc_crash => "roc_crash",
        .roc_leak => "roc_leak",
        .native_crash => "native_crash",
        .timeout => "timeout",
        .oom => "oom",
        .slow_unit => "slow_unit",
        .unknown => "unknown",
    };
}

fn writeManifestJson(file: *std.c.FILE, manifest: []const ManifestEntry) bool {
    if (!fileWrite(file, "[")) return false;
    for (manifest, 0..) |entry, index| {
        if (index != 0 and !fileWrite(file, ",")) return false;
        if (!fileWrite(file, "{\"path\":")) return false;
        if (!jsonString(file, entry.path)) return false;
        if (!filePrint(file, ",\"size\":{d},\"sha256\":\"{s}\"}}", .{ entry.size, &entry.sha256 })) return false;
    }
    return fileWrite(file, "]");
}

fn writeReport(
    path: []const u8,
    target_name: []const u8,
    corpus_path: []const u8,
    child_argv: []const []const u8,
    provenance: Provenance,
    configuration: Configuration,
    started_at_ms: i64,
    finished_at_ms: i64,
    duration_ms: u64,
    termination: Termination,
    outcome: Outcome,
    finding: FindingKind,
    stats: Stats,
    executable_hash: [64]u8,
    log_hash: [64]u8,
    log_size: u64,
    corpus: []const ManifestEntry,
    failures: []const ManifestEntry,
) !void {
    const allocator = std.heap.c_allocator;
    const path_z = try allocator.dupeZ(u8, path);
    defer allocator.free(path_z);
    const file = std.c.fopen(path_z.ptr, "wb") orelse return error.CannotCreateReport;
    defer _ = std.c.fclose(file);

    var ok = fileWrite(file, "{\"schema_version\":\"roc-fuzz-ci/v1\",\"target\":");
    ok = ok and jsonString(file, target_name);
    ok = ok and filePrint(file, ",\"started_at_unix_ms\":{d},\"finished_at_unix_ms\":{d},\"duration_ms\":{d},\"outcome\":\"{s}\"", .{ started_at_ms, finished_at_ms, duration_ms, outcomeName(outcome) });
    ok = ok and fileWrite(file, ",\"finding_kind\":");
    ok = ok and jsonOptionalString(file, findingName(finding));
    ok = ok and fileWrite(file, ",\"provenance\":{\"source_revision\":");
    ok = ok and jsonOptionalString(file, provenance.source_revision);
    ok = ok and fileWrite(file, ",\"roc_version\":");
    ok = ok and jsonOptionalString(file, provenance.roc_version);
    ok = ok and fileWrite(file, ",\"platform_release\":");
    ok = ok and jsonOptionalString(file, provenance.platform_release);
    ok = ok and fileWrite(file, ",\"platform_sha256\":");
    ok = ok and jsonOptionalString(file, provenance.platform_sha256);
    ok = ok and fileWrite(file, "}");

    ok = ok and fileWrite(file, ",\"configuration\":{\"corpus\":");
    ok = ok and jsonString(file, corpus_path);
    ok = ok and fileWrite(file, ",\"time_seconds\":");
    ok = ok and jsonOptionalString(file, configuration.time orelse if (configuration.runs == null) "60" else null);
    ok = ok and fileWrite(file, ",\"runs\":");
    ok = ok and jsonOptionalString(file, configuration.runs);
    ok = ok and fileWrite(file, ",\"max_input_size\":");
    ok = ok and jsonOptionalString(file, configuration.max_input_size);
    ok = ok and fileWrite(file, ",\"memory_limit_mb\":");
    ok = ok and jsonOptionalString(file, configuration.memory_limit);
    ok = ok and fileWrite(file, ",\"timeout_seconds\":");
    ok = ok and jsonOptionalString(file, configuration.timeout);
    ok = ok and fileWrite(file, ",\"dictionary\":");
    ok = ok and jsonOptionalString(file, configuration.dictionary);
    ok = ok and fileWrite(file, ",\"seed\":");
    ok = ok and jsonOptionalString(file, configuration.seed);
    ok = ok and filePrint(file, ",\"leak_detection\":{s},\"command\":[", .{if (configuration.leak_detection) "true" else "false"});
    for (child_argv, 0..) |argument, index| {
        if (index != 0) ok = ok and fileWrite(file, ",");
        ok = ok and jsonString(file, argument);
    }
    ok = ok and fileWrite(file, "]}");

    ok = ok and filePrint(file, ",\"executable\":{{\"name\":", .{});
    ok = ok and jsonString(file, std.fs.path.basename(child_argv[0]));
    ok = ok and filePrint(file, ",\"sha256\":\"{s}\"}}", .{&executable_hash});
    ok = ok and fileWrite(file, ",\"termination\":{\"exit_code\":");
    ok = ok and if (termination.exit_code) |code| filePrint(file, "{d}", .{code}) else fileWrite(file, "null");
    ok = ok and fileWrite(file, ",\"signal\":");
    ok = ok and if (termination.signal) |signal| filePrint(file, "{d}", .{signal}) else fileWrite(file, "null");
    ok = ok and fileWrite(file, "}");

    ok = ok and fileWrite(file, ",\"libfuzzer\":{\"coverage_kind\":\"sanitizer_edge_feedback\",\"executed_units\":");
    ok = ok and jsonOptionalInt(file, stats.executed_units);
    ok = ok and fileWrite(file, ",\"average_exec_per_sec\":");
    ok = ok and jsonOptionalInt(file, stats.average_exec_per_sec);
    ok = ok and fileWrite(file, ",\"new_units_added\":");
    ok = ok and jsonOptionalInt(file, stats.new_units_added);
    ok = ok and fileWrite(file, ",\"slowest_unit_time_sec\":");
    ok = ok and jsonOptionalInt(file, stats.slowest_unit_time_sec);
    ok = ok and fileWrite(file, ",\"peak_rss_mb\":");
    ok = ok and jsonOptionalInt(file, stats.peak_rss_mb);
    ok = ok and fileWrite(file, ",\"coverage_edges\":");
    ok = ok and jsonOptionalInt(file, stats.coverage_edges);
    ok = ok and fileWrite(file, ",\"coverage_features\":");
    ok = ok and jsonOptionalInt(file, stats.coverage_features);
    ok = ok and fileWrite(file, "}");

    ok = ok and fileWrite(file, ",\"corpus\":");
    ok = ok and writeManifestJson(file, corpus);
    ok = ok and fileWrite(file, ",\"failures\":");
    ok = ok and writeManifestJson(file, failures);
    ok = ok and filePrint(file, ",\"log\":{{\"path\":\"run.log\",\"size\":{d},\"sha256\":\"{s}\"}}}}\n", .{ log_size, &log_hash });
    if (!ok or ferror(file) != 0) return error.CannotWriteReport;
}

fn writeSummary(
    path: []const u8,
    target_name: []const u8,
    outcome: Outcome,
    finding: FindingKind,
    duration_ms: u64,
    stats: Stats,
    provenance: Provenance,
    configuration: Configuration,
    failures: []const ManifestEntry,
) !void {
    const allocator = std.heap.c_allocator;
    const path_z = try allocator.dupeZ(u8, path);
    defer allocator.free(path_z);
    const file = std.c.fopen(path_z.ptr, "wb") orelse return error.CannotCreateSummary;
    defer _ = std.c.fclose(file);
    var ok = filePrint(file, "# roc-fuzz CI: {s}\n\n", .{target_name});
    ok = ok and filePrint(file, "| Result | Value |\n| --- | --- |\n| Outcome | `{s}` |\n| Finding | `{s}` |\n| Duration | {d} ms |\n", .{ outcomeName(outcome), findingName(finding) orelse "none", duration_ms });
    if (stats.executed_units) |value| ok = ok and filePrint(file, "| Executed units | {d} |\n", .{value});
    if (stats.coverage_edges) |value| ok = ok and filePrint(file, "| Sanitizer coverage edges | {d} |\n", .{value});
    if (stats.coverage_features) |value| ok = ok and filePrint(file, "| Sanitizer coverage features | {d} |\n", .{value});
    ok = ok and filePrint(file, "| Leak detection | {s} |\n| Source revision | `{s}` |\n| Roc version | `{s}` |\n| Platform release | `{s}` |\n\n", .{
        if (configuration.leak_detection) "enabled" else "disabled",
        provenance.source_revision orelse "not supplied",
        provenance.roc_version orelse "not supplied",
        provenance.platform_release orelse "not supplied",
    });
    if (failures.len > 0) {
        ok = ok and fileWrite(file, "## Failure artifacts\n\n");
        for (failures) |entry| ok = ok and filePrint(file, "- `failures/{s}` ({d} bytes, SHA-256 `{s}`)\n", .{ entry.path, entry.size, &entry.sha256 });
        ok = ok and fileWrite(file, "\nUse the target's `show`, `replay`, and `minimize` commands with the listed artifact.\n\n");
    }
    ok = ok and fileWrite(file, "> `coverage_edges` and `coverage_features` are libFuzzer search feedback, not Roc statement or branch coverage.\n");
    if (!ok or ferror(file) != 0) return error.CannotWriteSummary;
}

pub fn run(original_count: usize, original: [*][*:0]u8, target_name: []const u8) noreturn {
    if (original_count < 3) fail("usage: TARGET ci REPORT_DIR [CORPUS] [OPTION...]");
    const allocator = std.heap.c_allocator;
    // The process has no Zig `main` and therefore no application-owned Io
    // instance. Give the deliberately single-threaded global implementation
    // an allocator before using its process-spawn path.
    std.Io.Threaded.global_single_threaded.allocator = allocator;
    const original_executable = std.mem.span(original[0]);
    const resolved_executable = std.process.executablePathAlloc(io(), allocator) catch allocator.dupeZ(u8, original_executable) catch fail("out of memory");
    defer allocator.free(resolved_executable);
    const executable: []const u8 = resolved_executable;
    const report_dir = std.mem.span(original[2]);
    if (report_dir.len == 0) fail("REPORT_DIR must not be empty");

    var next: usize = 3;
    const corpus = if (next < original_count and !std.mem.startsWith(u8, std.mem.span(original[next]), "-")) blk: {
        defer next += 1;
        break :blk std.mem.span(original[next]);
    } else ".roc-fuzz/corpus";
    if (pathsOverlap(allocator, report_dir, corpus) catch fail("could not resolve report and corpus paths")) fail("REPORT_DIR and CORPUS must not overlap");
    if (!(directoryIsEmpty(report_dir) catch fail("could not inspect REPORT_DIR"))) fail("REPORT_DIR must be absent or empty");
    std.Io.Dir.createDirPath(.cwd(), io(), report_dir) catch fail("could not create REPORT_DIR");
    std.Io.Dir.createDirPath(.cwd(), io(), corpus) catch fail("could not create CORPUS");
    const failures_dir = std.fs.path.join(allocator, &.{ report_dir, "failures" }) catch fail("out of memory");
    defer allocator.free(failures_dir);
    std.Io.Dir.createDirPath(.cwd(), io(), failures_dir) catch fail("could not create failure directory");
    const log_path = std.fs.path.join(allocator, &.{ report_dir, "run.log" }) catch fail("out of memory");
    defer allocator.free(log_path);
    const report_path = std.fs.path.join(allocator, &.{ report_dir, "report.json" }) catch fail("out of memory");
    defer allocator.free(report_path);
    const summary_path = std.fs.path.join(allocator, &.{ report_dir, "summary.md" }) catch fail("out of memory");
    defer allocator.free(summary_path);

    var provenance: Provenance = .{};
    var configuration: Configuration = .{};
    var child_argv: std.ArrayList([]const u8) = .empty;
    defer child_argv.deinit(allocator);
    child_argv.append(allocator, executable) catch fail("out of memory");
    child_argv.append(allocator, "run") catch fail("out of memory");
    child_argv.append(allocator, corpus) catch fail("out of memory");

    while (next < original_count) : (next += 1) {
        const argument = std.mem.span(original[next]);
        if (optionValue(argument, "--source-revision=")) |value| {
            setMetadata(&provenance.source_revision, value, "source revision");
        } else if (optionValue(argument, "--roc-version=")) |value| {
            setMetadata(&provenance.roc_version, value, "Roc version");
        } else if (optionValue(argument, "--platform-release=")) |value| {
            setMetadata(&provenance.platform_release, value, "platform release");
        } else if (optionValue(argument, "--platform-sha256=")) |value| {
            if (!validateSha256(value)) fail("--platform-sha256 must contain exactly 64 hexadecimal characters");
            setMetadata(&provenance.platform_sha256, value, "platform SHA-256");
        } else if (optionValue(argument, "--time=")) |value| {
            configuration.time = value;
            child_argv.append(allocator, argument) catch fail("out of memory");
        } else if (optionValue(argument, "--runs=")) |value| {
            configuration.runs = value;
            child_argv.append(allocator, argument) catch fail("out of memory");
        } else if (optionValue(argument, "--max-input-size=")) |value| {
            configuration.max_input_size = value;
            child_argv.append(allocator, argument) catch fail("out of memory");
        } else if (optionValue(argument, "--memory-limit=")) |value| {
            configuration.memory_limit = value;
            child_argv.append(allocator, argument) catch fail("out of memory");
        } else if (optionValue(argument, "--timeout=")) |value| {
            configuration.timeout = value;
            child_argv.append(allocator, argument) catch fail("out of memory");
        } else if (optionValue(argument, "--dictionary=")) |value| {
            configuration.dictionary = value;
            child_argv.append(allocator, argument) catch fail("out of memory");
        } else if (optionValue(argument, "--seed=")) |value| {
            configuration.seed = value;
            child_argv.append(allocator, argument) catch fail("out of memory");
        } else if (std.mem.eql(u8, argument, "--no-detect-leaks")) {
            configuration.leak_detection = false;
            child_argv.append(allocator, argument) catch fail("out of memory");
        } else if (std.mem.eql(u8, argument, "--print-final-stats")) {
            // The supervisor always requests these statistics once.
        } else if (std.mem.startsWith(u8, argument, "--artifact-dir=")) {
            fail("ci owns the artifact directory; do not pass --artifact-dir");
        } else {
            writeFd(2, "roc-fuzz ci: unknown option: ");
            writeFd(2, argument);
            writeFd(2, "\n");
            std.c._exit(2);
        }
    }
    const artifact_option = std.fmt.allocPrint(allocator, "--artifact-dir={s}", .{failures_dir}) catch fail("out of memory");
    defer allocator.free(artifact_option);
    child_argv.append(allocator, artifact_option) catch fail("out of memory");
    child_argv.append(allocator, "--print-final-stats") catch fail("out of memory");

    const log_path_z = allocator.dupeZ(u8, log_path) catch fail("out of memory");
    defer allocator.free(log_path_z);
    const log_file = std.c.fopen(log_path_z.ptr, "wb") orelse fail("could not create run.log");
    defer _ = std.c.fclose(log_file);

    var pipe_fds: [2]std.c.fd_t = undefined;
    if (std.c.pipe(&pipe_fds) != 0) fail("could not create child output pipe");
    var read_pipe = std.Io.File{ .handle = pipe_fds[0], .flags = .{ .nonblocking = false } };
    var write_pipe = std.Io.File{ .handle = pipe_fds[1], .flags = .{ .nonblocking = false } };
    var child = std.process.spawn(io(), .{
        .argv = child_argv.items,
        .stdout = .{ .file = write_pipe },
        .stderr = .{ .file = write_pipe },
        .request_resource_usage_statistics = true,
    }) catch |err| {
        read_pipe.close(io());
        write_pipe.close(io());
        writeFd(2, "roc-fuzz ci: could not launch the fuzz target child process: ");
        writeFd(2, @errorName(err));
        writeFd(2, "\n");
        std.c._exit(2);
    };
    write_pipe.close(io());

    const started_realtime = clock(.REALTIME);
    const started_monotonic = clock(.MONOTONIC);
    var copy_buffer: [64 * 1024]u8 = undefined;
    while (true) {
        const count = std.posix.read(read_pipe.handle, &copy_buffer) catch fail("could not read child output");
        if (count == 0) break;
        const bytes = copy_buffer[0..count];
        writeFd(1, bytes);
        if (!fileWrite(log_file, bytes)) fail("could not write run.log");
    }
    read_pipe.close(io());
    const term = child.wait(io()) catch fail("could not wait for the fuzz target child process");
    const finished_monotonic = clock(.MONOTONIC);
    const finished_realtime = clock(.REALTIME);
    if (fflush(log_file) != 0) fail("could not flush run.log");

    const termination: Termination = switch (term) {
        .exited => |code| .{ .exit_code = code },
        .signal => |signal| .{ .signal = @intFromEnum(signal) },
        .stopped => |signal| .{ .signal = @intFromEnum(signal) },
        .unknown => |status| .{ .signal = status },
    };
    var corpus_manifest = collectManifest(allocator, corpus) catch fail("could not build the corpus manifest");
    defer freeManifest(allocator, &corpus_manifest);
    var failure_manifest = collectManifest(allocator, failures_dir) catch fail("could not build the failure manifest");
    defer freeManifest(allocator, &failure_manifest);
    const log_bytes = readWholeFile(allocator, log_path) catch fail("could not read run.log");
    defer allocator.free(log_bytes);
    const stats = parseStats(log_bytes);
    const outcome = outcomeFor(termination, failure_manifest.items);
    const finding = if (outcome == .finding) classifyFinding(log_bytes, termination, failure_manifest.items) else .none;
    const executable_hashed = sha256File(executable) catch fail("could not hash the target executable");
    const log_hashed = sha256File(log_path) catch fail("could not hash run.log");
    const duration_ms = elapsedMilliseconds(started_monotonic, finished_monotonic);

    writeReport(
        report_path,
        target_name,
        corpus,
        child_argv.items,
        provenance,
        configuration,
        unixMilliseconds(started_realtime),
        unixMilliseconds(finished_realtime),
        duration_ms,
        termination,
        outcome,
        finding,
        stats,
        executable_hashed.digest,
        log_hashed.digest,
        log_hashed.size,
        corpus_manifest.items,
        failure_manifest.items,
    ) catch fail("could not write report.json");
    writeSummary(summary_path, target_name, outcome, finding, duration_ms, stats, provenance, configuration, failure_manifest.items) catch fail("could not write summary.md");

    const exit_code: u8 = if (termination.exit_code) |code| code else if (termination.signal) |signal| @intCast(@min(255, 128 + signal)) else 2;
    std.c._exit(exit_code);
}
