//! MapReduce utilities for zigzero
//!
//! Aligned with go-zero's core/mr package.

const std = @import("std");
const io_instance = @import("../io_instance.zig");
const errors = @import("errors.zig");
const threading = @import("threading.zig");

/// MapReduce result with source index preservation
pub fn MapReduce(comptime In: type, comptime Out: type) type {
    return struct {
        allocator: std.mem.Allocator,
        max_workers: usize,

        const Self = @This();

        pub fn init(allocator: std.mem.Allocator, max_workers: usize) Self {
            return .{
                .allocator = allocator,
                .max_workers = max_workers,
            };
        }

        /// Map a function over items concurrently, preserving order.
        pub fn map(self: Self, items: []const In, mapper: *const fn (In) Out) ![]Out {
            if (items.len == 0) return &[0]Out{};

            const workers = if (self.max_workers == 0) items.len else @min(self.max_workers, items.len);
            const results = try self.allocator.alloc(Out, items.len);
            errdefer self.allocator.free(results);

            var active = std.atomic.Value(usize).init(0);
            var completed = std.atomic.Value(usize).init(0);
            var mutex = std.Io.Mutex.init;
            var map_err: ?anyerror = null;

            for (items, 0..) |item, idx| {
                while (active.load(.monotonic) >= workers) {
                    std.Thread.yield() catch {};
                }
                _ = @atomicRmw(usize, &active.raw, .Add, 1, .monotonic);
                const thread = try std.Thread.spawn(.{}, struct {
                    fn run(i: In, index: usize, f: *const fn (In) Out, res: []Out, a: *std.atomic.Value(usize), c: *std.atomic.Value(usize), m: *std.Io.Mutex, e: *?anyerror) void {
                        defer {
                            _ = @atomicRmw(usize, &a.raw, .Sub, 1, .monotonic);
                            _ = @atomicRmw(usize, &c.raw, .Add, 1, .monotonic);
                        }
                        const out = f(i);
                        m.lock(io_instance.io) catch {};
                        if (e.* == null) {
                            res[index] = out;
                        }
                        m.unlock(io_instance.io);
                    }
                }.run, .{ item, idx, mapper, results, &active, &completed, &mutex, &map_err });
                thread.detach();
            }

            while (completed.load(.monotonic) < items.len) {
                std.Thread.yield() catch {};
            }
            if (map_err) |e| return e;
            return results;
        }

        /// Reduce a slice of items to a single value concurrently using a combiner.
        /// The combiner must be associative for correct parallel behavior.
        pub fn reduce(self: Self, items: []const Out, initial: Out, combiner: *const fn (Out, Out) Out) !Out {
            if (items.len == 0) return initial;

            const workers = if (self.max_workers == 0) items.len else @min(self.max_workers, items.len);
            const chunk_results = try self.allocator.alloc(Out, workers);
            defer self.allocator.free(chunk_results);

            // Calculate chunk sizes so all items are covered
            const base_size = items.len / workers;
            const remainder = items.len % workers;

            var active = std.atomic.Value(usize).init(0);
            var completed = std.atomic.Value(usize).init(0);

            var start: usize = 0;
            for (0..workers) |worker_idx| {
                const extra: usize = if (worker_idx < remainder) 1 else 0;
                const end = start + base_size + extra;

                while (active.load(.monotonic) >= workers) {
                    std.Thread.yield() catch {};
                }
                _ = @atomicRmw(usize, &active.raw, .Add, 1, .monotonic);
                const thread = try std.Thread.spawn(.{}, struct {
                    fn run(s: usize, e: usize, arr: []const Out, initial_val: Out, f: *const fn (Out, Out) Out, res: []Out, idx: usize, a: *std.atomic.Value(usize), c: *std.atomic.Value(usize)) void {
                        defer {
                            _ = @atomicRmw(usize, &a.raw, .Sub, 1, .monotonic);
                            _ = @atomicRmw(usize, &c.raw, .Add, 1, .monotonic);
                        }
                        var acc = initial_val;
                        for (arr[s..e]) |item| {
                            acc = f(acc, item);
                        }
                        res[idx] = acc;
                    }
                }.run, .{ start, end, items, initial, combiner, chunk_results, worker_idx, &active, &completed });
                thread.detach();
                start = end;
            }

            while (completed.load(.monotonic) < workers) {
                std.Thread.yield() catch {};
            }

            var final = initial;
            for (chunk_results) |r| {
                final = combiner(final, r);
            }
            return final;
        }

        /// MapReduce: map then reduce in one pipeline.
        pub fn mapReduce(self: Self, items: []const In, mapper: *const fn (In) Out, initial: Out, combiner: *const fn (Out, Out) Out) !Out {
            const mapped = try self.map(items, mapper);
            defer self.allocator.free(mapped);
            return self.reduce(mapped, initial, combiner);
        }

        /// Parallel for-each with void return.
        pub fn forAll(self: Self, items: []const In, worker: *const fn (In) void) !void {
            if (items.len == 0) return;
            const workers = if (self.max_workers == 0) items.len else @min(self.max_workers, items.len);

            var active = std.atomic.Value(usize).init(0);
            var completed = std.atomic.Value(usize).init(0);

            for (items) |item| {
                while (active.load(.monotonic) >= workers) {
                    std.Thread.yield() catch {};
                }
                _ = @atomicRmw(usize, &active.raw, .Add, 1, .monotonic);
                const thread = try std.Thread.spawn(.{}, struct {
                    fn run(i: In, f: *const fn (In) void, a: *std.atomic.Value(usize), c: *std.atomic.Value(usize)) void {
                        defer {
                            _ = @atomicRmw(usize, &a.raw, .Sub, 1, .monotonic);
                            _ = @atomicRmw(usize, &c.raw, .Add, 1, .monotonic);
                        }
                        f(i);
                    }
                }.run, .{ item, worker, &active, &completed });
                thread.detach();
            }

            while (completed.load(.monotonic) < items.len) {
                std.Thread.yield() catch {};
            }
        }
    };
}

