//! zigzero - Io instance management for Zig 0.16+
//!
//! This module provides a global Io instance that can be shared
//! across the entire application.

const std = @import("std");

/// Global Io instance - initialized in main()
pub var io: std.Io = undefined;

/// Global allocator - initialized in main()
pub var allocator: std.mem.Allocator = undefined;

/// Get current time in milliseconds
pub fn millis() i64 {
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(std.c.CLOCK.REALTIME, &ts);
    return ts.sec * 1000 + @divTrunc(ts.nsec, 1000000);
}

/// Get current time in seconds
pub fn seconds() i64 {
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(std.c.CLOCK.REALTIME, &ts);
    return ts.sec;
}

/// Lock a mutex using the global io instance
pub fn lock(mutex: *std.Io.Mutex) void {
    mutex.lockUncancelable(io);
}

/// Unlock a mutex using the global io instance
pub fn unlock(mutex: *std.Io.Mutex) void {
    mutex.unlock(io);
}
