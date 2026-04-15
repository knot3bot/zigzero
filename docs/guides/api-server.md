# HTTP API Server

完整的 HTTP 服务器 API 参考：路由、中间件、请求处理、响应构建。

## 服务器初始化

```zig
const zigzero = @import("zigzero");
const api = zigzero.api;
const log = zigzero.log;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    const logger = log.Logger.new(.info, "my-service");
    var server = api.Server.init(gpa.allocator(), 8080, logger);
    defer server.deinit();

    // 添加路由和中间件...

    try server.start();
}
```

构造函数签名：

```zig
pub fn init(allocator: std.mem.Allocator, port: u16, logger: log.Logger) Server
```

## 路由注册

### 基础路由

```zig
try server.addRoute(.{
    .method = .GET,
    .path = "/users",
    .handler = handleGetUsers,
});
```

### 路径参数

```zig
try server.addRoute(.{
    .method = .GET,
    .path = "/users/:id/posts/:post_id",
    .handler = handleGetUserPost,
});
```

在处理器中获取参数：

```zig
fn handleGetUserPost(ctx: *api.Context) !void {
    const user_id = ctx.param("id") orelse return error.MissingId;
    const post_id = ctx.param("post_id") orelse return error.MissingPostId;

    try ctx.jsonStruct(200, .{
        .user_id = user_id,
        .post_id = post_id,
    });
}
```

### 路由分组

为一组路由共享前缀：

```zig
{
    var g = server.group("/api/v1/users");
    try g.get("/:id", handleGetUser);
    try g.post("/", handleCreateUser);
    try g.put("/:id", handleUpdateUser);
    try g.delete("/:id", handleDeleteUser);
}
```

分组可以嵌套：

```zig
{
    var users = server.group("/api/v1/users");
    var admin = users.group("/admin");
    try admin.get("/stats", handleAdminStats);
}
```

### HTTP 方法

`server.addRoute()` 支持所有标准方法：

```zig
.try .GET,    .POST,    .PUT,     .DELETE,  .PATCH
```

`RouteGroup` 提供快捷方法：

```zig
try g.get("/path", handler);
try g.post("/path", handler);
try g.put("/path", handler);
try g.delete("/path", handler);
try g.patch("/path", handler);
```

## 中间件

### 全局中间件

按注册顺序执行（先注册先执行）：

```zig
try server.addMiddleware(middleware.requestId());
try server.addMiddleware(middleware.logging());
try server.addMiddleware(middleware.cors(allocator, .{}));
```

### 路由级中间件

通过 `.middleware` 字段为特定路由添加中间件：

```zig
try server.addRoute(.{
    .method = .POST,
    .path = "/api/admin/dangerous",
    .handler = handleDangerous,
    .middleware = &.{
        try middleware.jwt(allocator, "secret"),
        try middleware.rateLimitByIp(&limiter),
    },
});
```

### 可用中间件

| 中间件 | 功能 | 参数 |
|--------|------|------|
| `requestId()` | 为每个请求生成唯一 ID | 无 |
| `logging()` | 结构化请求日志 | 无 |
| `cors()` | CORS 头部处理 | `allow_origins`, `allow_methods`, `max_age` |
| `jwt()` | JWT 验证 | `secret` |
| `rateLimitByIp()` | IP 级别速率限制 | `*IpLimiter` |
| `loadShedding()` | 自适应负载丢弃 | `*AdaptiveShedder` |
| `maxBodySize()` | 请求体大小限制 | `max_bytes: usize` |
| `requestTimeout()` | 请求超时 | `timeout_ms: u64` |
| `cacheResponses()` | 响应缓存 | `*ResponseCache` |
| `observability()` | 请求计数和延迟直方图 | `*metric.Registry` |

## 请求处理

### 获取请求体

```zig
fn handleCreateUser(ctx: *api.Context) !void {
    // 绑定 JSON 到结构体
    const req = try ctx.bindJson(CreateUserReq);

    // 直接获取原始 body
    if (ctx.body) |body| {
        std.debug.print("Raw body: {s}\n", .{body});
    }
}
```

