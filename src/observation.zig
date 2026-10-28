//! Allocation scopes and logical traces. Only the Roc allocator hooks feed this
//! engine; storage and JSON rendering never call those hooks themselves.
const std = @import("std");

pub const metric_version = "roc-fuzz-allocations/1";
pub const trace_format = "roc-fuzz-trace/1";
pub const max_regions = 512;
pub const max_depth = 64;
pub const max_rules = 512;
pub const max_trace_events = 1024;
pub const max_name_bytes = 128;

pub const Error = error{
    Overflow,
    InvalidAllocation,
    InvalidScope,
    NoActiveScope,
    NameTooLong,
    RegionCapacity,
    DepthCapacity,
    RuleCapacity,
    LateRule,
    InvalidRule,
};

pub const Stats = struct {
    allocs: u64 = 0,
    reallocs: u64 = 0,
    deallocs: u64 = 0,
    requested_bytes: u64 = 0,
    entry_live_allocs: u64 = 0,
    entry_live_bytes: u64 = 0,
    exit_live_allocs: u64 = 0,
    exit_live_bytes: u64 = 0,
    peak_live_bytes: u64 = 0,
};

const Totals = struct {
    allocs: u64 = 0,
    reallocs: u64 = 0,
    deallocs: u64 = 0,
    requested_bytes: u64 = 0,
};

const Name = struct {
    bytes: [max_name_bytes]u8 = undefined,
    len: usize = 0,

    fn init(value: []const u8) Error!Name {
        if (value.len > max_name_bytes) return error.NameTooLong;
        var name: Name = .{};
        @memcpy(name.bytes[0..value.len], value);
        name.len = value.len;
        return name;
    }

    fn slice(self: *const Name) []const u8 {
        return self.bytes[0..self.len];
    }
};

const Region = struct {
    id: u64,
    parent_id: u64,
    name: Name,
    occurrence: u64,
    complete: bool = false,
    entry: Totals,
    stats: Stats,
    event_count: u64 = 0,
};

pub const Observation = struct {
    id: u64,
    parent_id: u64,
    name: []const u8,
    occurrence: u64,
    complete: bool,
    stats: Stats,
};

pub const RuleKind = enum { before, count, forbidden };

const Rule = struct {
    scope_id: u64,
    kind: RuleKind,
    a: Name,
    b: Name = .{},
    expected: u64 = 0,
    observed_a: u64 = 0,
    observed_b: u64 = 0,
    violated: bool = false,
    evaluated: bool = false,

    fn passes(self: *const Rule) bool {
        if (self.violated) return false;
        return switch (self.kind) {
            .before => self.observed_a != 0 and self.observed_b != 0,
            .count => self.observed_a == self.expected,
            .forbidden => self.observed_a == 0,
        };
    }
};

pub const RuleResult = struct {
    scope_id: u64,
    kind: RuleKind,
    a: []const u8,
    b: []const u8,
    expected: u64,
    observed_a: u64,
    observed_b: u64,
    evaluated: bool,
    passed: bool,
};

pub const EventKind = enum { begin, end, mark };

const Event = struct {
    sequence: u64,
    kind: EventKind,
    region_id: u64,
    name: Name,
};

pub const TraceEvent = struct {
    sequence: u64,
    kind: EventKind,
    region_id: u64,
    name: []const u8,
};

pub const Gap = struct {
    first_sequence: u64,
    last_sequence: u64,
    dropped: u64,
};

