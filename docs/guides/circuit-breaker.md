# Circuit Breaker

断路器模式防止级联故障。当下游服务不可用时，快速失败而不是无限等待。

## 工作原理

```
正常状态 → 请求通过 → 失败计数增加
    ↓
失败次数达到阈值 → 断路器打开 → 请求立即被拒绝
    ↓
等待重置时间 → 半开状态 → 允许一个测试请求
    ↓
测试请求成功 → 断路器关闭 → 恢复正常
测试请求失败 → 断路器打开 → 重新等待
```

## 基础使用

```zig
const zigzero = @import("zigzero");
const breaker = zigzero.breaker;

pub fn main() !void {
    var cb = breaker.CircuitBreaker.new();
    defer cb.deinit();

    // 使用断路器包装可能失败的调用
    const result = try cb.execute(struct {
        fn run() !ExternalResponse {
            return try callExternalService();
        }
    }.run);
}
```

## 配置参数

```zig
var cb = breaker.CircuitBreaker.newWithOptions(.{
    .failure_threshold = 5,      // 5 次失败后打开
    .success_threshold = 2,       // 2 次成功后关闭
    .timeout_ms = 30_000,        // 30 秒后半开
});
```

| 参数 | 默认值 | 说明 |
|------|--------|------|
| `failure_threshold` | 5 | 打开断路器的连续失败次数 |
| `success_threshold` | 2 | 关闭断路器的连续成功次数 |
| `timeout_ms` | 30_000 | 半开状态持续时间（毫秒） |

## HTTP 客户端集成

保护对外部 API 的调用：

```zig
const http = zigzero.http;

var http_client = http.Client.init(gpa.allocator(), .{
    .timeout_ms = 5000,
});

var cb = breaker.CircuitBreaker.new();
defer cb.deinit();

try server.addRoute(.{
    .method = .GET,
    .path = "/proxy/:service",
    .handler = struct {
        fn handle(ctx: *api.Context) !void {
            const service = ctx.param("service") orelse return error.BadRequest;
            const target_url = try std.fmt.allocPrint(
                ctx.allocator,
                "https://{s}.api.example.com/data",
                .{service},
            );
            defer ctx.allocator.free(target_url);

            var resp = cb.execute(struct {
                fn run() !http.Response {
                    return http_client.get(target_url);
                }
            }.run) catch |err| {
                // 断路器打开或请求失败
                try ctx.sendError(503, "service temporarily unavailable");
                return;
            };
            defer resp.deinit();

            try ctx.setHeader("Content-Type", "application/json");
            try ctx.json(200, resp.body);
        }
    }.handle,
    .user_data = &http_client,
});
```

## 数据库调用保护

```zig
var db_cb = breaker.CircuitBreaker.newWithOptions(.{
    .failure_threshold = 3,
    .timeout_ms = 10_000,
});

pub fn queryWithProtection(query: []const u8) ![]const u8 {
    return db_cb.execute(struct {
        fn run() ![]const u8 {
            return try db.query(query);
        }
    }.run) catch |err| {
        if (cb.isOpen()) {
            std.debug.print("Circuit open - DB call skipped\n", .{});
            return error.CircuitOpen;
        }
        return err;
    };
}
```

## 与重试结合

断路器 + 指数退避重试 = 最佳实践：

```zig
const retry = zigzero.retry;

pub fn callWithRetry(url: []const u8) !http.Response {
    return retry.withBackoff(gpa.allocator(), struct {
        fn attempt() !http.Response {
            return cb.execute(struct {
                fn run() !http.Response {
                    return try http_client.get(url);
                }
            }.run);
        }
    }.attempt, .{
        .max_attempts = 3,
        .base_delay_ms = 100,
        .max_delay_ms = 2000,
        .jitter = true,
    });
}
```

执行顺序：`attempt` → `CircuitBreaker` → `HTTP 请求`：
1. 失败 → 退避重试
2. 连续失败达到阈值 → 断路器打开
3. 打开期间 → 所有请求立即返回 `error.CircuitOpen`
4. 超时后 → 半开 → 允许一个请求测试
5. 成功 → 断路器关闭

## 状态监控

```zig
// 获取当前状态
const state = cb.getState();
switch (state) {
    .closed => std.debug.print("Circuit: CLOSED (normal)\n", .{}),
    .open => std.debug.print("Circuit: OPEN (failing fast)\n", .{}),
    .half_open => std.debug.print("Circuit: HALF-OPEN (testing)\n", .{}),
}

// 获取统计数据
const stats = cb.getStats();
std.debug.print(
    "Circuit stats: failures={d}, successes={d}, rejects={d}\n",
    .{ stats.failures, stats.successes, stats.rejects },
);
```

## Prometheus 指标

```zig
const cb_state = try registry.gauge(
    "circuit_breaker_state",
    "Circuit breaker state (0=closed, 1=open, 2=half-open)",
);

pub fn recordCircuitState(cb: *breaker.CircuitBreaker) !void {
    const state = cb.getState();
    const value: f64 = switch (state) {
        .closed => 0,
        .open => 1,
        .half_open => 2,
    };
    try cb_state.set(value);
}
```

## 服务降级

断路器打开时返回降级响应：

```zig
pub fn callWithFallback(url: []const u8) !FallbackResponse {
    return cb.executeWithFallback(struct {
        fn run() !ServiceResponse {
            return try realService.call(url);
        }

        fn fallback() !FallbackResponse {
            // 降级逻辑
            return .{
                .data = getCachedData() orelse .{},
                .source = "fallback",
                .stale = true,
            };
        }
    }.run, struct {
        fn fb(_: anyerror) !FallbackResponse {
            return .{
                .data = getCachedData() orelse .{},
                .source = "fallback",
                .stale = true,
            };
        }
    }.fb);
}
```

## 手动控制

```zig
// 强制打开
cb.forceOpen();

// 强制关闭
cb.forceClose();

// 重置统计
cb.reset();

// 穿透（忽略断路器，用于管理操作）
const result = try cb.executeWithPassThrough(expensiveAdminCall);
```

## 最佳实践

### 1. 细粒度断路器

每个外部依赖独立的断路器：

```zig
var user_service_cb = breaker.CircuitBreaker.new();
var payment_service_cb = breaker.CircuitBreaker.new();
var notification_service_cb = breaker.CircuitBreaker.new();
```

### 2. 合理的超时

```zig
var cb = breaker.CircuitBreaker.newWithOptions(.{
    .failure_threshold = 5,
    .success_threshold = 2,
    .timeout_ms = 30_000,  // 不要太长
});
```

### 3. 监控断路器状态

```bash
# 告警规则
ALERT CircuitBreakerOpen
  IF circuit_breaker_state == 1
  FOR 1m
  LABELS { severity = "critical" }
  ANNOTATIONS {
    summary = "Circuit breaker is open for {{ $labels.service }}"
  }
```

## 下一步

- [Rate Limiting](rate-limiting.md) — 速率限制
- [Metrics & Observability](metrics.md) — 断路器监控
- [Graceful Shutdown](graceful-shutdown.md) — 断路器与关闭集成
