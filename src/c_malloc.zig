//! C allocator for the roc-fuzz executable, overriding the weak malloc family
//! that zig's bundled libc (libzigc.a) provides.
//!
//! Zig 0.16's libc malloc is backed by std.heap.SmpAllocator, which keys its
//! freelists to per-CPU metadata slots and migrates a thread to the next slot
//! whenever an allocation finds its current slot empty. Under a fuzzing
//! workload (hundreds of thousands of alloc/free pairs per second on one
//! thread) the migration strands every previously filled freelist behind the
//! thread's new position, so the process keeps mapping fresh slabs while the
//! freed memory sits unreachable in other slots. RSS then ratchets up
//! nondeterministically until libFuzzer's -rss_limit_mb aborts the campaign.
//!
//! This file keeps the upstream C wrapper logic (adapted from zig's
//! lib/c/malloc.zig, MIT licensed) but backs it with a single-arena variant of
//! SmpAllocator: one set of size-class freelists behind a blocking mutex, so
//! freed slots are always found again regardless of scheduling. Fuzz targets
//! are single-threaded apart from libFuzzer's once-a-second RSS watchdog, so
//! the shared mutex is uncontended in practice.
const builtin = @import("builtin");

const std = @import("std");
const assert = std.debug.assert;
const math = std.math;
const Alignment = std.mem.Alignment;
const Allocator = std.mem.Allocator;
const PageAllocator = std.heap.PageAllocator;

comptime {
    @export(&malloc, .{ .name = "malloc" });
    @export(&aligned_alloc, .{ .name = "aligned_alloc" });
    @export(&posix_memalign, .{ .name = "posix_memalign" });
    @export(&calloc, .{ .name = "calloc" });
    @export(&realloc, .{ .name = "realloc" });
    @export(&reallocarray, .{ .name = "reallocarray" });
    @export(&free, .{ .name = "free" });
    @export(&malloc_usable_size, .{ .name = "malloc_usable_size" });
    @export(&valloc, .{ .name = "valloc" });
    @export(&memalign, .{ .name = "memalign" });
}

/// Single-arena size-class allocator. Slot layout, size classes, and the
/// large-allocation path match std.heap.SmpAllocator; the per-CPU slot
/// rotation is replaced by one mutex-protected arena.
const StableAllocator = struct {
    mutex: std.atomic.Mutex = .unlocked,
    /// For each size class, the next address to be returned when the
    /// freelist is empty.
    next_addrs: [size_class_count]usize = @splat(0),
    /// For each size class, the most recently freed slot.
    frees: [size_class_count]usize = @splat(0),

    var global: StableAllocator = .{};

    const slab_len: usize = @max(std.heap.page_size_max, 64 * 1024);
    /// Because of storing free list pointers, the minimum size class is 3.
    const min_class = math.log2(@sizeOf(usize));
    const size_class_count = math.log2(slab_len) - min_class;

    const vtable: Allocator.VTable = .{
        .alloc = alloc,
        .resize = resize,
        .remap = remap,
        .free = allocatorFree,
    };

    /// The fuzzing thread is the only frequent allocator; libFuzzer's RSS
    /// watchdog thread allocates at most a handful of times, so spinning on
    /// contention is cheaper than a full futex-based mutex.
    fn lockGlobal() void {
        while (!global.mutex.tryLock()) std.atomic.spinLoopHint();
    }

    fn alloc(context: *anyopaque, len: usize, a: Alignment, ra: usize) ?[*]u8 {
        _ = context;
        _ = ra;
        const class = sizeClassIndex(len, a);
        if (class >= size_class_count) {
            @branchHint(.unlikely);
            return PageAllocator.map(len, a);
        }

        const slot_size = slotSize(class);
        assert(slab_len % slot_size == 0);

        lockGlobal();
        defer global.mutex.unlock();

        const top_free_ptr = global.frees[class];
        if (top_free_ptr != 0) {
            @branchHint(.likely);
            const node: *usize = @ptrFromInt(top_free_ptr);
            global.frees[class] = node.*;
            return @ptrFromInt(top_free_ptr);
        }

        const next_addr = global.next_addrs[class];
        if ((next_addr % slab_len) != 0) {
            @branchHint(.likely);
            global.next_addrs[class] = next_addr + slot_size;
            return @ptrFromInt(next_addr);
        }

        // Slab alignment here ensures the % slab len earlier catches the end of slots.
        const slab = PageAllocator.map(slab_len, .fromByteUnits(slab_len)) orelse return null;
        global.next_addrs[class] = @intFromPtr(slab) + slot_size;
        return slab;
    }

    fn resize(context: *anyopaque, memory: []u8, a: Alignment, new_len: usize, ra: usize) bool {
        _ = context;
        _ = ra;
        const class = sizeClassIndex(memory.len, a);
        const new_class = sizeClassIndex(new_len, a);
        if (class >= size_class_count) {
            if (new_class < size_class_count) return false;
            return PageAllocator.realloc(memory, a, new_len, false) != null;
        }
        return new_class == class;
    }

    fn remap(context: *anyopaque, memory: []u8, a: Alignment, new_len: usize, ra: usize) ?[*]u8 {
        _ = context;
        _ = ra;
        const class = sizeClassIndex(memory.len, a);
        const new_class = sizeClassIndex(new_len, a);
        if (class >= size_class_count) {
            if (new_class < size_class_count) return null;
            return PageAllocator.realloc(memory, a, new_len, true);
        }
        return if (new_class == class) memory.ptr else null;
    }

    fn allocatorFree(context: *anyopaque, memory: []u8, a: Alignment, ra: usize) void {
        _ = context;
        _ = ra;
        const class = sizeClassIndex(memory.len, a);
        if (class >= size_class_count) {
            @branchHint(.unlikely);
            return PageAllocator.unmap(@alignCast(memory));
        }

        const node: *usize = @ptrCast(@alignCast(memory.ptr));

        lockGlobal();
        defer global.mutex.unlock();

        node.* = global.frees[class];
        global.frees[class] = @intFromPtr(node);
    }

    fn sizeClassIndex(len: usize, a: Alignment) usize {
        return @max(@bitSizeOf(usize) - @clz(len - 1), @intFromEnum(a), min_class) - min_class;
    }

    fn slotSize(class: usize) usize {
        return @as(usize, 1) << @intCast(class + min_class);
    }
};

