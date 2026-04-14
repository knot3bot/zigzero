//! Rate limiter implementation for zigzero
//!
//! Provides token bucket and sliding window rate limiting aligned with go-zero's limit.

const std = @import("std");
const errors = @import("../core/errors.zig");

/// Rate limiter type
pub const Type = enum {
    token_bucket, // Token bucket algorithm
    sliding_window, // Sliding window algorithm
    leaky_bucket, // Leaky bucket algorithm
};

/// Rate limiter configuration
pub const Config = struct {
    /// Maximum number of requests allowed per second
    rate: f64,
    /// Burst capacity (maximum tokens/requests that can be accumulated)
    burst: u32,
    /// Type of rate limiter
    type: Type = .token_bucket,
};

/// Token bucket rate limiter
pub const TokenBucket = struct {
    rate: f64, // Tokens per second
    burst: u32, // Maximum tokens
    tokens: f64, // Current tokens
    last_update: i128, // Last update timestamp in nanoseconds

    /// Create a new token bucket
    pub fn new(rate: f64, burst: u32) TokenBucket {
        return TokenBucket{
            .rate = rate,
            .burst = burst,
            .tokens = @as(f64, @floatFromInt(burst)),
            .last_update = std.time.nanoTimestamp(),
        };
    }

    /// Try to acquire a token
    pub fn allow(self: *TokenBucket) bool {
        return self.allowN(1);
    }

    /// Try to acquire n tokens
    pub fn allowN(self: *TokenBucket, n: u32) bool {
        self.replenish();

        if (self.tokens >= @as(f64, @floatFromInt(n))) {
            self.tokens -= @as(f64, @floatFromInt(n));
            return true;
        }
        return false;
    }

    /// Replenish tokens based on elapsed time
    fn replenish(self: *TokenBucket) void {
        const now = std.time.nanoTimestamp();
        const elapsed = @as(f64, @floatFromInt(now - self.last_update)) / 1_000_000_000.0;

        self.tokens = @min(@as(f64, @floatFromInt(self.burst)), self.tokens + elapsed * self.rate);
        self.last_update = now;
    }
};

/// Sliding window rate limiter
pub const SlidingWindow = struct {
    allocator: std.mem.Allocator,
    rate: f64, // Max requests per second
    window_size_ns: i64, // Window size in nanoseconds
    requests: std.ArrayList(i64), // Timestamps of recent requests

    /// Create a new sliding window limiter
    pub fn init(allocator: std.mem.Allocator, rate: f64, window_sec: u32) !SlidingWindow {
        return SlidingWindow{
            .allocator = allocator,
            .rate = rate,
            .window_size_ns = @as(i64, @intCast(window_sec)) * 1_000_000_000,
            .requests = std.ArrayList(i64){},
        };
    }

    pub fn deinit(self: *SlidingWindow) void {
        self.requests.deinit(self.allocator);
    }

    /// Try to allow a request
    pub fn allow(self: *SlidingWindow) bool {
        const now = std.time.nanoTimestamp();
        const window_start = now - self.window_size_ns;

        // Remove expired requests
        var i: usize = 0;
        while (i < self.requests.items.len) {
            if (self.requests.items[i] <= window_start) {
                _ = self.requests.orderedRemove(i);
            } else {
                i += 1;
            }
        }

        // Check if under limit
        const count = @as(u32, @intCast(self.requests.items.len));
        if (count < @as(u32, @intFromFloat(self.rate))) {
            self.requests.append(self.allocator, now) catch return false;
            return true;
        }

        return false;
    }
};

/// IP-based rate limiter using token buckets per client
pub const IpLimiter = struct {
    allocator: std.mem.Allocator,
    rate: f64,
    burst: u32,
    buckets: std.StringHashMap(TokenBucket),
    mutex: std.Thread.Mutex,
    last_cleanup: i64,
    cleanup_interval_ms: i64,

    pub fn init(allocator: std.mem.Allocator, rate: f64, burst: u32) IpLimiter {
        return .{
            .allocator = allocator,
            .rate = rate,
            .burst = burst,
            .buckets = std.StringHashMap(TokenBucket).init(allocator),
            .mutex = .{},
            .last_cleanup = std.time.milliTimestamp(),
            .cleanup_interval_ms = 60000, // cleanup every 60s
        };
    }

    pub fn deinit(self: *IpLimiter) void {
        var iter = self.buckets.iterator();
        while (iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
        }
        self.buckets.deinit();
    }

    /// Check if request from ip is allowed
    pub fn allow(self: *IpLimiter, ip: []const u8) bool {
        self.mutex.lock();
        defer self.mutex.unlock();

        const gop = self.buckets.getOrPut(ip) catch return false;
        if (!gop.found_existing) {
            gop.key_ptr.* = self.allocator.dupe(u8, ip) catch return false;
            gop.value_ptr.* = TokenBucket.new(self.rate, self.burst);
        }

        const result = gop.value_ptr.allow();

        // Periodic cleanup of stale buckets
        const now = std.time.milliTimestamp();
        if (now - self.last_cleanup > self.cleanup_interval_ms) {
            self.last_cleanup = now;
            self.cleanupStaleBuckets();
        }

        return result;
    }

    fn cleanupStaleBuckets(self: *IpLimiter) void {
        const now = std.time.nanoTimestamp();
        var iter = self.buckets.iterator();
        var to_remove: std.ArrayList([]const u8) = .{};
        defer {
            for (to_remove.items) |k| self.allocator.free(k);
            to_remove.deinit(self.allocator);
        }

        while (iter.next()) |entry| {
            // Remove buckets that haven't been used in 5 minutes
            const elapsed = @as(f64, @floatFromInt(now - entry.value_ptr.last_update)) / 1_000_000_000.0;
            if (elapsed > 300) {
                to_remove.append(self.allocator, entry.key_ptr.*) catch {};
            }
        }

        for (to_remove.items) |k| {
            _ = self.buckets.remove(k);
        }
    }
};

/// Global rate limiter storage
var global_limiters: std.StringHashMapUnmanaged(TokenBucket) = .{};

/// Get or create a rate limiter
pub fn getLimiter(name: []const u8, config: Config) *TokenBucket {
    const gpa = std.heap.page_allocator;
    if (global_limiters.get(gpa, name)) |limiter| {
        return limiter;
    }

    const limiter = TokenBucket.new(config.rate, config.burst);
    global_limiters.put(gpa, name, limiter) catch return &global_limiters.get(gpa, name).?;
    return &global_limiters.get(gpa, name).?;
}

test "token bucket" {
    var tb = TokenBucket.new(10.0, 5);

    // Should allow initial burst
    try std.testing.expect(tb.allow());
    try std.testing.expect(tb.allow());
    try std.testing.expect(tb.allow());
    try std.testing.expect(tb.allow());
    try std.testing.expect(tb.allow());

    // Should deny when exhausted
    try std.testing.expect(!tb.allow());
}

test "ip limiter" {
    const allocator = std.testing.allocator;
    var limiter = IpLimiter.init(allocator, 2.0, 2);
    defer limiter.deinit();

    try std.testing.expect(limiter.allow("192.168.1.1"));
    try std.testing.expect(limiter.allow("192.168.1.1"));
    try std.testing.expect(!limiter.allow("192.168.1.1"));

    // Different IP should have its own bucket
    try std.testing.expect(limiter.allow("192.168.1.2"));
    try std.testing.expect(limiter.allow("192.168.1.2"));
}
