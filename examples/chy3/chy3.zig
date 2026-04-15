// \! chy3 — Creator Metaverse: Narrative-Driven Creative Monetization Platform
// !
// ! Demonstrates ZigZero across three business domains:
// ! 1. 问题域 (Problem Domain) — Creator pain point discovery
// ! 2. 解决域 (Solution Domain) — Asset minting, marketplace, royalties
// ! 3. 世界域 (World Domain) — Persistent narrative worlds with NPCs, quests
// !
// ! Run:  cd examples/chy3 && zig build run

const std = @import("std");
const zigzero = @import("zigzero");
const api = zigzero.api;
const log = zigzero.log;
const middleware = zigzero.middleware;
const metric = zigzero.metric;
const lifecycle = zigzero.lifecycle;
const health = zigzero.health;
const limiter = zigzero.limiter;
const breaker = zigzero.breaker;
const load = zigzero.load;
const mq = zigzero.mq;

// Request / Response Types

const ProblemSubmitReq = struct {
    creator_id: []const u8,
    category: []const u8,
    description: []const u8,
    severity: u8,
};

const MintAssetReq = struct {
    creator_id: []const u8,
    asset_type: []const u8,
    metadata: []const u8,
    price: ?u64 = null,
};

const SubscribeReq = struct {
    subscriber_id: []const u8,
    creator_id: []const u8,
    tier: []const u8,
};

const CreateWorldReq = struct {
    creator_id: []const u8,
    name: []const u8,
    genre: []const u8,
    is_public: bool = true,
};

const SpawnNPCReq = struct {
    world_id: []const u8,
    npc_type: []const u8,
    personality: []const u8,
    lore: ?[]const u8 = null,
};

const TriggerEventReq = struct {
    world_id: []const u8,
    event_type: []const u8,
    magnitude: u8 = 5,
};

const IssueQuestReq = struct {
    world_id: []const u8,
    quest_name: []const u8,
    reward_amount: u64,
    difficulty: u8,
};

// Global counters (in-memory state)
var problem_count: u64 = 0;
var asset_count: u64 = 0;
var world_count: u64 = 0;
var npc_count: u64 = 0;
var quest_count: u64 = 0;

// Domain 1: 问题域 — Problem Domain
fn handleSubmitPainPoint(ctx: *api.Context) !void {
    const req = try ctx.bindJson(ProblemSubmitReq);
    problem_count += 1;
    const pid = try std.fmt.allocPrint(ctx.allocator, "p{d}", .{problem_count});
    defer ctx.allocator.free(pid);
    const insight: []const u8 = switch (req.category[0]) {
        'm' => "Clusters with 847 monetization pain points",
        'd' => "Discovery gap: 94% of creators struggle here",
        'i' => "IP protection concern — on-chain rights registry recommended",
        'c' => "Collaboration friction — async workflows can help",
        else => "General tooling friction point",
    };
    try ctx.jsonStruct(200, .{
        .problem_id = pid,
        .category = req.category,
        .ai_insight = insight,
        .total_pain_points = problem_count,
    });
}

fn handleGetHeatmap(ctx: *api.Context) !void {
    try ctx.jsonStruct(200, .{
        .heatmap = &.{
            .{ .category = "monetization", .score = 92, .count = 12847 },
            .{ .category = "discovery", .score = 87, .count = 9432 },
            .{ .category = "ip_protection", .score = 78, .count = 7234 },
            .{ .category = "collaboration", .score = 65, .count = 5102 },
            .{ .category = "tooling", .score = 54, .count = 3891 },
            .{ .category = "distribution", .score = 48, .count = 2934 },
            .{ .category = "analytics", .score = 41, .count = 2103 },
        },
    });
}

