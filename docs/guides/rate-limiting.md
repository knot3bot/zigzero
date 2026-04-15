# Rate Limiting

速率限制保护服务免受流量突刺和滥用。ZigZero 提供多种速率限制策略。

## 可用策略

| 策略 | 算法 | 适用场景 |
|------|------|----------|
| Token Bucket | 固定速率 + burst | API 限流 |
| Sliding Window | 平滑限制 | 精确限流 |
| IP Limiter | Token Bucket + IP 追踪 | 防止单个 IP 滥用 |
| Adaptive Shedder | CPU-based probabilistic drop | 高负载保护 |

## IP 级别限流

最常用的限流方式，基于客户端 IP 地址：

```zig
const zigzero = @import("zigzero");
const limiter = zigzero.limiter;
const middleware = zigzero.middleware;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    // 100 requests/second, burst of 10
    var ip_limiter = limiter.IpLimiter.init(gpa.allocator(), 100.0, 10);
    defer ip_limiter.deinit();

    var server = try api.Server.init(gpa.allocator(), 8080, logger);
    try server.addMiddleware(middleware.rateLimitByIp(&ip_limiter));

    // ...
}
```

参数：
- `rate: f64` — 每秒允许的请求数
- `burst: u32` — 允许的突发请求数

### 自定义错误响应

```zig
try server.addMiddleware(.{
    .func = struct {
        fn exec(ctx: *api.Context, next: api.HandlerFn, data: ?*anyopaque) !void {
            const limiter_inst = @as(*limiter.IpLimiter, @ptrCast(@alignCast(data.?)));
            const allowed = limiter_inst.check(ctx.remote_addr) catch false;

            if (!allowed) {
                try ctx.setHeader("Retry-After", "1");
                try ctx.jsonStruct(429, .{
                    .error = "rate_limit_exceeded",
                    .message = "Too many requests. Please slow down.",
                });
                return;
            }

            try next(ctx);
        }
    }.exec,
    .user_data = &ip_limiter,
});
```

### 不同端点不同限制

```zig
// 公开端点：宽松限制
var public_limiter = limiter.IpLimiter.init(gpa.allocator(), 50.0, 5);
try server.addRoute(.{
    .method = .GET,
    .path = "/api/public",
    .handler = handlePublic,
    .middleware = &.{ middleware.rateLimitByIp(&public_limiter) },
});

// 写操作：严格限制
var write_limiter = limiter.IpLimiter.init(gpa.allocator(), 10.0, 2);
try server.addRoute(.{
    .method = .POST,
    .path = "/api/data",
    .handler = handleWrite,
    .middleware = &.{ middleware.rateLimitByIp(&write_limiter) },
});
```

## Token Bucket 算法

手动控制令牌补充：

```zig
var bucket = limiter.TokenBucket.init(gpa.allocator(), .{
    .capacity = 100,
    .refill_rate = 10,      // 10 tokens/second
    .refill_interval = 100, // ms
});
defer bucket.deinit();

pub fn checkLimit() !void {
    const allowed = try bucket.allow();
    if (!allowed) {
        return error.RateLimited;
    }
    // 处理请求...
}
```

## 滑动窗口限流

更精确的限流，平滑突发：

```zig
var window = limiter.SlidingWindow.init(gpa.allocator(), .{
    .max_requests = 100,
    .window_size_ms = 1000,
});
defer window.deinit();

pub fn checkWindow(ctx: *api.Context) !void {
    const allowed = try window.check(ctx.allocator, ctx.remote_addr);
    if (!allowed) {
        try ctx.sendError(429, "rate limited");
        return;
    }
    try next(ctx);
}
```

## 自适应负载丢弃

当 CPU 使用率过高时，自动丢弃请求：