test "mapreduce map" {
    const allocator = std.testing.allocator;
    const items = &[_]u32{ 1, 2, 3, 4, 5 };

    const mr = MapReduce(u32, u32).init(allocator, 2);
    const out = try mr.map(items, struct {
        fn f(x: u32) u32 {
            return x * x;
        }
    }.f);
    defer allocator.free(out);

    try std.testing.expectEqual(@as(u32, 1), out[0]);
    try std.testing.expectEqual(@as(u32, 4), out[1]);
    try std.testing.expectEqual(@as(u32, 9), out[2]);
    try std.testing.expectEqual(@as(u32, 16), out[3]);
    try std.testing.expectEqual(@as(u32, 25), out[4]);
}

test "mapreduce reduce" {
    const allocator = std.testing.allocator;
    const items = &[_]u32{ 1, 2, 3, 4, 5 };

    const mr = MapReduce(u32, u32).init(allocator, 2);
    const sum = try mr.reduce(items, 0, struct {
        fn f(a: u32, b: u32) u32 {
            return a + b;
        }
    }.f);

    try std.testing.expectEqual(@as(u32, 15), sum);
}

test "mapreduce mapreduce" {
    const allocator = std.testing.allocator;
    const items = &[_]u32{ 1, 2, 3, 4, 5 };

    const mr = MapReduce(u32, u32).init(allocator, 2);
    const sum_of_squares = try mr.mapReduce(items, struct {
        fn f(x: u32) u32 {
            return x * x;
        }
    }.f, 0, struct {
        fn f(a: u32, b: u32) u32 {
            return a + b;
        }
    }.f);

    try std.testing.expectEqual(@as(u32, 55), sum_of_squares);
}
