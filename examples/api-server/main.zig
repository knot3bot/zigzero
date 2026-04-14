const std = @import("std");
const zigzero = @import("zigzero");
const api = zigzero.api;
const log = zigzero.log;
const health = zigzero.health;
const middleware = zigzero.middleware;
const metric = zigzero.metric;
const load = zigzero.load;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Initialize logger
    log.initFromConfig(.{
        .service_name = "api-server",
        .level = "info",
    });
    const logger = log.Logger.new(.info, "api-server");

    // Create metrics registry
    var registry = metric.Registry.init(allocator);
    defer registry.deinit();

    // Create health registry
    var health_registry = health.Registry.init(allocator);
    defer health_registry.deinit();
    try health_registry.register("memory", health.checks.memory);
    try health_registry.register("disk", health.checks.disk);

    // Create adaptive load shedder
    var shedder = try load.newAdaptiveShedder(allocator, .{});
    defer shedder.deinit();

    // Create HTTP server
    var server = api.Server.init(allocator, 8080, logger);
    defer server.deinit();

    // Add global middleware
    try server.addMiddleware(middleware.requestId());
    try server.addMiddleware(try middleware.cors(allocator, .{}));
    try server.addMiddleware(middleware.logging());
    try server.addMiddleware(middleware.observability(&registry));
    try server.addMiddleware(middleware.loadShedding(&shedder));

    // Health check endpoint
    try server.addRoute(.{
        .method = .GET,
        .path = "/health",
        .handler = middleware.healthHandler,
        .user_data = &health_registry,
    });

    // Prometheus metrics endpoint
    try server.addRoute(.{
        .method = .GET,
        .path = "/metrics",
        .handler = middleware.prometheusHandler,
        .user_data = &registry,
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

    // Protected endpoint with JWT
    try server.addRoute(.{
        .method = .GET,
        .path = "/admin",
        .handler = struct {
            fn handle(ctx: *api.Context) !void {
                try ctx.jsonStruct(200, .{ .status = "admin access granted" });
            }
        }.handle,
        .middleware = &.{try middleware.jwt(allocator, "my-secret-key")},
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

                const Req = struct {
                    name: []const u8,
                    email: []const u8,
                };
                const req = std.json.parseFromSlice(Req, ctx.allocator, ctx.body.?, .{}) catch {
                    try ctx.sendError(400, "invalid json");
                    return;
                };
                defer req.deinit();

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

    logger.info("Starting API server on port 8080");
    try server.start();
}