/// Fixed owned storage keeps instrumentation independent of the Roc allocator.
/// Keep an Engine in host-owned storage rather than the Roc heap. Reset it
/// before each input, including the live counts that existed at that boundary.
pub const Engine = struct {
    live_allocs: u64 = 0,
    live_bytes: u64 = 0,
    metric_valid: bool = true,
    trace_rules_passed: bool = true,
    capture_complete: bool = true,
    /// Reducing this affects diagnostics only, never observation inventories
    /// or rule validation. Values above max_trace_events use the fixed maximum.
    trace_limit: usize = max_trace_events,
    totals: Totals = .{},
    regions: [max_regions]Region = undefined,
    region_count: usize = 0,
    stack: [max_depth]usize = undefined,
    depth: usize = 0,
    rules: [max_rules]Rule = undefined,
    rule_count: usize = 0,
    events: [max_trace_events]Event = undefined,
    event_count: usize = 0,
    sequence: u64 = 0,
    gap: ?Gap = null,

    pub fn reset(self: *Engine, live_allocs: u64, live_bytes: u64) void {
        self.live_allocs = live_allocs;
        self.live_bytes = live_bytes;
        self.metric_valid = true;
        self.trace_rules_passed = true;
        self.capture_complete = true;
        self.totals = .{};
        self.region_count = 0;
        self.depth = 0;
        self.rule_count = 0;
        self.event_count = 0;
        self.sequence = 0;
        self.gap = null;
    }

    fn fail(self: *Engine, err: Error) Error {
        self.metric_valid = false;
        return err;
    }

    fn add(self: *Engine, a: u64, b: u64) Error!u64 {
        return std.math.add(u64, a, b) catch self.fail(error.Overflow);
    }

    fn current(self: *Engine) Error!*Region {
        if (self.depth == 0) return self.fail(error.NoActiveScope);
        return &self.regions[self.stack[self.depth - 1]];
    }

    fn peak(self: *Engine, live_bytes: u64) void {
        for (self.stack[0..self.depth]) |index| {
            self.regions[index].stats.peak_live_bytes = @max(self.regions[index].stats.peak_live_bytes, live_bytes);
        }
    }

    /// Record a successful roc_alloc, using its requested length without host
    /// headers. Allocations made before a scope still contribute its entry-live
    /// memory and peak; their allocation counts do not belong to that scope.
    pub fn alloc(self: *Engine, length: u64) Error!void {
        const allocs = try self.add(self.totals.allocs, 1);
        const requested = try self.add(self.totals.requested_bytes, length);
        const live_allocs = try self.add(self.live_allocs, 1);
        const live_bytes = try self.add(self.live_bytes, length);
        self.totals.allocs = allocs;
        self.totals.requested_bytes = requested;
        self.live_allocs = live_allocs;
        self.live_bytes = live_bytes;
        self.peak(live_bytes);
    }

    pub fn dealloc(self: *Engine, length: u64) Error!void {
        if (self.live_allocs == 0 or length > self.live_bytes) return self.fail(error.InvalidAllocation);
        const deallocs = try self.add(self.totals.deallocs, 1);
        self.totals.deallocs = deallocs;
        self.live_allocs -= 1;
        self.live_bytes -= length;
    }

    /// The host's realloc allocates the new block before releasing the old one.
    /// Count one realloc, include that actual old/new overlap in every active
    /// peak, and leave allocation/deallocation counts and final live count alone.
    pub fn realloc(self: *Engine, old_length: u64, new_length: u64) Error!void {
        if (self.live_allocs == 0 or old_length > self.live_bytes) return self.fail(error.InvalidAllocation);
        const reallocs = try self.add(self.totals.reallocs, 1);
        const requested = try self.add(self.totals.requested_bytes, new_length);
        _ = try self.add(self.live_allocs, 1);
        const overlapping = try self.add(self.live_bytes, new_length);
        self.totals.reallocs = reallocs;
        self.totals.requested_bytes = requested;
        self.peak(overlapping);
        self.live_bytes = overlapping - old_length;
    }

    pub fn start(self: *Engine, label: []const u8) Error!u64 {
        if (self.region_count == max_regions) return self.fail(error.RegionCapacity);
        if (self.depth == max_depth) return self.fail(error.DepthCapacity);
        const name = Name.init(label) catch |err| return self.fail(err);
        const parent_id: u64 = if (self.depth == 0) 0 else self.regions[self.stack[self.depth - 1]].id;
        var occurrence: u64 = 1;
        for (self.regions[0..self.region_count]) |*region| {
            if (region.parent_id == parent_id and std.mem.eql(u8, region.name.slice(), label)) occurrence += 1;
        }
        const index = self.region_count;
        const id: u64 = @intCast(index + 1);
        self.regions[index] = .{
            .id = id,
            .parent_id = parent_id,
            .name = name,
            .occurrence = occurrence,
            .entry = self.totals,
            .stats = .{
                .entry_live_allocs = self.live_allocs,
                .entry_live_bytes = self.live_bytes,
                .peak_live_bytes = self.live_bytes,
            },
        };
        self.region_count += 1;
        self.stack[self.depth] = index;
        self.depth += 1;
        try self.capture(.begin, id, label);
        return id;
    }

    fn statsNow(self: *const Engine, region: *const Region) Stats {
        var stats = region.stats;
        stats.allocs = self.totals.allocs - region.entry.allocs;
        stats.reallocs = self.totals.reallocs - region.entry.reallocs;
        stats.deallocs = self.totals.deallocs - region.entry.deallocs;
        stats.requested_bytes = self.totals.requested_bytes - region.entry.requested_bytes;
        stats.exit_live_allocs = self.live_allocs;
        stats.exit_live_bytes = self.live_bytes;
        return stats;
    }

    pub fn finish(self: *Engine, id: u64) Error!Stats {
        const region = try self.current();
        if (region.id != id) return self.fail(error.InvalidScope);
        region.stats = self.statsNow(region);
        region.complete = true;
        for (self.rules[0..self.rule_count]) |*rule| {
            if (rule.scope_id == id) {
                rule.evaluated = true;
                if (!rule.passes()) self.trace_rules_passed = false;
            }
        }
        self.depth -= 1;
        try self.capture(.end, id, region.name.slice());
        // A completed immediate child is a single event in its parent. Marks
        // inside that child are visible to rules on that child alone.
        if (self.depth != 0) try self.event(region.name.slice());
        return region.stats;
    }

    fn capture(self: *Engine, kind: EventKind, region_id: u64, label: []const u8) Error!void {
        self.sequence = try self.add(self.sequence, 1);
        if (self.event_count < @min(self.trace_limit, max_trace_events)) {
            self.events[self.event_count] = .{
                .sequence = self.sequence,
                .kind = kind,
                .region_id = region_id,
                .name = Name.init(label) catch |err| return self.fail(err),
            };
            self.event_count += 1;
        } else {
            self.capture_complete = false;
            if (self.gap) |*gap| {
                gap.last_sequence = self.sequence;
                gap.dropped = try self.add(gap.dropped, 1);
            } else self.gap = .{ .first_sequence = self.sequence, .last_sequence = self.sequence, .dropped = 1 };
        }
    }

    fn event(self: *Engine, label: []const u8) Error!void {
        const region = try self.current();
        region.event_count = try self.add(region.event_count, 1);
        for (self.rules[0..self.rule_count]) |*rule| {
            if (rule.scope_id != region.id) continue;
            if (std.mem.eql(u8, rule.a.slice(), label)) {
                rule.observed_a = try self.add(rule.observed_a, 1);
                switch (rule.kind) {
                    .before => if (rule.observed_b != 0) {
                        rule.violated = true;
                    },
                    .count => if (rule.observed_a > rule.expected) {
                        rule.violated = true;
                    },
                    .forbidden => rule.violated = true,
                }
            }
            if (rule.kind == .before and std.mem.eql(u8, rule.b.slice(), label)) {
                rule.observed_b = try self.add(rule.observed_b, 1);
            }
            if (rule.violated) self.trace_rules_passed = false;
        }
    }

    pub fn mark(self: *Engine, label: []const u8) Error!void {
        const region = try self.current();
        if (label.len > max_name_bytes) return self.fail(error.NameTooLong);
        try self.event(label);
        try self.capture(.mark, region.id, label);
    }

    fn register(self: *Engine, kind: RuleKind, a: []const u8, b: []const u8, expected: u64) Error!void {
        const region = try self.current();
        if (region.event_count != 0) return self.fail(error.LateRule);
        if (self.rule_count == max_rules) return self.fail(error.RuleCapacity);
        if (kind == .before and std.mem.eql(u8, a, b)) return self.fail(error.InvalidRule);
        const name_a = Name.init(a) catch |err| return self.fail(err);
        const name_b = Name.init(b) catch |err| return self.fail(err);
        self.rules[self.rule_count] = .{ .scope_id = region.id, .kind = kind, .a = name_a, .b = name_b, .expected = expected };
        self.rule_count += 1;
    }

    pub fn before(self: *Engine, a: []const u8, b: []const u8) Error!void {
        try self.register(.before, a, b, 0);
    }

    pub fn count(self: *Engine, label: []const u8, expected: u64) Error!void {
        try self.register(.count, label, "", expected);
    }

    pub fn forbidden(self: *Engine, label: []const u8) Error!void {
        try self.register(.forbidden, label, "", 0);
    }

    pub fn complete(self: *const Engine) bool {
        return self.depth == 0 and self.metric_valid;
    }

    /// Views borrow their names from the engine; free only the returned slice.
    pub fn observations(self: *const Engine, allocator: std.mem.Allocator) ![]Observation {
        const result = try allocator.alloc(Observation, self.region_count);
        for (self.regions[0..self.region_count], result) |*region, *observation| {
            observation.* = .{
                .id = region.id,
                .parent_id = region.parent_id,
                .name = region.name.slice(),
                .occurrence = region.occurrence,
                .complete = region.complete,
                .stats = if (region.complete) region.stats else self.statsNow(region),
            };
        }
        return result;
    }

    pub fn observationsJson(self: *const Engine, allocator: std.mem.Allocator) ![]u8 {
        const values = try self.observations(allocator);
        defer allocator.free(values);
        return std.json.Stringify.valueAlloc(allocator, values, .{});
    }

    pub const baselineJson = observationsJson;

    pub fn traceJson(self: *const Engine, allocator: std.mem.Allocator) ![]u8 {
        const region_views = try self.observations(allocator);
        defer allocator.free(region_views);
        const event_views = try allocator.alloc(TraceEvent, self.event_count);
        defer allocator.free(event_views);
        for (self.events[0..self.event_count], event_views) |*event_value, *view| {
            view.* = .{ .sequence = event_value.sequence, .kind = event_value.kind, .region_id = event_value.region_id, .name = event_value.name.slice() };
        }
        const rule_views = try allocator.alloc(RuleResult, self.rule_count);
        defer allocator.free(rule_views);
        for (self.rules[0..self.rule_count], rule_views) |*rule, *view| {
            view.* = .{
                .scope_id = rule.scope_id,
                .kind = rule.kind,
                .a = rule.a.slice(),
                .b = rule.b.slice(),
                .expected = rule.expected,
                .observed_a = rule.observed_a,
                .observed_b = rule.observed_b,
                .evaluated = rule.evaluated,
                .passed = rule.evaluated and rule.passes(),
            };
        }
        return std.json.Stringify.valueAlloc(allocator, .{
            .format = trace_format,
            .metric_version = metric_version,
            .metric_valid = self.metric_valid,
            .trace_rules_passed = self.trace_rules_passed,
            .capture_complete = self.capture_complete,
            .complete = self.complete(),
            .regions = region_views,
            .rules = rule_views,
            .events = event_views,
            .gap = self.gap,
        }, .{});
    }

    pub const diagnosticJson = traceJson;
    pub const snapshotJson = traceJson;
};

