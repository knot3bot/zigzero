# Graceful Shutdown

优雅关闭确保在服务停止时完成正在处理的请求，清理资源，并正确处理系统信号。

## 核心概念

```
SIGTERM/SIGINT  →  停止接收新请求  →  等待处理中请求完成  →  执行关闭钩子  →  退出
```

## 基础实现

```zig
const zigzero = @import("zigzero");
const lifecycle = zigzero.lifecycle;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    var lc = lifecycle.Manager.init(gpa.allocator());
    defer lc.deinit();

    var server = try api.Server.init(gpa.allocator(), 8080, logger);
    defer server.deinit();

    // 添加关闭钩子
    try lc.onShutdown("close-db", struct {
        fn run(_: *anyopaque) void {
            std.debug.print("Closing database connections...\n", .{});
            db.close();
        }
    }.run, null);

    try lc.onShutdown("cleanup-tmp", struct {
        fn run(_: *anyopaque) void {
            std.debug.print("Cleaning up temp files...\n", .{});
            cleanupTmp();
        }
    }.run, null);

    try server.start();
    lc.run();     // 启动信号监听
    lc.shutdown(); // 阻塞直到所有钩子执行完毕
}
```

## 注册关闭钩子

`onShutdown(name, callback, context)`:

```zig
try lc.onShutdown("resource-name", callback, context);
```

参数：
- `name: []const u8` — 钩子名称，用于日志
- `callback: fn(*anyopaque) void` — 清理函数
- `context: ?*anyopaque` — 传递给回调的任意数据

### 带上下文的钩子

```zig
const DbPool = struct {
    connections: []Connection,
    allocator: std.mem.Allocator,

    pub fn close(self: *DbPool) void {
        for (self.connections) |conn| {
            conn.disconnect();
        }
        self.allocator.free(self.connections);
    }
};

var db_pool = DbPool{ .connections = &.{}, .allocator = allocator };

try lc.onShutdown("close-db-pool", struct {
    fn run(data: *anyopaque) void {
        const pool = @as(*DbPool, @ptrCast(@alignCast(data)));
        pool.close();
    }
}.run, &db_pool);
```

### 多个钩子执行顺序

按注册顺序逆序执行（后注册先执行）：

```
1. "cleanup-tmp"
2. "close-db-pool"
3. "close-server"
```

## 信号处理

`lifecycle.Manager` 自动处理：

| 信号 | 行为 |
|------|------|
| `SIGTERM` | 优雅关闭（默认） |
| `SIGINT` | 优雅关闭（Ctrl+C） |
| `SIGQUIT` | 强制退出 |
| `SIGKILL` | 强制退出（无法捕获） |

### 自定义信号处理

```zig
var lc = lifecycle.Manager.init(allocator);

// 启用 SIGHUP 信号处理（重新加载配置）
try lc.configure(.{ .handle_sighup = true });

try server.start();
lc.run();
lc.shutdown();
```

## 与 HTTP 服务器集成

### 标准模式

```zig
var server = try api.Server.init(allocator, 8080, logger);
defer server.deinit();

try lc.onShutdown("stop-http", struct {
    fn run(_: *anyopaque) void {
        server.stop();  // 停止接受新连接
    }
}.run, null);

try server.start();
lc.run();
lc.shutdown();
```

### 等待处理中请求

```zig
try lc.onShutdown("drain-requests", struct {
    fn run(_: *anyopaque) void {
        // 等待活跃请求计数归零
        while (active_requests.load(.monotonic) > 0) {
            std.Thread.sleep(100 * std.time.ns_per_ms);
        }
    }
}.run, null);
```

## 典型关闭钩子清单

```zig
// 1. 停止接受新请求
try lc.onShutdown("stop-accepting", struct {
    fn run(_: *anyopaque) void { listener.close(); }
}.run, null);

// 2. 等待活跃请求完成
try lc.onShutdown("drain-requests", struct {
    fn run(_: *anyopaque) void { waitForDrain(); }
}.run, null);

// 3. 关闭数据库连接
try lc.onShutdown("close-db", struct {
    fn run(_: *anyopaque) void { db.close(); }
}.run, null);

// 4. 关闭 Redis 连接
try lc.onShutdown("close-redis", struct {
    fn run(_: *anyopaque) void { redis.quit(); }
}.run, null);

// 5. 刷新日志
try lc.onShutdown("flush-logs", struct {
    fn run(_: *anyopaque) void { logger.flush(); }
}.run, null);

// 6. 上报健康检查失败
try lc.onShutdown("update-health", struct {
    fn run(_: *anyopaque) void {
        health_registry.setStatus("shutting_down");
    }
}.run, null);

// 7. 注销服务发现
try lc.onShutdown("deregister", struct {
    fn run(_: *anyopaque) void {
        etcd.deregister();
    }
}.run, null);

// 8. 持久化内存状态
try lc.onShutdown("persist-state", struct {
    fn run(_: *anyopaque) void {
        state.save("/var/lib/service/state.json");
    }
}.run, null);
```

## 关闭超时

防止关闭挂起：

```zig
try lc.configure(.{ .timeout_ms = 30_000 }); // 30 秒超时

lc.run();
lc.shutdown();
```

超时后执行强制退出：

```
1. 执行所有钩子直到超时
2. 打印未执行钩子列表
3. 调用 std.posix._exit(1)
```

## 验证关闭行为

```bash
# 启动服务
./zig-out/bin/my-service &
PID=$!

# 发送 SIGTERM
kill -TERM $PID

# 观察日志
# 应该看到所有钩子的执行日志
```

## 与 Kubernetes 集成

Kubernetes 发送 `SIGTERM` 并等待 `terminationGracePeriodSeconds`（默认 30s）。

```bash
# 确保关闭在 30 秒内完成
try lc.configure(.{ .timeout_ms = 25_000 });

# 健康检查应在收到 SIGTERM 后立即返回 unhealthy
try lc.onShutdown("fail-health", struct {
    fn run(_: *anyopaque) void {
        health_registry.setStatus("terminating");
    }
}.run, null);
```

## 调试关闭问题

```bash
# 跟踪未完成的关闭钩子
kill -USR1 $PID  # 如果实现了 USR1 信号处理器

# 强制退出（最后手段）
kill -9 $PID
```

## 下一步

- [Metrics & Observability](metrics.md) — 健康检查和 Prometheus 指标
- [Configuration](configuration.md) — 使用 YAML 配置管理服务参数