// The remainder wraps the Zig allocator with the C API, storing alignment and
// size metadata just before the pointer returned from `malloc`.

const alignment_bytes = @max(@alignOf(std.c.max_align_t), @sizeOf(Header));
const alignment: Alignment = .fromByteUnits(alignment_bytes);

const no_context: *anyopaque = undefined;
const no_ra: usize = undefined;
const vtable = StableAllocator.vtable;

/// Needed because libc memory allocators don't provide old alignment and size
/// which are required by Zig memory allocators.
const Header = packed struct(u64) {
    alignment: Alignment,
    /// Does not include the extra alignment bytes added.
    size: Size,
    canary: Canary = magic,

    comptime {
        assert(@sizeOf(Header) <= alignment_bytes);
    }

    const safety = switch (builtin.mode) {
        .Debug, .ReleaseSafe => true,
        .ReleaseFast, .ReleaseSmall => false,
    };
    const max_addr_bits = switch (safety) {
        true => 48, // Ensures space for Canary bits.
        false => 64,
    };
    const Size = @Int(.unsigned, @min(max_addr_bits, 64 - @bitSizeOf(Alignment), @bitSizeOf(usize)));
    const Canary = @Int(.unsigned, 64 - @bitSizeOf(Alignment) - @bitSizeOf(Size));
    const magic: Canary = switch (safety) {
        true => @truncate(@as(u64, 0x76fa65bebb3d7a39)), // statically chosen entropy
        false => 0,
    };

    fn get(base: [*]align(alignment_bytes) u8) Header {
        const header: *Header = @ptrCast(base - @sizeOf(Header));
        assert(header.canary == magic);
        return header.*;
    }

    fn set(base: [*]align(alignment_bytes) u8, a: Alignment, size: Size) [*]align(alignment_bytes) u8 {
        const header: *Header = @ptrCast(base - @sizeOf(Header));
        header.* = .{ .alignment = a, .size = size };
        return base;
    }
};

fn malloc(n: usize) callconv(.c) ?[*]align(alignment_bytes) u8 {
    const size = std.math.cast(Header.Size, n) orelse return nomem();
    const ptr: [*]align(alignment_bytes) u8 = @alignCast(
        vtable.alloc(no_context, n + alignment_bytes, alignment, no_ra) orelse return nomem(),
    );
    const base = ptr + alignment_bytes;
    return Header.set(base, alignment, size);
}

fn aligned_alloc(alloc_alignment: usize, n: usize) callconv(.c) ?[*]align(alignment_bytes) u8 {
    return aligned_alloc_inner(alloc_alignment, n) orelse return nomem();
}