test "allocation statistics include entry-live memory and returned values" {
    var engine: Engine = .{};
    engine.reset(2, 48);
    const scope = try engine.start("property");
    try engine.alloc(100);
    try engine.alloc(0);
    try engine.dealloc(0);
    const stats = try engine.finish(scope);
    try std.testing.expectEqualDeep(Stats{
        .allocs = 2,
        .deallocs = 1,
        .requested_bytes = 100,
        .entry_live_allocs = 2,
        .entry_live_bytes = 48,
        .exit_live_allocs = 3,
        .exit_live_bytes = 148,
        .peak_live_bytes = 148,
    }, stats);
    try std.testing.expect(engine.complete());
}

test "reallocation counts requested bytes and actual old/new overlap when growing or shrinking" {
    var engine: Engine = .{};
    engine.reset(1, 100);
    const scope = try engine.start("realloc");
    try engine.realloc(100, 200);
    try engine.realloc(200, 50);
    const stats = try engine.finish(scope);
    try std.testing.expectEqualDeep(Stats{
        .reallocs = 2,
        .requested_bytes = 250,
        .entry_live_allocs = 1,
        .entry_live_bytes = 100,
        .exit_live_allocs = 1,
        .exit_live_bytes = 50,
        .peak_live_bytes = 300,
    }, stats);
}

