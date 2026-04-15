# Middleware

中间件是在请求到达处理器之前或之后执行的拦截器。ZigZero 提供内置中间件并支持编写自定义中间件。

## 内置中间件速查

| 中间件 | 用途 |
|--------|------|
| `requestId()` | 生成/传递请求唯一 ID (X-Request-ID header) |
| `logging()` | 结构化请求/响应日志 |
| `cors()` | CORS preflight 和响应头 |
| `jwt()` | HMAC-SHA256 JWT 验证 |
| `rateLimitByIp()` | Token bucket IP 速率限制 |
| `loadShedding()` | CPU-based 自适应负载丢弃 |
| `maxBodySize()` | 请求体大小限制 |
| `requestTimeout()` | 请求超时 |
| `cacheResponses()` | HTTP 响应缓存 |
| `observability()` | 请求计数 + 延迟直方图 |

## 使用中间件

### 全局注册

```zig
try server.addMiddleware(middleware.requestId());
try server.addMiddleware(middleware.logging());
try server.addMiddleware(try middleware.cors(allocator, .{
    .max_age = 86400,
}));
```

### 路由级注册

```zig
try server.addRoute(.{
    .method = .POST,
    .path = "/admin",
    .handler = handleAdmin,
    .middleware = &.{
        try middleware.jwt(allocator, "admin-secret"),
    },
});
```

### 组合使用

```zig
// 全局中间件 (所有路由)
try server.addMiddleware(middleware.requestId());
try server.addMiddleware(middleware.logging());

// 组级中间件 (该组下所有路由)
var g = server.group("/api/v1");
try g.withMiddleware(&.{
    try middleware.jwt(allocator, "api-secret"),
}).post("/data", handleData);

// 路由级中间件 (仅此路由)
try server.addRoute(.{
    .method = .POST,
    .path = "/api/v1/admin",
    .handler = handleAdmin,
    .middleware = &.{
        try middleware.jwt(allocator, "admin-secret"),
        try middleware.maxBodySize(allocator, 1024 * 1024 * 100),
    },
});
```

## 中间件执行顺序

```
请求 → requestId → logging → cors → rateLimit → loadShedding → observability → [路由中间件] → Handler
       ←                                                        ←
```

## 编写自定义中间件

### 函数签名

```zig
pub const Middleware = struct {
    func: MiddlewareFn,
    user_data: ?*anyopaque = null,
};

pub const MiddlewareFn = *const fn (*Context, HandlerFn, ?*anyopaque) anyerror!void;
```

### 基础示例：请求日志中间件

```zig
fn requestLoggerMw() zigzero.api.Middleware {
    return .{
        .func = struct {
            fn exec(ctx: *api.Context, next: api.HandlerFn, _: ?*anyopaque) !void {
                const start = std.time.timestamp();
                const req_id = ctx.getRequestId();

                std.debug.print(
                    "[{s}] {s} {s} started\n",
                    .{ req_id, @tagName(ctx.method), ctx.path },
                );

                try next(ctx);

                const elapsed = std.time.timestamp() - start;
                std.debug.print(
                    "[{s}] {s} {s} done in {d}s\n",
                    .{ req_id, @tagName(ctx.method), ctx.path, elapsed },
                );
            }
        }.exec,
    };
}

// 注册
try server.addMiddleware(requestLoggerMw());
```

### 带状态的中间件：IP 黑名单

```zig
const IpBlocklist = struct {
    blocked_ips: std.StringHashMap(void),

    pub fn init() IpBlocklist {
        return .{ .blocked_ips = std.StringHashMap(void).init(std.heap.page_allocator) };
    }

    pub fn block(self: *IpBlocklist, ip: []const u8) !void {
        try self.blocked_ips.put(ip, {});
    }

    pub fn middleware(self: *IpBlocklist) zigzero.api.Middleware {
        return .{
            .func = struct {
                fn exec(ctx: *api.Context, next: api.HandlerFn, data: ?*anyopaque) !void {
                    const blocklist = @as(*IpBlocklist, @ptrCast(@alignCast(data.?)));
                    const ip_str = try std.fmt.allocPrint(
                        ctx.allocator,
                        "{}",
                        .{ctx.remote_addr},
                    );
                    defer ctx.allocator.free(ip_str);

                    if (blocklist.blocked_ips.contains(ip_str)) {
                        try ctx.sendError(403, "ip blocked");
                        return;
                    }

                    try next(ctx);
                }
            }.exec,
            .user_data = self,
        };
    }
};

// 使用
var blocklist = IpBlocklist.init();
try blocklist.block("192.168.1.100");
try server.addMiddleware(blocklist.middleware());
```