### 自定义请求绑定

`bindJson` 使用 `std.json.parse` 进行解marshaling，支持 Zig 的默认字段和内联解marshaling：

```zig
const req = try ctx.bindJson(MyStruct);
// 自动处理：
// - 可选字段 (?T)
// - 默认值 (.field = value)
// - 嵌套结构体
```

### 设置响应

```zig
// JSON 结构体 (推荐)
try ctx.jsonStruct(200, .{ .key = "value" });

// 原始 JSON
try ctx.json(200, body: []const u8);

// 错误响应
try ctx.sendError(404, "not found");

// 设置自定义头部
try ctx.setHeader("X-Request-Id", "12345");
try ctx.setHeader("Cache-Control", "max-age=3600");

// 设置响应体
try ctx.response_body.appendSlice(allocator, "Hello, World!");
ctx.responded = true;
```

### 响应构建

```zig
// 简单 JSON
try ctx.jsonStruct(200, .{ .status = "ok" });

// 带嵌套的 JSON
try ctx.jsonStruct(200, .{
    .user = .{
        .id = "123",
        .name = "Alice",
        .profile = .{
            .bio = "Developer",
            .avatar_url = "https://example.com/avatar.png",
        },
    },
    .meta = .{
        .request_id = ctx.getRequestId(),
    },
});
```

## 请求上下文

`api.Context` 提供所有请求信息：

```zig
pub const Context = struct {
    // 路径参数
    param:              fn ([]const u8) ?[]const u8,
    getRequestId:       fn () []const u8,

    // 请求信息
    method:             Method,
    path:               []const u8,
    query:             ?[]const u8,
    body:              ?[]const u8,
    remote_addr:       std.net.Address,
    headers:           std.http.Headers,

    // 响应构建
    response_body:      std.ArrayList(u8),
    responded:         bool,
    status_code:       u16,

    // 绑定与解析
    bindJson:           fn (comptime T: type) !T,
    json:              fn (status: u16, []const u8) anyerror!void,
    jsonStruct:        fn (status: u16, anytype) anyerror!void,
    sendError:         fn (status: u16, []const u8) anyerror!void,
    setHeader:         fn ([]const u8, []const u8) anyerror!void,

    // 工具
    allocator:         std.mem.Allocator,
    user_data:         ?*anyopaque,
};
```

## User Data (依赖注入)

通过 `user_data` 向处理器传递依赖：

```zig
// 在路由注册时设置
try server.addRoute(.{
    .method = .GET,
    .path = "/users",
    .handler = handleListUsers,
    .user_data = &user_repo,
});

// 在处理器中读取
fn handleListUsers(ctx: *api.Context) !void {
    const repo = @as(*UserRepository, @ptrCast(@alignCast(ctx.user_data.?)));
    const users = try repo.list(ctx.allocator);
    try ctx.jsonStruct(200, .{ .users = users });
}
```

## 错误处理

内置错误响应：

```zig
try ctx.sendError(400, "invalid request");
try ctx.sendError(401, "unauthorized");
try ctx.sendError(403, "forbidden");
try ctx.sendError(404, "not found");
try ctx.sendError(500, "internal server error");
```

返回自定义 JSON 错误：

```zig
try ctx.jsonStruct(400, .{
    .error = "validation_error",
    .message = "email field is required",
    .field = "email",
});
```

## 静态文件服务

```zig
try server.addRoute(.{
    .method = .GET,
    .path = "/static/:filename",
    .handler = static.serveHandler,
    .user_data = "/var/www/public",
});
```

## 启动选项

### Unix Socket

```zig
var server = api.Server.init(allocator, 0, logger);
try server.startOnUnixSocket("/var/run/my-service.sock");
```

### 自定义线程数

```zig
try server.startWithOptions(.{ .threads = 4 });
```

## 下一步

- [Middleware Guide](middleware.md) — 编写自定义中间件
- [Metrics & Observability](metrics.md) — Prometheus 集成
- [Rate Limiting](rate-limiting.md) — 速率限制模式