// Domain 2: 解决域 — Solution Domain
fn handleMintAsset(ctx: *api.Context) !void {
    const req = try ctx.bindJson(MintAssetReq);
    asset_count += 1;
    const asset_id = try std.fmt.allocPrint(ctx.allocator, "asset_{s}_{d}", .{ req.creator_id, asset_count });
    defer ctx.allocator.free(asset_id);
    try ctx.jsonStruct(200, .{
        .asset_id = asset_id,
        .asset_type = req.asset_type,
        .status = "minted",
        .ipfs_cid = "QmTzQ1JRkWErjk39mryYw2WVaphAZNAREyMchXzYQ7c15n",
        .royalty_bps = 750,
        .blockchain = "ethereum",
    });
}

fn handleListMarketplace(ctx: *api.Context) !void {
    try ctx.jsonStruct(200, .{
        .assets = &.{
            .{ .id = "a001", .asset_type = "image", .creator = "alice", .price = 299, .currency = "USD" },
            .{ .id = "a002", .asset_type = "music", .creator = "bob", .price = 499, .currency = "USD" },
            .{ .id = "a003", .asset_type = "3d_model", .creator = "carol", .price = 999, .currency = "USD" },
            .{ .id = "a004", .asset_type = "narrative", .creator = "dave", .price = 149, .currency = "USD" },
            .{ .id = "a005", .asset_type = "world_template", .creator = "eve", .price = 1999, .currency = "USD" },
        },
        .total = 5,
        .page = 1,
    });
}

fn handleSubscribe(ctx: *api.Context) !void {
    const req = try ctx.bindJson(SubscribeReq);
    _ = req;
    const sub_id = try std.fmt.allocPrint(ctx.allocator, "sub_{d}", .{std.time.timestamp()});
    defer ctx.allocator.free(sub_id);
    try ctx.jsonStruct(200, .{
        .ok = true,
        .subscription_id = sub_id,
        .next_billing = "2026-05-15",
        .access_level = "founder",
        .monthly_usd = 9,
    });
}

fn handleRoyalties(ctx: *api.Context) !void {
    try ctx.jsonStruct(200, .{
        .period = "2026-04",
        .distributions = &.{
            .{ .creator = "alice", .amount = 45230, .currency = "USD", .assets_sold = 187 },
            .{ .creator = "bob", .amount = 38910, .currency = "USD", .assets_sold = 156 },
            .{ .creator = "carol", .amount = 52100, .currency = "USD", .assets_sold = 203 },
            .{ .creator = "dave", .amount = 28440, .currency = "USD", .assets_sold = 112 },
        },
        .total_volume_usd = 164680,
    });
}

// Domain 3: 世界域 — World Domain
fn handleCreateWorld(ctx: *api.Context) !void {
    const req = try ctx.bindJson(CreateWorldReq);
    world_count += 1;
    const world_id = try std.fmt.allocPrint(ctx.allocator, "world_{s}_{d}", .{ req.name, world_count });
    defer ctx.allocator.free(world_id);
    const arc: []const u8 = switch (req.genre[0]) {
        'f' => "Chapter 1: The Iron Frontier",
        's' => "Chapter 1: Neon Requiem",
        'h' => "Chapter 1: Hallowed Grounds",
        'a' => "Chapter 1: Archipelago Awakens",
        else => "Chapter 1: The Awakening",
    };
    try ctx.jsonStruct(200, .{
        .world_id = world_id,
        .name = req.name,
        .genre = req.genre,
        .status = "active",
        .population = 0,
        .narrative_arc = arc,
        .chapter = 1,
    });
}

fn handleSpawnNPC(ctx: *api.Context) !void {
    const req = try ctx.bindJson(SpawnNPCReq);
    npc_count += 1;
    const npc_id = try std.fmt.allocPrint(ctx.allocator, "npc_{d}", .{npc_count});
    defer ctx.allocator.free(npc_id);
    const location: []const u8 = switch (req.npc_type[0]) {
        'm' => "Market Square",
        'g' => "Guild Hall",
        't' => "Tavern",
        'k' => "Keep",
        'w' => "Wandering",
        else => "Village Center",
    };
    try ctx.jsonStruct(200, .{
        .npc_id = npc_id,
        .world_id = req.world_id,
        .npc_type = req.npc_type,
        .status = "alive",
        .location = location,
        .dialogue_tree = "root_greeting",
        .ai_model = "narrative-gpt-4",
    });
}