### 带配置的工厂函数

```zig
fn requestValidatorMw(comptime allowed_methods: []const api.Method) zigzero.api.Middleware {
    return .{
        .func = struct {
            fn exec(ctx: *api.Context, next: api.HandlerFn, _: ?*anyopaque) !void {
                inline for (allowed_methods) |method| {
                    if (ctx.method == method) {
                        try next(ctx);
                        return;
                    }
                }
                try ctx.sendError(405, "method not allowed");
            }
        }.exec,
    };
}

// 注册
try server.addMiddleware(requestValidatorMw(&.{ .GET, .POST }));
```

### 修改响应的中间件：Gzip 压缩

```zig
fn gzipResponseMw() zigzero.api.Middleware {
    return .{
        .func = struct {
            fn exec(ctx: *api.Context, next: api.HandlerFn, _: ?*anyopaque) !void {
                try next(ctx);

                const accept_encoding = ctx.headers.get("Accept-Encoding") orelse return;
                if (!std.mem.containsAtLeast(u8, accept_encoding, 4, "gzip")) return;

                try ctx.setHeader("Content-Encoding", "gzip");
                try ctx.setHeader("Vary", "Accept-Encoding");
                // 实际压缩逻辑...
            }
        }.exec,
    };
}
```

### 异步中间件：JWT 验证 + 数据库查询

```zig
const jwtMw = try middleware.jwt(allocator, "secret");

try server.addMiddleware(.{
    .func = struct {
        fn exec(ctx: *api.Context, next: api.HandlerFn, data: ?*anyopaque) !void {
            // 验证 JWT
            const claims = try verifyJwt(ctx);

            // 从数据库查询用户权限
            const user = try db.findUserById(ctx.allocator, claims.sub);
            defer user.deinit();

            // 将用户注入 user_data
            ctx.user_data = &user;
            try next(ctx);
        }
    }.exec,
});
```

## 中间件与 User Data

通过 `.user_data` 字段传递任意数据到中间件：

```zig
try server.addRoute(.{
    .method = .GET,
    .path = "/data",
    .handler = handleData,
    .middleware = &.{myMiddleware()},
    .user_data = &my_service,  // 处理器可通过 ctx.user_data 访问
});
```

## 错误处理与中间件

```zig
try server.addMiddleware(.{
    .func = struct {
        fn exec(ctx: *api.Context, next: api.HandlerFn, _: ?*anyopaque) !void {
            next(ctx) catch |err| {
                switch (err) {
                    error.NotFound => try ctx.sendError(404, "resource not found"),
                    error.Unauthorized => try ctx.sendError(401, "unauthorized"),
                    error.PermissionDenied => try ctx.sendError(403, "permission denied"),
                    else => try ctx.sendError(500, "internal error"),
                }
            };
        }
    }.exec,
});
```

## 短路中间件

不调用 `next` 直接返回响应：

```zig
// 认证中间件
try server.addMiddleware(.{
    .func = struct {
        fn exec(ctx: *api.Context, next: api.HandlerFn, data: ?*anyopaque) !void {
            const auth_header = ctx.headers.get("Authorization") orelse {
                try ctx.sendError(401, "missing authorization header");
                return;
            };

            if (!std.mem.startsWith(u8, auth_header, "Bearer ")) {
                try ctx.sendError(401, "invalid authorization format");
                return;
            }

            try next(ctx);
        }
    }.exec,
});
```

## 路由分组与中间件继承

```zig
// 外层组
var api = server.group("/api");
try api.withMiddleware(&.{authMw}).get("/public", h1);
try api.withMiddleware(&.{authMw}).get("/private", h2);

// 内层组继承外层中间件
var v1 = api.group("/v1");
try v1.get("/resource", h3);  // 继承 /api 的中间件
```

## 下一步

- [Authentication](authentication.md) — JWT 认证实战
- [Rate Limiting](rate-limiting.md) — 速率限制模式
- [Graceful Shutdown](graceful-shutdown.md) — 生命周期管理
