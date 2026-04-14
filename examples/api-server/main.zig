const std = @import("std");
const zigzero = @import("zigzero");
const api = zigzero.api;
const log = zigzero.log;
const health = zigzero.health;
const middleware = zigzero.middleware;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Initialize logger
    log.initFromConfig(.{
        .service_name = "api-server",
        .level = "info",
    });

    // Create health registry
    var health_registry = health.Registry.init(allocator);
    defer health_registry.deinit();
    try health_registry.register("memory", health.checks.memory);
    try health_registry.register("disk", health.checks.disk);

    // Create HTTP server
    const logger = log.Logger.new(.info, "api-server");
    var server = api.Server.init(allocator, 8080, logger);
    defer server.deinit();

    // Add middleware
    try server.addMiddleware(middleware.requestId());
    try server.addMiddleware(middleware.cors(.{}));
    try server.addMiddleware(middleware.logging(logger));

    // Health check endpoint
    const health_ptr: *health.Registry = &health_registry;
    try server.addRoute(.{
        .method = .GET,
        .path = "/health",
        .handler = struct {
            fn handle(ctx: *api.Context) !void {
                const status = try health_ptr.overall();
                const code = switch (status) {
                    .healthy => @as(u16, 200),
                    .degraded => @as(u16, 200),
                    .unhealthy => @as(u16, 503),
                };
                try ctx.jsonStruct(code, .{
                    .status = @tagName(status),
                });
            }
        }.handle,
    });

    // Hello endpoint
    try server.addRoute(.{
        .method = .GET,
        .path = "/hello/:name",
        .handler = struct {
            fn handle(ctx: *api.Context) !void {
                const name = ctx.param("name") orelse "World";
                try ctx.jsonStruct(200, .{
                    .message = std.fmt.allocPrint(ctx.allocator, "Hello, {s}!", .{name}) catch "Hello!",
                });
            }
        }.handle,
    });

    // Echo endpoint
    try server.addRoute(.{
        .method = .POST,
        .path = "/echo",
        .handler = struct {
            fn handle(ctx: *api.Context) !void {
                if (ctx.body) |body| {
                    try ctx.json(200, body);
                } else {
                    try ctx.sendError(400, "missing body");
                }
            }
        }.handle,
    });

    // User endpoint with validation
    try server.addRoute(.{
        .method = .POST,
        .path = "/users",
        .handler = struct {
            fn handle(ctx: *api.Context) !void {
                if (ctx.body == null) {
                    try ctx.sendError(400, "missing body");
                    return;
                }

                const req = std.json.parseFromSlice(struct {
                    name: []const u8,
                    email: []const u8,
                }, ctx.allocator, ctx.body.?, .{}) catch {
                    try ctx.sendError(400, "invalid json");
                    return;
                };
                defer std.json.parseFree(struct {
                    name: []const u8,
                    email: []const u8,
                }, ctx.allocator, req);

                const name_valid = zigzero.validate.notEmpty(req.value.name);
                const email_valid = zigzero.validate.email(req.value.email);

                if (!name_valid.valid or !email_valid.valid) {
                    try ctx.sendError(400, "validation failed");
                    return;
                }

                try ctx.jsonStruct(201, .{
                    .id = 1,
                    .name = req.value.name,
                    .email = req.value.email,
                });
            }
        }.handle,
    });

    log.default().info("Starting API server on port 8080");
    try server.start();
}