fn handleTriggerEvent(ctx: *api.Context) !void {
    const req = try ctx.bindJson(TriggerEventReq);
    const event_id = try std.fmt.allocPrint(ctx.allocator, "evt_{d}", .{std.time.timestamp()});
    defer ctx.allocator.free(event_id);
    const branch: []const u8 = switch (req.event_type[0]) {
        'w' => "war_arc",
        'f' => "festival_arc",
        'd' => "discovery_arc",
        'c' => "conflict_arc",
        'r' => "resolution_arc",
        else => "default_arc",
    };
    try ctx.jsonStruct(200, .{
        .event_id = event_id,
        .world_id = req.world_id,
        .status = "triggered",
        .affected_npcs = 47 + @as(u64, req.magnitude) * 10,
        .narrative_branch = branch,
        .player_impact = "positive",
    });
}

fn handleIssueQuest(ctx: *api.Context) !void {
    const req = try ctx.bindJson(IssueQuestReq);
    quest_count += 1;
    const quest_id = try std.fmt.allocPrint(ctx.allocator, "quest_{d}", .{quest_count});
    defer ctx.allocator.free(quest_id);
    const difficulty_label: []const u8 = switch (req.difficulty) {
        1...3 => "easy",
        4...6 => "medium",
        7...8 => "hard",
        else => "legendary",
    };
    try ctx.jsonStruct(200, .{
        .quest_id = quest_id,
        .world_id = req.world_id,
        .quest_name = req.quest_name,
        .status = "published",
        .assigned_players = 234,
        .difficulty = difficulty_label,
        .reward_token = "CHY3",
        .reward_amount = req.reward_amount,
    });
}

fn handleWorldStats(ctx: *api.Context) !void {
    try ctx.jsonStruct(200, .{
        .active_worlds = world_count,
        .total_npcs = npc_count,
        .active_quests = quest_count,
        .narrative_events_24h = 8921,
        .realtime_players = 4823,
        .avg_world_size_mb = 128,
    });
}

// Observability
fn handleHealth(ctx: *api.Context) !void {
    try ctx.jsonStruct(200, .{
        .status = "healthy",
        .uptime_seconds = 86400,
        .version = "0.1.0",
        .domains = .{
            .problem = "operational",
            .solution = "operational",
            .world = "operational",
        },
    });
}

fn handleMetrics(ctx: *api.Context) !void {
    const registry = @as(*metric.Registry, @ptrCast(@alignCast(ctx.user_data.?)));
    var buf = std.ArrayList(u8){};
    defer buf.deinit(ctx.allocator);
    try registry.exportPrometheus(buf.writer(ctx.allocator));
    try ctx.setHeader("Content-Type", "text/plain; version=0.0.4; charset=utf-8");
    try ctx.response_body.appendSlice(ctx.allocator, buf.items);
    ctx.responded = true;
}