test "nested scopes are inclusive and manual windows retain completed results" {
    var engine: Engine = .{};
    engine.reset(0, 0);
    try engine.alloc(20);
    const outer = try engine.start("outer");
    try engine.alloc(10);
    const inner = try engine.start("inner");
    try engine.realloc(10, 30);
    const inner_stats = try engine.finish(inner);
    try engine.dealloc(30);
    const outer_stats = try engine.finish(outer);
    try std.testing.expectEqual(@as(u64, 1), inner_stats.reallocs);
    try std.testing.expectEqual(@as(u64, 30), inner_stats.entry_live_bytes);
    try std.testing.expectEqual(@as(u64, 50), inner_stats.exit_live_bytes);
    try std.testing.expectEqual(@as(u64, 60), inner_stats.peak_live_bytes);
    try std.testing.expectEqual(@as(u64, 1), outer_stats.allocs);
    try std.testing.expectEqual(@as(u64, 1), outer_stats.reallocs);
    try std.testing.expectEqual(@as(u64, 1), outer_stats.deallocs);
    try std.testing.expectEqual(@as(u64, 40), outer_stats.requested_bytes);
    try std.testing.expectEqual(@as(u64, 20), outer_stats.exit_live_bytes);
    try std.testing.expectEqual(@as(u64, 60), outer_stats.peak_live_bytes);
}

