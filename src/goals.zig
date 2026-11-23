//! Campaign goals: the inventory a target declares, and which of its goals the
//! current input has reached. Storage is fixed, so recording an event never
//! allocates and the counters can be handed to libFuzzer by address.
const std = @import("std");

pub const max_goals = 1024;
pub const max_name_bytes = 128;
const slot_count = 4 * max_goals;

pub const Error = error{ GoalCapacity, EmptyGoalName, GoalNameTooLong, DuplicateGoal };

pub const Tracker = struct {
    count: usize = 0,
    names: [max_goals][max_name_bytes]u8 = undefined,
    lengths: [max_goals]u8 = undefined,
    /// Open addressing by name hash. A slot holds a goal index plus one.
    slots: [slot_count]u16 = @splat(0),
    /// One byte per declared goal, nonzero while the current input has reached
    /// it. The first `count` bytes are the region libFuzzer reads as coverage.
    counters: [max_goals]u8 = @splat(0),
    hits: [max_goals]u16 = undefined,
    hit_count: usize = 0,

    fn slot(label: []const u8) usize {
        return @intCast(std.hash.Wyhash.hash(0, label) % slot_count);
    }

    pub fn name(self: *const Tracker, index: usize) []const u8 {
        return self.names[index][0..self.lengths[index]];
    }

    pub fn find(self: *const Tracker, label: []const u8) ?u16 {
        if (self.count == 0 or label.len == 0 or label.len > max_name_bytes) return null;
        var at = slot(label);
        while (self.slots[at] != 0) : (at = (at + 1) % slot_count) {
            const index = self.slots[at] - 1;
            if (std.mem.eql(u8, self.name(index), label)) return index;
        }
        return null;
    }

    /// Add one goal to the inventory. Declaration order is the goal's index in
    /// every report and its position in the coverage region.
    pub fn declare(self: *Tracker, label: []const u8) Error!u16 {
        if (label.len == 0) return error.EmptyGoalName;
        if (label.len > max_name_bytes) return error.GoalNameTooLong;
        if (self.find(label) != null) return error.DuplicateGoal;
        if (self.count == max_goals) return error.GoalCapacity;
        const index: u16 = @intCast(self.count);
        @memcpy(self.names[index][0..label.len], label);
        self.lengths[index] = @intCast(label.len);
        var at = slot(label);
        while (self.slots[at] != 0) at = (at + 1) % slot_count;
        self.slots[at] = index + 1;
        self.count += 1;
        return index;
    }

    /// Start an input having reached nothing.
    pub fn begin(self: *Tracker) void {
        for (self.hits[0..self.hit_count]) |index| self.counters[index] = 0;
        self.hit_count = 0;
    }

    /// An event of this name occurred. Events that name no goal cost one lookup.
    pub fn event(self: *Tracker, label: []const u8) void {
        const index = self.find(label) orelse return;
        if (self.counters[index] != 0) return;
        self.counters[index] = 1;
        self.hits[self.hit_count] = index;
        self.hit_count += 1;
    }

    /// The goals reached since `begin`, in the order they were first reached.
    pub fn reached(self: *const Tracker) []const u16 {
        return self.hits[0..self.hit_count];
    }
};

test "an inventory keeps declaration order and refuses invalid names" {
    var tracker: Tracker = .{};
    try std.testing.expectEqual(@as(u16, 0), try tracker.declare("first"));
    try std.testing.expectEqual(@as(u16, 1), try tracker.declare("second"));
    try std.testing.expectError(error.DuplicateGoal, tracker.declare("first"));
    try std.testing.expectError(error.EmptyGoalName, tracker.declare(""));
    const longest = [_]u8{'x'} ** max_name_bytes;
    try std.testing.expectEqual(@as(u16, 2), try tracker.declare(&longest));
    try std.testing.expectError(error.GoalNameTooLong, tracker.declare(&(longest ++ [_]u8{'x'})));
    try std.testing.expectEqual(@as(usize, 3), tracker.count);
    try std.testing.expectEqualStrings("second", tracker.name(1));
    try std.testing.expectEqualStrings(&longest, tracker.name(2));
    try std.testing.expectEqual(@as(?u16, 1), tracker.find("second"));
    try std.testing.expectEqual(@as(?u16, null), tracker.find("third"));
}

test "an input reaches each goal once and the next input starts clean" {
    var tracker: Tracker = .{};
    _ = try tracker.declare("a");
    _ = try tracker.declare("b");
    _ = try tracker.declare("c");
    tracker.begin();
    tracker.event("c");
    tracker.event("not a goal");
    tracker.event("a");
    tracker.event("c");
    try std.testing.expectEqualSlices(u16, &.{ 2, 0 }, tracker.reached());
    try std.testing.expectEqualSlices(u8, &.{ 1, 0, 1 }, tracker.counters[0..3]);
    tracker.begin();
    try std.testing.expectEqual(@as(usize, 0), tracker.reached().len);
    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 0 }, tracker.counters[0..3]);
    tracker.event("b");
    try std.testing.expectEqualSlices(u16, &.{1}, tracker.reached());
}

test "a full inventory fails explicitly and every goal stays findable" {
    var tracker: Tracker = .{};
    var buffer: [16]u8 = undefined;
    for (0..max_goals) |index| _ = try tracker.declare(try std.fmt.bufPrint(&buffer, "goal {d}", .{index}));
    try std.testing.expectError(error.GoalCapacity, tracker.declare("one more"));
    for (0..max_goals) |index| {
        try std.testing.expectEqual(@as(?u16, @intCast(index)), tracker.find(try std.fmt.bufPrint(&buffer, "goal {d}", .{index})));
    }
    tracker.begin();
    for (0..max_goals) |index| tracker.event(try std.fmt.bufPrint(&buffer, "goal {d}", .{index}));
    try std.testing.expectEqual(@as(usize, max_goals), tracker.reached().len);
}
