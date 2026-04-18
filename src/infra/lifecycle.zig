//! Lifecycle management for zigzero
//!
//! Provides graceful shutdown, signal handling, and application lifecycle hooks.

const std = @import("std");
const io_instance = @import("../io_instance.zig");

/// Lifecycle manager for graceful application shutdown
pub const Manager = struct {
    allocator: std.mem.Allocator,
    running: std.atomic.Value(bool),
    shutdown_hooks: std.ArrayList(ShutdownHook),
    mutex: std.Io.Mutex,

    const ShutdownHook = struct {
        name: []const u8,
        callback: *const fn (*anyopaque) void,
        context: *anyopaque,
    };

    pub fn init(allocator: std.mem.Allocator) Manager {
        return .{
            .allocator = allocator,
            .running = std.atomic.Value(bool).init(true),
            .shutdown_hooks = .empty,
            .mutex = std.Io.Mutex.init,
        };
    }

    pub fn deinit(self: *Manager) void {
        self.mutex.lockUncancelable(io_instance.io);
        defer self.mutex.unlock(io_instance.io);
        self.shutdown_hooks.deinit(self.allocator);
    }

    /// Register a shutdown hook
    pub fn onShutdown(self: *Manager, name: []const u8, callback: *const fn (*anyopaque) void, context: *anyopaque) !void {
        self.mutex.lockUncancelable(io_instance.io);
        defer self.mutex.unlock(io_instance.io);
        try self.shutdown_hooks.append(self.allocator, .{
            .name = name,
            .callback = callback,
            .context = context,
        });
    }

    /// Register signal handlers and block until shutdown
    pub fn run(self: *Manager) void {
        // Note: In a real implementation, we'd use std.os.sigaction
        // For cross-platform compatibility, this is a simplified version
        while (self.running.load(.monotonic)) {
            std.Thread.yield() catch {};
        }
        self.executeShutdown();
    }

    /// Trigger shutdown
    pub fn shutdown(self: *Manager) void {
        self.running.store(false, .monotonic);
    }

    /// Check if application is running
    pub fn isRunning(self: *Manager) bool {
        return self.running.load(.monotonic);
    }

    /// Execute all shutdown hooks in LIFO order
    fn executeShutdown(self: *Manager) void {
        self.mutex.lockUncancelable(io_instance.io);
        defer self.mutex.unlock(io_instance.io);

        var i: usize = self.shutdown_hooks.items.len;
        while (i > 0) {
            i -= 1;
            const hook = self.shutdown_hooks.items[i];
            hook.callback(hook.context);
        }
    }

    /// Wait for a condition with periodic running checks
    pub fn wait(self: *Manager, interval_ms: u64) void {
        const end = io_instance.millis() + @as(i64, @intCast(interval_ms));
        while (self.running.load(.monotonic) and io_instance.millis() < end) {
            std.Thread.yield() catch {};
        }
    }
};

/// Server wrapper that supports graceful shutdown
pub fn Server(comptime T: type) type {
    return struct {
        const Self = @This();

        server: *T,
        manager: *Manager,
        shutdown_timeout_ms: u32 = 10000,

        pub fn init(server: *T, manager: *Manager) Self {
            return .{
                .server = server,
                .manager = manager,
            };
        }

        pub fn register(self: *Self) !void {
            try self.manager.onShutdown("server", struct {
                fn callback(ctx: *anyopaque) void {
                    const s = @as(*T, @ptrCast(@alignCast(ctx)));
                    s.stop();
                }
            }.callback, self.server);
        }

        pub fn start(self: *Self) !void {
            try self.server.start();
            self.manager.run();
        }
    };
}

test "lifecycle manager" {
    var manager = Manager.init(std.testing.allocator);
    defer manager.deinit();

    var called = false;
    const hook = struct {
        fn callback(ctx: *anyopaque) void {
            const c = @as(*bool, @ptrCast(@alignCast(ctx)));
            c.* = true;
        }
    }.callback;

    try manager.onShutdown("test", hook, &called);
    manager.shutdown();
    manager.executeShutdown();

    try std.testing.expect(called);
}