test "arithmetic errors and invalid scope lifetimes fail explicitly" {
    var engine: Engine = .{};
    engine.reset(1, std.math.maxInt(u64));
    _ = try engine.start("overflow");
    try std.testing.expectError(error.Overflow, engine.realloc(std.math.maxInt(u64), 1));
    try std.testing.expect(!engine.metric_valid);
    engine.reset(0, 0);
    const outer = try engine.start("outer");
    _ = try engine.start("inner");
    try std.testing.expectError(error.InvalidScope, engine.finish(outer));
    try std.testing.expect(!engine.metric_valid);
    engine.reset(0, 0);
    try std.testing.expectError(error.InvalidAllocation, engine.dealloc(1));
    engine.reset(0, 0);
    const region = try engine.start("once");
    _ = try engine.finish(region);
    try std.testing.expectError(error.NoActiveScope, engine.finish(region));
}

test "trace rules see direct marks and completed immediate child regions" {
    var engine: Engine = .{};
    engine.reset(0, 0);
    const root = try engine.start("property");
    try engine.before("decode", "encode");
    try engine.count("decode", 2);
    try engine.forbidden("unexpected");
    const first = try engine.start("decode");
    try engine.mark("unexpected"); // A grandchild event is outside root's rules.
    _ = try engine.finish(first);
    const second = try engine.start("decode");
    _ = try engine.finish(second);
    try engine.mark("encode");
    _ = try engine.finish(root);
    try std.testing.expect(engine.trace_rules_passed);
    const values = try engine.observations(std.testing.allocator);
    defer std.testing.allocator.free(values);
    try std.testing.expectEqual(@as(u64, 1), values[1].occurrence);
    try std.testing.expectEqual(@as(u64, 2), values[2].occurrence);
    try std.testing.expectEqual(@as(u64, 1), values[2].parent_id);
}