/// Avoids setting errno so it can be called by `posix_memalign`.
fn aligned_alloc_inner(alloc_alignment: usize, n: usize) ?[*]align(alignment_bytes) u8 {
    const size = std.math.cast(Header.Size, n) orelse return null;
    const max_align = alignment.max(.fromByteUnits(alloc_alignment));
    const max_align_bytes = max_align.toByteUnits();
    const ptr: [*]align(alignment_bytes) u8 = @alignCast(
        vtable.alloc(no_context, n + max_align_bytes, max_align, no_ra) orelse return null,
    );
    const base: [*]align(alignment_bytes) u8 = @alignCast(ptr + max_align_bytes);
    return Header.set(base, max_align, size);
}

fn calloc(elems: usize, len: usize) callconv(.c) ?[*]align(alignment_bytes) u8 {
    const n = std.math.mul(usize, elems, len) catch return nomem();
    const base = malloc(n) orelse return null;
    @memset(base[0..n], 0);
    return base;
}

fn realloc(opt_old_base: ?[*]align(alignment_bytes) u8, n: usize) callconv(.c) ?[*]align(alignment_bytes) u8 {
    if (n == 0) {
        free(opt_old_base);
        return null;
    }
    const old_base = opt_old_base orelse return malloc(n);
    const new_size = std.math.cast(Header.Size, n) orelse return nomem();
    const old_header: Header = .get(old_base);
    const old_size = old_header.size;
    const old_alignment = old_header.alignment;
    const old_alignment_bytes = old_alignment.toByteUnits();
    const old_ptr = old_base - old_alignment_bytes;
    const old_slice = old_ptr[0 .. old_size + old_alignment_bytes];
    const new_base: [*]align(alignment_bytes) u8 = if (vtable.remap(
        no_context,
        old_slice,
        old_alignment,
        n + old_alignment_bytes,
        no_ra,
    )) |new_ptr| @alignCast(new_ptr + old_alignment_bytes) else b: {
        const new_ptr: [*]align(alignment_bytes) u8 = @alignCast(
            vtable.alloc(no_context, n + old_alignment_bytes, old_alignment, no_ra) orelse
                return nomem(),
        );
        const new_base: [*]align(alignment_bytes) u8 = @alignCast(new_ptr + old_alignment_bytes);
        const copy_len = @min(new_size, old_size);
        @memcpy(new_base[0..copy_len], old_base[0..copy_len]);
        vtable.free(no_context, old_slice, old_alignment, no_ra);
        break :b new_base;
    };
    return Header.set(new_base, old_alignment, new_size);
}

fn reallocarray(opt_base: ?[*]align(alignment_bytes) u8, elems: usize, len: usize) callconv(.c) ?[*]align(alignment_bytes) u8 {
    const n = std.math.mul(usize, elems, len) catch return nomem();
    return realloc(opt_base, n);
}

fn free(opt_old_base: ?[*]align(alignment_bytes) u8) callconv(.c) void {
    const old_base = opt_old_base orelse return;
    const old_header: Header = .get(old_base);
    const old_size = old_header.size;
    const old_alignment = old_header.alignment;
    const old_alignment_bytes = old_alignment.toByteUnits();
    const old_ptr = old_base - old_alignment_bytes;
    const old_slice = old_ptr[0 .. old_size + old_alignment_bytes];
    vtable.free(no_context, old_slice, old_alignment, no_ra);
}

fn malloc_usable_size(opt_old_base: ?[*]align(alignment_bytes) u8) callconv(.c) usize {
    const old_base = opt_old_base orelse return 0;
    const old_header: Header = .get(old_base);
    const old_size = old_header.size;
    return old_size;
}

fn valloc(n: usize) callconv(.c) ?[*]align(alignment_bytes) u8 {
    return aligned_alloc(std.heap.pageSize(), n);
}

fn memalign(alloc_alignment: usize, n: usize) callconv(.c) ?[*]align(alignment_bytes) u8 {
    return aligned_alloc(alloc_alignment, n);
}

fn posix_memalign(result: *?[*]align(alignment_bytes) u8, alloc_alignment: usize, n: usize) callconv(.c) c_int {
    if (alloc_alignment < @sizeOf(*anyopaque)) return @intFromEnum(std.c.E.INVAL);
    result.* = aligned_alloc_inner(alloc_alignment, n) orelse return @intFromEnum(std.c.E.NOMEM);
    return 0;
}

/// Libc memory allocation functions must set errno in addition to returning
/// `null`.
fn nomem() ?[*]align(alignment_bytes) u8 {
    @branchHint(.cold);
    std.c._errno().* = @intFromEnum(std.c.E.NOMEM);
    return null;
}
