//! Validation utilities for zigzero
//!
//! Provides input validation aligned with go-zero's validate patterns.

const std = @import("std");
const errors = @import("errors.zig");

/// Validation result
pub const Result = struct {
    valid: bool,
    message: ?[]const u8,

    pub fn ok() Result {
        return .{ .valid = true, .message = null };
    }

    pub fn fail(msg: []const u8) Result {
        return .{ .valid = false, .message = msg };
    }
};

/// Validate that string is not empty
pub fn notEmpty(value: []const u8) Result {
    if (value.len == 0) return Result.fail("value cannot be empty");
    return Result.ok();
}

/// Validate minimum length
pub fn minLength(value: []const u8, min: usize) Result {
    if (value.len < min) return Result.fail("value too short");
    return Result.ok();
}

/// Validate maximum length
pub fn maxLength(value: []const u8, max: usize) Result {
    if (value.len > max) return Result.fail("value too long");
    return Result.ok();
}

/// Validate email format (simplified)
pub fn email(value: []const u8) Result {
    if (value.len == 0) return Result.fail("email cannot be empty");
    if (std.mem.indexOf(u8, value, "@") == null) return Result.fail("invalid email format");
    if (std.mem.indexOf(u8, value, ".") == null) return Result.fail("invalid email format");
    return Result.ok();
}

/// Validate phone number (simplified - digits only, 7-15 chars)
pub fn phone(value: []const u8) Result {
    if (value.len < 7 or value.len > 15) return Result.fail("invalid phone length");
    for (value) |c| {
        if (!std.ascii.isDigit(c) and c != '+' and c != '-') return Result.fail("invalid phone format");
    }
    return Result.ok();
}

/// Validate range for integers
pub fn range(comptime T: type, value: T, min: T, max: T) Result {
    if (value < min or value > max) return Result.fail("value out of range");
    return Result.ok();
}

/// Validate that value is in allowed set
pub fn oneOf(value: []const u8, choices: []const []const u8) Result {
    for (choices) |choice| {
        if (std.mem.eql(u8, value, choice)) return Result.ok();
    }
    return Result.fail("value not in allowed choices");
}

/// Validate UUID format
pub fn uuid(value: []const u8) Result {
    if (value.len != 36) return Result.fail("invalid UUID length");
    // Simplified check
    for (value, 0..) |c, i| {
        if (i == 8 or i == 13 or i == 18 or i == 23) {
            if (c != '-') return Result.fail("invalid UUID format");
        } else {
            if (!std.ascii.isHex(c)) return Result.fail("invalid UUID format");
        }
    }
    return Result.ok();
}

/// Validate URL format (simplified)
pub fn url(value: []const u8) Result {
    if (value.len == 0) return Result.fail("url cannot be empty");
    if (!std.mem.startsWith(u8, value, "http://") and !std.mem.startsWith(u8, value, "https://")) {
        return Result.fail("url must start with http:// or https://");
    }
    return Result.ok();
}

/// Validator that combines multiple checks
pub const Validator = struct {
    checks: []const Result,

    pub fn validate(results: []const Result) errors.Result {
        for (results) |result| {
            if (!result.valid) return error.ValidationError;
        }
        return;
    }
};

test "validation" {
    try std.testing.expect(notEmpty("hello").valid);
    try std.testing.expect(!notEmpty("").valid);

    try std.testing.expect(email("test@example.com").valid);
    try std.testing.expect(!email("invalid").valid);

    try std.testing.expect(range(u32, 5, 1, 10).valid);
    try std.testing.expect(!range(u32, 15, 1, 10).valid);

    try std.testing.expect(uuid("550e8400-e29b-41d4-a716-446655440000").valid);
    try std.testing.expect(!uuid("not-a-uuid").valid);
}