test "before requires both events and every first event before every second" {
    var engine: Engine = .{};
    for ([_][]const []const u8{
        &.{ "a", "b", "a" },
        &.{ "a", "a" },
        &.{ "b", "b" },
        &.{},
    }) |events| {
        engine.reset(0, 0);
        const root = try engine.start("root");
        try engine.before("a", "b");
        for (events) |event_value| try engine.mark(event_value);
        _ = try engine.finish(root);
        try std.testing.expect(!engine.trace_rules_passed);
    }
    engine.reset(0, 0);
    const root = try engine.start("root");
    try engine.before("a", "b");
    for ([_][]const u8{ "a", "a", "b", "b" }) |event_value| try engine.mark(event_value);
    _ = try engine.finish(root);
    try std.testing.expect(engine.trace_rules_passed);
}

test "rule violations after diagnostic truncation remain failures with explicit ordered gap" {
    var engine: Engine = .{};
    engine.trace_limit = 2;
    engine.reset(0, 0);
    const root = try engine.start("root");
    try engine.forbidden("bad");
    try engine.count("good", 1);
    try engine.mark("good");
    try engine.mark("bad");
    _ = try engine.finish(root);
    try std.testing.expect(!engine.trace_rules_passed);
    try std.testing.expect(!engine.capture_complete);
    try std.testing.expect(engine.metric_valid);
    try std.testing.expectEqualDeep(Gap{ .first_sequence = 3, .last_sequence = 4, .dropped = 2 }, engine.gap.?);
    try std.testing.expectEqual(@as(u64, 1), engine.events[0].sequence);
    try std.testing.expectEqual(@as(u64, 2), engine.events[1].sequence);
}

test "unfinished regions and unevaluated rules are explicit in diagnostics" {
    var engine: Engine = .{};
    engine.reset(0, 0);
    const root = try engine.start("root");
    try engine.count("child", 1);
    _ = try engine.start("child");
    try engine.alloc(12);
    const encoded = try engine.traceJson(std.testing.allocator);
    defer std.testing.allocator.free(encoded);
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, encoded, .{});
    defer parsed.deinit();
    try std.testing.expect(!parsed.value.object.get("complete").?.bool);
    try std.testing.expect(!parsed.value.object.get("regions").?.array.items[0].object.get("complete").?.bool);
    try std.testing.expect(!parsed.value.object.get("rules").?.array.items[0].object.get("evaluated").?.bool);
    try std.testing.expectEqual(root, @as(u64, @intCast(parsed.value.object.get("regions").?.array.items[1].object.get("parent_id").?.integer)));
    try std.testing.expect(!engine.complete());
}

test "late rules and capacity errors cannot silently discard assertions or observations" {
    var engine: Engine = .{};
    engine.reset(0, 0);
    _ = try engine.start("root");
    try engine.mark("first");
    try std.testing.expectError(error.LateRule, engine.count("first", 1));
    engine.reset(0, 0);
    _ = try engine.start("root");
    for (0..max_rules) |_| try engine.count("event", 0);
    try std.testing.expectError(error.RuleCapacity, engine.forbidden("bad"));
    engine.reset(0, 0);
    for (0..max_regions) |_| {
        const id = try engine.start("repeated");
        _ = try engine.finish(id);
    }
    try std.testing.expectError(error.RegionCapacity, engine.start("excess"));
    try std.testing.expect(!engine.metric_valid);
}

test "baseline excludes diagnostic capacity but preserves exact region inventory and statistics" {
    var engine: Engine = .{};
    engine.trace_limit = 0;
    engine.reset(0, 0);
    const root = try engine.start("root \"quoted\"");
    try engine.alloc(17);
    _ = try engine.finish(root);
    const baseline = try engine.baselineJson(std.testing.allocator);
    defer std.testing.allocator.free(baseline);
    try std.testing.expect(std.mem.indexOf(u8, baseline, "capture_complete") == null);
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, baseline, .{});
    defer parsed.deinit();
    try std.testing.expectEqual(@as(usize, 1), parsed.value.array.items.len);
    try std.testing.expectEqualStrings("root \"quoted\"", parsed.value.array.items[0].object.get("name").?.string);
    try std.testing.expectEqual(@as(i64, 17), parsed.value.array.items[0].object.get("stats").?.object.get("peak_live_bytes").?.integer);
}

