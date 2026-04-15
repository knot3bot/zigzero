# Metrics & Observability

使用 Prometheus 指标和健康检查实现可观测性。

## 指标注册表

```zig
const zigzero = @import("zigzero");
const metric = zigzero.metric;

pub fn main() !void {
    var registry = metric.Registry.init(gpa.allocator());
    defer registry.deinit();

    // 创建指标...
}
```

## 指标类型

### Counter（计数器）

单调递增，用于请求总数、错误计数等：

```zig
const requests_total = try registry.counter(
    "http_requests_total",
    "Total number of HTTP requests",
);

pub fn handleRequest() !void {
    try requests_total.inc();
    // 或带标签
    // try requests_total.incBy(1, &.{ .{ "method", "GET" }, .{ "path", "/api/users" } });
}
```

### Gauge（仪表）

可增可减，用于当前连接数、队列深度、活跃 worker 数：

```zig
const active_connections = try registry.gauge(
    "active_connections",
    "Number of active connections",
);

// 增
try active_connections.inc();

// 减
try active_connections.dec();

// 设为具体值
try active_connections.set(42);
```

### Histogram（直方图）

用于延迟、请求大小等分布统计：

```zig
const request_duration_ms = try registry.histogram(
    "http_request_duration_ms",
    "HTTP request duration in milliseconds",
    &.{ 5, 10, 25, 50, 100, 250, 500, 1000, 2500, 5000, 10000 },
    //              ms   buckets
);

pub fn handleRequest() !void {
    const start = std.time.milliTimestamp();
    defer {
        const elapsed = std.time.milliTimestamp() - start;
        request_duration_ms.observe(@as(f64, @floatFromInt(elapsed)));
    }
    // 处理请求...
}
```

## Observability 中间件

自动记录请求计数和延迟：

```zig
try server.addMiddleware(middleware.observability(&registry));
```

自动生成以下指标：

- `http_requests_total` — 请求总数（标签：`method`, `path`, `status`）
- `http_request_duration_seconds` — 请求延迟直方图（标签：`method`, `path`）

## Prometheus 导出端点

```zig
try server.addRoute(.{
    .method = .GET,
    .path = "/metrics",
    .handler = middleware.prometheusHandler,
    .user_data = &registry,
});
```

访问 `http://localhost:8080/metrics` 查看：

```
# HELP http_requests_total Total HTTP requests
# TYPE http_requests_total counter
http_requests_total{method="GET",path="/api/users",status="200"} 1523

# HELP http_request_duration_ms HTTP request duration in ms
# TYPE http_request_duration_ms histogram
http_request_duration_ms_bucket{method="GET",path="/api/users",le="50"} 1200
http_request_duration_ms_bucket{method="GET",path="/api/users",le="100"} 1450
...
```

## 健康检查

### 注册健康检查

```zig
const health = zigzero.health;

var health_registry = health.Registry.init(gpa.allocator());
defer health_registry.deinit();

try health_registry.register("memory", health.checks.memory);
try health_registry.register("disk", health.checks.disk);
```

### 内置健康检查

| 检查 | 功能 |
|------|------|
| `health.checks.memory` | 检查内存使用率 |
| `health.checks.disk` | 检查磁盘空间 |
| `health.checks.tcp` | 检查 TCP 端口可达 |
| `health.checks.http` | 检查 HTTP 端点 |

### 自定义健康检查

```zig
try health_registry.register("database", struct {
    fn check() health.CheckResult {
        return db.ping() catch |err| {
            return .{
                .healthy = false,
                .message = @errorName(err),
            };
        };
        return .{
            .healthy = true,
            .message = "connected",
        };
    }
}.check);
```

### 健康检查端点

```zig
try server.addRoute(.{
    .method = .GET,
    .path = "/health",
    .handler = middleware.healthHandler,
    .user_data = &health_registry,
});
```

响应：

```json
// GET /health
{
  "status": "healthy",
  "checks": {
    "memory": { "healthy": true, "message": "OK" },
    "disk": { "healthy": true, "message": "OK" },
    "database": { "healthy": true, "message": "connected" }
  }
}
```

### 就绪探针 vs 存活探针

```bash
# 存活探针 (liveness) — 服务是否存活
GET /health/live
# 简单 200 OK 表示进程存活

# 就绪探针 (readiness) — 服务是否可接收流量
GET /health/ready
# 只有所有依赖都就绪才返回 200
```

## 自定义业务指标

### 业务计数器

```zig
const user_registrations = try registry.counter(
    "user_registrations_total",
    "Total user registrations",
);

const transaction_volume = try registry.counter(
    "transaction_volume_usd_total",
    "Total transaction volume in USD",
);

pub fn handleRegister(ctx: *api.Context) !void {
    try ctx.bindJson(CreateUserReq);
    try user_registrations.inc();
    try ctx.jsonStruct(201, .{ .status = "created" });
}
```

### 带标签的指标

```zig
const orders_by_status = try registry.counter(
    "orders_total",
    "Total orders by status",
);

pub fn handleOrder(ctx: *api.Context) !void {
    const order = try ctx.bindJson(OrderReq);
    try orders_by_status.incWithLabels(&.{
        .{ "status", order.status },
        .{ "payment_method", order.payment_method },
    });
}
```

### 仪表类指标

```zig
const queue_depth = try registry.gauge(
    "job_queue_depth",
    "Current job queue depth",
);

const active_worlds = try registry.gauge(
    "chy3_active_worlds",
    "Active metaverse worlds",
);
```

## Prometheus 抓取配置

```yaml
# prometheus.yml
scrape_configs:
  - job_name: 'my-service'
    static_configs:
      - targets: ['localhost:8080']
    metrics_path: /metrics
    scrape_interval: 15s
```

## Grafana 仪表板建议

| 面板 | 指标 |
|------|------|
| 请求 QPS | `rate(http_requests_total[5m])` |
| P99 延迟 | `histogram_quantile(0.99, http_request_duration_ms)` |
| 错误率 | `rate(http_requests_total{status=~"5.."}[5m])` |
| 活跃连接 | `active_connections` |
| 队列深度 | `job_queue_depth` |

## 结构化日志

除了指标，日志也是可观测性的重要组成：

```zig
const logger = log.Logger.new(.info, "my-service");

logger.info("Request processed", .{
    .request_id = req_id,
    .method = @tagName(ctx.method),
    .path = ctx.path,
    .status = status_code,
    .duration_ms = elapsed,
});
```

## 下一步

- [Rate Limiting](rate-limiting.md) — 速率限制配置
- [Circuit Breaker](circuit-breaker.md) — 熔断器模式
- [Graceful Shutdown](graceful-shutdown.md) — 健康检查与关闭集成
