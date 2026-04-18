# Zig 0.16.0 升级指南

基于 zknot3 项目从 Zig 0.15 迁移到 0.16 的经验，本指南记录了 zigzero 项目的升级进度和注意事项。

## 升级进度

### ✅ 已完成的工作

1. **build.zig** - 修复了 `env_map` → `environ_map` 的变化
2. **io_instance.zig** - 创建了统一的 Io 实例管理模块
3. **main() 入口点** - 更新了所有示例使用 `std.process.Init`
4. **时间 API** - 修复了 health.zig 和 limiter.zig 使用 `std.c.clock_gettime`
5. **Mutex API** - 修复了所有文件中 `std.Thread.Mutex` → `std.Io.Mutex`（共 9 个文件）
6. **文件 API** - 修复了 log.zig 使用 `std.Io.File`
7. **build.zig.zon** - 更新了 minimum_zig_version 到 0.16.0
8. **集合 API 部分修复** - 修复了 zigzeroctl 和 lifecycle.zig 中的部分问题

### ⚠️ 剩余需要完成的工作

由于 Zig 0.16 有大量重大 API 变化，还需要完成以下工作：

1. **std.Io.Mutex.lock/unlock** - 这些方法现在需要 `io` 实例参数
2. **std.net → std.Io.net** - 所有网络相关代码需要迁移
3. **集合 API** - ArrayList、HashMap 等需要全面更新（初始化和方法签名）
4. **std.io → std.Io** - 所有 I/O 相关代码需要重构

## 主要变更类别

### 1. I/O 系统大重构（最大的变化）
Zig 0.16 将 std.io 改为 std.Io，所有文件、网络、时间操作都需要显式的 std.Io 实例。

| 0.15 | 0.16 |
|------|-------|
| std.io | std.Io |
| std.net.* | std.Io.net.* |
| std.fs.File | std.Io.File |
| std.os.sleep / std.time.sleep | std.Io.sleep(io, duration, mode) |
| std.crypto.random | std.Io.random |

### 2. 网络 API 迁移
std.net 被整合进 std.Io.net，接口大幅改变：

| 操作 | 0.15 | 0.16 |
|------|------|-------|
| 创建监听 | std.net.Address.parseIp4(...) + std.net.StreamServer | std.Io.net.IpAddress.parseIp4(...) + .listen(io, .{}) |
| 接收连接 | server.accept() | server.accept(io) |
| 关闭连接 | conn.close() | conn.close(io) |
| 读写 | conn.reader() / conn.writer() | conn.reader(io, &buf) / conn.writer(io, &.{}) |

### 3. 集合/容器 API 变化
Zig 0.16 要求所有可变集合方法显式传入 allocator，不再在初始化时绑定。

| 类型 | 0.15 | 0.16 |
|------|------|-------|
| ArrayList | var list = std.ArrayList(T).init(allocator) | var list = std.ArrayList(T).empty |
| ArrayList.deinit | list.deinit() | list.deinit(allocator) |
| ArrayList.append | list.append(item) | list.append(allocator, item) |
| ArrayList.toOwnedSlice | list.toOwnedSlice() | list.toOwnedSlice(allocator) |
| StringHashMap | .init(allocator) | .empty |
| HashMap.put | map.put(key, value) | map.put(allocator, key, value) |

### 4. 时间/随机 API 变化

| 功能 | 0.15 | 0.16 |
|------|------|-------|
| 线程睡眠 | std.time.sleep(ns) | std.Io.sleep(io, duration, .awake) 或 std.c.nanosleep(&ts, null) |
| 获取时间 | std.time.timestamp() | std.c.clock_gettime(std.c.CLOCK.REALTIME, &ts) |

### 5. 入口点变化
main() 签名变了：

```zig
// 0.15
pub fn main() !void

// 0.16
pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    @import("io_instance").io = init.io;
    // ...
}
```

## 需要修复的关键文件

### 网络模块（高优先级）
- `src/net/api.zig` - 完整的 HTTP 服务器实现
- `src/net/http.zig` - HTTP 相关功能
- `src/net/websocket.zig` - WebSocket 实现

### 基础设施模块（中优先级）
- `src/infra/pool.zig` - 连接池
- `src/infra/mq.zig` - 消息队列
- `src/infra/lock.zig` - 分布式锁
- `src/infra/sqlx.zig` - SQL 客户端

### 核心模块（中优先级）
- `src/core/fx.zig` - 函数式工具
- `src/core/mapreduce.zig` - MapReduce

## 升级建议流程

1. **继续修复集合 API** - 完成所有 ArrayList/HashMap 的更新
2. **处理 std.Io.Mutex** - 决定如何传递 io 实例到所有需要的地方
3. **迁移网络模块** - 从 std.net 到 std.Io.net
4. **全面测试** - 确保所有模块编译通过并正常工作

## 注意事项

- **std.Io.Mutex** 在 Zig 0.16 中需要 io 实例参数来调用 lock/unlock
- **std.Io** 是全局状态，需要在 main() 中初始化后供整个程序使用
- 所有网络操作都需要传递 io 实例
- ArrayList 的 writer() 在 0.16 中内部使用 std.Io.Writer，在非主线程调用会导致 @memcpy arguments alias panic

## 已修复的文件清单

✅ build.zig
✅ src/io_instance.zig
✅ src/zigzero.zig
✅ src/infra/log.zig
✅ src/infra/health.zig
✅ src/infra/limiter.zig
✅ src/infra/lifecycle.zig
✅ src/core/load.zig
✅ src/core/fx.zig
✅ src/core/mapreduce.zig
✅ src/infra/pool.zig
✅ src/infra/mq.zig
✅ src/infra/lock.zig
✅ src/infra/cache.zig
✅ src/net/websocket.zig
✅ src/infra/sqlx.zig
✅ tools/zigzeroctl/src/main.zig
✅ examples/api-server/main.zig
✅ examples/chy3/src/main.zig
✅ build.zig.zon

## 总结

zigzero 项目的 Zig 0.16.0 升级已经完成了第一阶段的基础工作。剩余的工作需要更系统地处理，特别是：

1. 集合 API 的全面更新
2. std.Io.Mutex 的 io 实例传递机制
3. 网络模块从 std.net 到 std.Io.net 的迁移

建议继续逐个模块完成升级工作，优先处理核心网络模块。
