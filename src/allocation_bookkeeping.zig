//! Identifies the private ownership box used by measurement, without hiding
//! user allocations or changing the allocator's address/size layout.
const std = @import("std");

pub const Error = error{ Overflow, AlreadyPending, NoPending, WrongScope, WrongBox };

/// Keep the existing one-word host prefix. Requested lengths never include it.
pub fn pack(requested: usize, bookkeeping: bool) Error!usize {
    return (std.math.mul(usize, requested, 2) catch return error.Overflow) | @intFromBool(bookkeeping);
}

pub fn length(metadata: usize) usize {
    return metadata >> 1;
}

pub fn isBookkeeping(metadata: usize) bool {
    return metadata & 1 != 0;
}

pub const ReturnBox = struct {
    scope: ?u64 = null,
    waiting: bool = false,
    allocation_start: ?usize = null,
    allocation_end: usize = 0,

    pub fn prepare(self: *ReturnBox, scope: u64) Error!void {
        if (self.scope != null) return error.AlreadyPending;
        self.* = .{ .scope = scope, .waiting = true };
    }

    /// Only the next allocation is scaffolding. Payload teardown and any other
    /// allocations continue through the ordinary counters and active scopes.
    pub fn claim(self: *ReturnBox, address: usize, requested: usize) Error!bool {
        if (!self.waiting) return false;
        const end = std.math.add(usize, address, requested) catch return error.Overflow;
        self.waiting = false;
        self.allocation_start = address;
        self.allocation_end = end;
        return true;
    }

    pub fn finish(self: *ReturnBox, scope: u64, boxed: usize) Error!void {
        const expected = self.scope orelse return error.NoPending;
        if (scope != expected) return error.WrongScope;
        if (self.allocation_start) |start| {
            if (boxed < start or boxed > self.allocation_end) return error.WrongBox;
        }
        // Unit/static boxes and already erased callables may need no allocation.
        // Clear the marker in every case before ordinary Roc execution resumes.
        self.* = .{};
    }
};

test "metadata preserves requested lengths and one-word allocator layout" {
    for ([_]usize{ 0, 1, 8, 17, 4096, std.math.maxInt(usize) >> 1 }) |requested| {
        for ([_]bool{ false, true }) |internal| {
            const encoded = try pack(requested, internal);
            try std.testing.expectEqual(requested, length(encoded));
            try std.testing.expectEqual(internal, isBookkeeping(encoded));
        }
    }
    try std.testing.expectError(error.Overflow, pack(std.math.maxInt(usize), false));
}

test "only the ownership container is tagged and ordinary allocations remain visible" {
    var state: ReturnBox = .{};
    try std.testing.expect(!try state.claim(100, 32));
    try state.prepare(7);
    try std.testing.expect(try state.claim(100, 40));
    try std.testing.expect(!try state.claim(200, 16));
    try state.finish(7, 116);
    try std.testing.expect(state.scope == null and !state.waiting);
    try std.testing.expect(!try state.claim(300, 16));
}

test "unit static and already erased boxes cannot leave a stale marker" {
    var state: ReturnBox = .{};
    for ([_]usize{ 0, 100 }) |boxed| {
        try state.prepare(1);
        try state.finish(1, boxed);
        try std.testing.expect(!try state.claim(200, 24));
    }
}

test "invalid box protocols fail explicitly" {
    var state: ReturnBox = .{};
    try std.testing.expectError(error.NoPending, state.finish(1, 0));
    try state.prepare(1);
    try std.testing.expectError(error.AlreadyPending, state.prepare(2));
    try std.testing.expectError(error.WrongScope, state.finish(2, 0));
    try std.testing.expect(try state.claim(100, 40));
    try std.testing.expectError(error.WrongBox, state.finish(1, 200));
    try state.finish(1, 108);
}