test "count rules require exact counts including zero and can fail before scope completion" {
    var engine: Engine = .{};
    engine.reset(0, 0);
    var scope = try engine.start("under");
    try engine.count("event", 2);
    try engine.mark("event");
    _ = try engine.finish(scope);
    try std.testing.expect(!engine.trace_rules_passed);
    engine.reset(0, 0);
    scope = try engine.start("over");
    try engine.count("event", 0);
    try engine.mark("event");
    try std.testing.expect(!engine.trace_rules_passed);
    _ = try engine.finish(scope);
    engine.reset(0, 0);
    scope = try engine.start("zero");
    try engine.count("event", 0);
    _ = try engine.finish(scope);
    try std.testing.expect(engine.trace_rules_passed);
}

test "repeated region names have independent path and occurrence identities" {
    var engine: Engine = .{};
    engine.reset(0, 0);
    const root = try engine.start("root");
    for (0..2) |_| {
        const parent = try engine.start("same");
        const child = try engine.start("same");
        _ = try engine.finish(child);
        _ = try engine.finish(parent);
    }
    _ = try engine.finish(root);
    const values = try engine.observations(std.testing.allocator);
    defer std.testing.allocator.free(values);
    try std.testing.expectEqual(@as(u64, 1), values[1].occurrence);
    try std.testing.expectEqual(@as(u64, 2), values[3].occurrence);
    try std.testing.expectEqual(@as(u64, 1), values[2].occurrence);
    try std.testing.expectEqual(@as(u64, 1), values[4].occurrence);
    try std.testing.expect(values[2].parent_id != values[4].parent_id);
}

test "counter overflow never saturates or partially commits allocation metrics" {
    var engine: Engine = .{};
    engine.reset(1, 7);
    engine.totals.requested_bytes = std.math.maxInt(u64);
    try std.testing.expectError(error.Overflow, engine.alloc(1));
    try std.testing.expectEqual(@as(u64, 1), engine.live_allocs);
    try std.testing.expectEqual(@as(u64, 7), engine.live_bytes);
    try std.testing.expectEqual(@as(u64, 0), engine.totals.allocs);
    try std.testing.expect(!engine.metric_valid);
    engine.reset(1, 7);
    engine.totals.deallocs = std.math.maxInt(u64);
    try std.testing.expectError(error.Overflow, engine.dealloc(7));
    try std.testing.expectEqual(@as(u64, 1), engine.live_allocs);
    try std.testing.expectEqual(@as(u64, 7), engine.live_bytes);
    engine.reset(std.math.maxInt(u64), 0);
    try std.testing.expectError(error.Overflow, engine.realloc(0, 0));
    engine.reset(0, 0);
    engine.totals.allocs = std.math.maxInt(u64);
    try std.testing.expectError(error.Overflow, engine.alloc(0));
}

test "names are owned and depth or label limits fail explicitly" {
    var engine: Engine = .{};
    engine.reset(0, 0);
    var label = [_]u8{ 'o', 'l', 'd' };
    const scope = try engine.start(&label);
    label[0] = 'n';
    _ = try engine.finish(scope);
    try std.testing.expectEqualStrings("old", engine.regions[0].name.slice());
    const oversized = [_]u8{'x'} ** (max_name_bytes + 1);
    try std.testing.expectError(error.NameTooLong, engine.start(&oversized));
    engine.reset(0, 0);
    for (0..max_depth) |_| _ = try engine.start("nested");
    try std.testing.expectError(error.DepthCapacity, engine.start("too deep"));
    try std.testing.expect(!engine.metric_valid);
}
