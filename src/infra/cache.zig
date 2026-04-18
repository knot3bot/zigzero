//! Local cache for zigzero
//!
//! Provides in-memory LRU cache aligned with go-zero's cache patterns.

const std = @import("std");
const io_instance = @import("../io_instance.zig");

pub fn Cache(comptime K: type, comptime V: type) type {
    return struct {
        const Self = @This();
        const Entry = struct {
            key: K,
            value: V,
            expires_at: ?i64,
        };

        allocator: std.mem.Allocator,
        map: std.AutoHashMap(K, Entry),
        max_size: usize,
        mutex: std.Io.Mutex,

        pub fn init(allocator: std.mem.Allocator, max_size: usize) Self {
            return .{
                .allocator = allocator,
                .map = std.AutoHashMap(K, Entry).init(allocator),
                .max_size = max_size,
                .mutex = std.Io.Mutex.init,
            };
        }

        pub fn deinit(self: *Self) void {
            self.map.deinit();
        }

        /// Get value from cache
        pub fn get(self: *Self, key: K) ?V {
            self.mutex.lockUncancelable(io_instance.io);
            defer self.mutex.unlock(io_instance.io);

            const entry = self.map.get(key) orelse return null;

            if (entry.expires_at) |expires| {
                if (io_instance.millis() > expires) {
                    _ = self.map.remove(key);
                    return null;
                }
            }

            return entry.value;
        }

        /// Set value in cache with optional TTL
        pub fn set(self: *Self, key: K, value: V, ttl_ms: ?i64) !void {
            self.mutex.lockUncancelable(io_instance.io);
            defer self.mutex.unlock(io_instance.io);

            const expires_at = if (ttl_ms) |ttl| io_instance.millis() + ttl else null;

            // Simple eviction if at capacity
            if (self.map.count() >= self.max_size and !self.map.contains(key)) {
                var iter = self.map.keyIterator();
                if (iter.next()) |first_key| {
                    _ = self.map.remove(first_key.*);
                }
            }

            try self.map.put(key, .{
                .key = key,
                .value = value,
                .expires_at = expires_at,
            });
        }

        /// Delete key from cache
        pub fn delete(self: *Self, key: K) void {
            self.mutex.lockUncancelable(io_instance.io);
            defer self.mutex.unlock(io_instance.io);
            self.map.remove(key);
        }

        /// Clear all cache entries
        pub fn clear(self: *Self) void {
            self.mutex.lockUncancelable(io_instance.io);
            defer self.mutex.unlock(io_instance.io);
            self.map.clearRetainingCapacity();
        }

        /// Current cache size
        pub fn size(self: *Self) usize {
            self.mutex.lockUncancelable(io_instance.io);
            const s = self.map.count();
            self.mutex.unlock(io_instance.io);
            return s;
        }
    };
}

test "cache basic" {
    var cache = Cache(u32, []const u8).init(std.testing.allocator, 10);
    defer cache.deinit();

    try cache.set(1, "hello", null);
    try std.testing.expectEqualStrings("hello", cache.get(1).?);

    cache.delete(1);
    try std.testing.expect(cache.get(1) == null);
}

test "cache ttl" {
    var cache = Cache(u32, []const u8).init(std.testing.allocator, 10);
    defer cache.deinit();

    try cache.set(1, "hello", 1);
    try std.testing.expectEqualStrings("hello", cache.get(1).?);

    std.Thread.yield() catch {};
    try std.testing.expect(cache.get(1) == null);
}