// Main
pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Prometheus metrics registry
    var registry = metric.Registry.init(allocator);
    defer registry.deinit();
    const http_counter = try registry.counter("chy3_http_requests_total", "Total HTTP requests");
    const worlds_gauge = try registry.gauge("chy3_active_worlds", "Active metaverse worlds");
    const npcs_gauge = try registry.gauge("chy3_total_npcs", "Total NPCs spawned");
    const hist = try registry.histogram("chy3_request_duration_ms", "Request duration in ms", &.{});
    _ = http_counter;
    _ = worlds_gauge;
    _ = npcs_gauge;
    _ = hist;

    // Health checks
    var health_registry = health.Registry.init(allocator);
    defer health_registry.deinit();
    try health_registry.register("memory", health.checks.memory);
    try health_registry.register("disk", health.checks.disk);

    // Rate limiter
    var ip_limiter = limiter.IpLimiter.init(allocator, 100.0, 10);
    defer ip_limiter.deinit();

    // Adaptive load shedder (cpu-based probabilistic drop)
    var shedder = try load.newAdaptiveShedder(allocator, .{
        .window_ms = 1000,
        .buckets = 10,
        .cpu_threshold = 80,
    });
    defer shedder.deinit();

    // Lifecycle manager
    var lc = lifecycle.Manager.init(allocator);
    defer lc.deinit();

    // Message bus for world events
    var event_bus = mq.Queue.init(allocator);
    defer event_bus.deinit();

    // HTTP server
    const logger = log.Logger.new(.info, "chy3-server");
    var server = api.Server.init(allocator, 8080, logger);
    defer server.deinit();

    // Global middleware
    try server.addMiddleware(middleware.requestId());
    try server.addMiddleware(middleware.logging());
    try server.addMiddleware(try middleware.cors(allocator, .{ .max_age = 86400 }));
    try server.addMiddleware(middleware.observability(&registry));
    try server.addMiddleware(middleware.loadShedding(&shedder));
    try server.addMiddleware(middleware.rateLimitByIp(&ip_limiter));

    // Observability routes
    try server.addRoute(.{
        .method = .GET,
        .path = "/health",
        .handler = middleware.healthHandler,
        .user_data = &health_registry,
    });
    try server.addRoute(.{
        .method = .GET,
        .path = "/metrics",
        .handler = handleMetrics,
        .user_data = &registry,
    });

    // Pre-create per-route middleware slices
    const max64k = try middleware.maxBodySize(allocator, 1024 * 64);
    const max10m = try middleware.maxBodySize(allocator, 1024 * 1024 * 10);
    const jwt_auth = try middleware.jwt(allocator, "chy3-secret-key");

    // Domain 1: 问题域
    {
        var g = server.group("/api/v1/problems");
        try server.addRoute(.{
            .method = .POST,
            .path = "/api/v1/problems/submit",
            .handler = handleSubmitPainPoint,
            .middleware = &.{max64k},
        });
        try g.get("/heatmap", handleGetHeatmap);
    }

    // Domain 2: 解决域
    {
        try server.addRoute(.{
            .method = .POST,
            .path = "/api/v1/assets/mint",
            .handler = handleMintAsset,
            .middleware = &.{ jwt_auth, max10m },
        });
    }
    {
        var g = server.group("/api/v1/marketplace");
        try g.get("/list", handleListMarketplace);
    }
    {
        try server.addRoute(.{
            .method = .POST,
            .path = "/api/v1/subscriptions/subscribe",
            .handler = handleSubscribe,
            .middleware = &.{jwt_auth},
        });
    }
    try server.addRoute(.{ .method = .GET, .path = "/api/v1/royalties", .handler = handleRoyalties });

    // Domain 3: 世界域
    {
        var g = server.group("/api/v1/worlds");
        try server.addRoute(.{
            .method = .POST,
            .path = "/api/v1/worlds/create",
            .handler = handleCreateWorld,
            .middleware = &.{jwt_auth},
        });
        try server.addRoute(.{
            .method = .POST,
            .path = "/api/v1/worlds/:world_id/npcs",
            .handler = handleSpawnNPC,
            .middleware = &.{jwt_auth},
        });
        try g.post("/:world_id/events", handleTriggerEvent);
        try server.addRoute(.{
            .method = .POST,
            .path = "/api/v1/worlds/:world_id/quests",
            .handler = handleIssueQuest,
            .middleware = &.{jwt_auth},
        });
        try g.get("/stats", handleWorldStats);
    }

    std.debug.print(
        \\
        \\chy3 — Creator Metaverse Platform
        \\============================================================
        \\  问题域 (Problem)  Pain point discovery → /api/v1/problems/*
        \\  解决域 (Solution) Creator tools      → /api/v1/assets/* /marketplace/* /subscriptions/*
        \\  世界域 (World)   Metaverse engine   → /api/v1/worlds/*
        \\  Observability                    → /health /metrics
        \\============================================================
        \\
    , .{});

    try server.start();
    lc.run();
    lc.shutdown();
}