```zig
const load = zigzero.load;
const middleware = zigzero.middleware;

var shedder = try load.newAdaptiveShedder(gpa.allocator(), .{
    .window_ms = 1000,
    .buckets = 10,
    .cpu_threshold = 80,  // 80% CPU 时开始丢弃
});
defer shedder.deinit();

try server.addMiddleware(middleware.loadShedding(&shedder));
```

丢弃策略：
- 低于 `cpu_threshold` → 全部通过
- 达到 `cpu_threshold` → 按概率丢弃
- 超过 `cpu_threshold` + 50% → 强制丢弃

## 全局限流中间件

为整个服务设置上限：

```zig
var global_limiter = limiter.GlobalLimiter.init(gpa.allocator(), .{
    .max_concurrent = 1000,
    .max_queue = 5000,
});
defer global_limiter.deinit();
```

## 组合限流

多层防护：

```zig
// 1. 全局限流
try server.addMiddleware(middleware.loadShedding(&shedder));

// 2. IP 级别限流
try server.addMiddleware(middleware.rateLimitByIp(&ip_limiter));

// 3. 路由级别限流
try server.addRoute(.{
    .method = .POST,
    .path = "/api/upload",
    .handler = handleUpload,
    .middleware = &.{
        try middleware.maxBodySize(gpa.allocator(), 1024 * 1024 * 10),
        middleware.rateLimitByIp(&upload_limiter),
    },
});
```

## 用户级别限流

基于用户 ID 而非 IP：

```zig
var user_limiter = limiter.UserLimiter.init(gpa.allocator(), .{
    .rate = 60.0,  // 60 req/min
    .burst = 10,
});

try server.addMiddleware(.{
    .func = struct {
        fn exec(ctx: *api.Context, next: api.HandlerFn, data: ?*anyopaque) !void {
            const limiter_inst = @as(*limiter.UserLimiter, @ptrCast(@alignCast(data.?)));
            const token = try extractAuthToken(ctx);
            const allowed = try limiter_inst.check(token);

            if (!allowed) {
                try ctx.setHeader("X-RateLimit-Limit", "60");
                try ctx.setHeader("X-RateLimit-Remaining", "0");
                try ctx.sendError(429, "rate limit exceeded");
                return;
            }

            try next(ctx);
        }
    }.exec,
    .user_data = &user_limiter,
});
```

## 监控限流指标

```zig
const rate_limited = try registry.counter(
    "rate_limited_requests_total",
    "Total requests rejected by rate limiter",
    .{ .labels = &.{"reason"} },
);

pub fn handleRateLimited() !void {
    try rate_limited.incWithLabels(&.{.{ "reason", "ip" }});
    try ctx.sendError(429, "rate limited");
}
```

## Redis 分布式限流

跨多实例协调限流：

```zig
const redis = zigzero.redis;

var redis_client = try redis.Client.init(gpa.allocator(), .{
    .address = "127.0.0.1:6379",
});
defer redis_client.deinit();

pub fn checkDistributedLimit(ctx: *api.Context) !void {
    const key = try std.fmt.allocPrint(
        ctx.allocator,
        "ratelimit:ip:{s}",
        .{ctx.remote_addr},
    );
    defer ctx.allocator.free(key);

    const count = try redis_client.incr(key);
    if (count == 1) {
        try redis_client.expire(key, 1);
    }

    if (count > 100) {
        try ctx.sendError(429, "rate limited");
        return;
    }

    try next(ctx);
}
```

## 配置示例

```yaml
# config.yaml
rate_limiting:
  ip:
    rate: 100  # req/s
    burst: 10
  write:
    rate: 10
    burst: 2
  upload:
    rate: 1
    burst: 1

load_shedding:
  enabled: true
  cpu_threshold: 80
  window_ms: 1000
  buckets: 10
```

## 下一步

- [Circuit Breaker](circuit-breaker.md) — 熔断器保护外部调用
- [Metrics & Observability](metrics.md) — 限流指标监控
- [Middleware](middleware.md) — 自定义限流中间件
