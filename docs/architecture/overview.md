# Architecture Overview

ZigZero 的设计原则和架构层次。

## 设计原则

### 1. go-zero 兼容性

ZigZero 借鉴 [go-zero](https://github.com/zeromicro/go-zero) 的 API 设计哲学，让 Go 开发者能平滑迁移到 Zig：

```go
// go-zero (Go)
func (svc *ServiceContext) GetUser(ctx *svc.ServiceContext, in *types.GetUserRequest) (*types.User, error) {
    user, err := svc.UserModel.FindOne(ctx, in.Id)
    if err != nil {
        return nil, err
    }
    return &types.User{ Id: user.Id, Name: user.Name }, nil
}
```

```zig
// zigzero (Zig)
fn handleGetUser(ctx: *api.Context) !void {
    const req = try ctx.bindJson(GetUserReq);
    const user = try db.findUser(req.id);
    try ctx.jsonStruct(200, user);
}
```

### 2. 零成本抽象

尽可能利用 Zig 的 comptime 特性：

- `std.json.parseFromSlice` 编译时生成解析代码
- `RouteGroup` 路由路径在编译时拼接
- 泛型容器避免运行时反射开销

### 3. 纯 Zig 依赖

除了可选的数据库 C 驱动，没有任何外部依赖：

```
zigzero
├── 纯 Zig 代码（框架核心）
├── libsqlite3（可选）
├── libpq（可选）
└── libmysqlclient（可选）
```

## 四层架构

```
┌────────────────────────────────────────────────────┐
│                   接入层 (API Gateway)               │
│  HTTP Server | RouteGroup | Middleware Chain        │
├────────────────────────────────────────────────────┤
│                    服务层 (Service)                  │
│  Business Logic (Handlers / Domain)                 │
├────────────────────────────────────────────────────┤
│                 服务治理层 (Governance)              │
│  Breaker | Limiter | LoadShedder | LoadBalancer     │
├────────────────────────────────────────────────────┤
│                基础设施层 (Infrastructure)           │
│  Log | Metric | Health | Config | Lifecycle        │
│  SQLx | Redis | Cache | MQ | Cron                   │
├────────────────────────────────────────────────────┤
│                   核心层 (Core)                      │
│  Threading | FX (Stream/Parallel) | MapReduce       │
└────────────────────────────────────────────────────┘
```

## 模块关系图

```
                    ┌──────────────────────┐
                    │     API Server       │
                    │   (net/api.zig)      │
                    └──────────┬───────────┘
                               │
              ┌────────────────┼────────────────┐
              │                │                │
              ▼                ▼                ▼
    ┌─────────────────┐ ┌───────────┐ ┌──────────────┐
    │ RouteGroup      │ │Middleware │ │   Context    │
    │ (路由分组)      │ │ (拦截器)  │ │ (请求上下文)  │
    └────────┬────────┘ └─────┬─────┘ └──────────────┘
             │                 │
             │    ┌────────────┼────────────┐
             │    │            │             │
             ▼    ▼            ▼             ▼
    ┌─────────────────────────────────────────────────┐
    │              Infrastructure                     │
    │  ┌─────────┐ ┌──────────┐ ┌────────┐          │
    │  │  Log    │ │  Metric  │ │ Health │  ...      │
    │  └─────────┘ └──────────┘ └────────┘          │
    │  ┌─────────┐ ┌──────────┐ ┌────────┐          │
    │  │  SQLx   │ │  Redis   │ │ Cache  │  ...      │
    │  └─────────┘ └──────────┘ └────────┘          │
    └─────────────────────────────────────────────────┘
```

## 请求处理流程

```
HTTP Request
    │
    ▼
┌─────────────────────────┐
│ Parse Request            │ 提取 method, path, headers, body
└────────────┬────────────┘
             │
             ▼
┌─────────────────────────┐
│ Middleware Chain        │ requestId → logging → cors → rateLimit → ...
│  (按注册顺序)            │
└────────────┬────────────┘
             │ (如中间件短路，直接返回响应)
             ▼
┌─────────────────────────┐
│ Route Match             │ Trie 树匹配获取 Handler
└────────────┬────────────┘
             │
             ▼
┌─────────────────────────┐
│ Handler (业务逻辑)       │ 调用 db, redis, mq 等服务
└────────────┬────────────┘
             │
             ▼
┌─────────────────────────┐
│ Response Writer         │ JSON 序列化，写入 HTTP 响应
└─────────────────────────┘
```

## 中间件链执行

```zig
// 全局中间件 (server.addMiddleware)
// 应用于所有路由

try server.addMiddleware(mw1);  // #1
try server.addMiddleware(mw2);  // #2
try server.addMiddleware(mw3);  // #3

// 路由级中间件 (addRoute.middleware)
// 仅应用于该路由

try server.addRoute(.{ .middleware = &.{ r1, r2 } });

// 执行顺序：
// mw1 → mw2 → mw3 → r1 → r2 → Handler
//       ←                        ←
//       (逆序返回，mw3 最后设置响应头)
```

## 数据流

```
用户请求
    │
    ▼
api.Context (请求上下文)
    ├── param("id")       → 路径参数
    ├── queryParam("q")   → 查询参数
    ├── bindJson(T)       → JSON 解析
    ├── body              → 原始请求体
    ├── headers           → HTTP 头部
    ├── user_data         → 依赖注入
    │
    ▼
业务处理器 (Handler)
    │
    ├── AppContext        → 共享状态
    ├── metric.Registry    → 指标记录
    ├── 数据库/缓存/队列   → 数据操作
    │
    ▼
ctx.jsonStruct() / ctx.sendError()
    │
    ▼
HTTP 响应
```

## 内存管理模型

ZigZero 遵循 Zig 的所有权模型：

| 模式 | 使用场景 |
|------|----------|
| **所有者持有** | `Server.deinit()` 在函数退出时清理 |
| **Arena 分配** | 短生命周期数据用 `std.heap.ArenaAllocator` |
| **请求级** | 每个请求的内存通过 `ctx.allocator` 分配，请求结束释放 |
| **全局共享** | 通过指针传递，`defer` 确保清理 |

```zig
pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    var server = api.Server.init(gpa.allocator(), 8080, logger);
    defer server.deinit();  // main 退出时清理

    try server.start();
}

fn handleRequest(ctx: *api.Context) !void {
    // 请求级分配，由 ctx.allocator 管理
    const id = try std.fmt.allocPrint(ctx.allocator, "id_{d}", .{timestamp});
    defer ctx.allocator.free(id);

    try ctx.jsonStruct(200, .{ .id = id });
}
```

## 下一步

- [Module Reference](module-reference.md) — 所有模块的详细 API 文档
- [API Server Guide](../guides/api-server.md) — HTTP 服务器使用
- [First Service Tutorial](../getting-started/first-service.md) — 实践教程
