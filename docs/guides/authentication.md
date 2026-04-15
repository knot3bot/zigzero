# Authentication

JWT 认证、自定义 Token 生成和 Bearer Token 验证。

## JWT 中间件

验证请求中的 JWT Token：

```zig
const middleware = zigzero.middleware;

try server.addMiddleware(try middleware.jwt(allocator, "your-secret-key"));
```

默认从 `Authorization: Bearer <token>` 头读取 Token。

## 生成 JWT Token

```zig
pub fn handleLogin(ctx: *api.Context) !void {
    const req = try ctx.bindJson(LoginReq);

    // 验证用户凭证
    const user = try db.findUser(req.username, req.password) 
        orelse {
            try ctx.sendError(401, "invalid credentials");
            return;
        };

    // 生成 Token
    const token = try middleware.generateToken(ctx.allocator, .{
        .sub = user.id,
        .username = user.name,
        .role = user.role,
        .exp = std.time.timestamp() + 3600 * 24,  // 24 小时过期
    }, "your-secret-key");
    defer ctx.allocator.free(token);

    try ctx.jsonStruct(200, .{ .token = token });
}
```

## Token Claims 结构

```zig
pub const TokenClaims = struct {
    sub: []const u8,      // 用户 ID (subject)
    username: ?[]const u8 = null,
    role: ?[]const u8 = null,
    exp: i64,             // 过期时间 (Unix timestamp)
    iat: ?i64 = null,     // 签发时间
    iss: ?[]const u8 = null,  // 签发者
    aud: ?[]const u8 = null,  // 受众
};
```

## 受保护路由

```zig
// 方式 1: 全局 JWT 中间件（所有路由需要认证）
try server.addMiddleware(try middleware.jwt(allocator, "secret"));
try server.addRoute(.{
    .method = .GET,
    .path = "/api/users",
    .handler = handleListUsers,
});

// 方式 2: 路由级 JWT（仅特定路由需要认证）
try server.addRoute(.{
    .method = .POST,
    .path = "/api/users",
    .handler = handleCreateUser,
    .middleware = &.{ try middleware.jwt(allocator, "secret") },
});
```

## 从请求中获取用户信息

在处理器中获取 Token Claims：

```zig
fn handleGetProfile(ctx: *api.Context) !void {
    const claims = ctx.getJwtClaims() orelse {
        try ctx.sendError(401, "no token");
        return;
    };

    std.debug.print("User: {s} (role: {s})\n", .{
        claims.sub,
        claims.role orelse "unknown",
    });

    const user = try db.findUserById(ctx.allocator, claims.sub);
    try ctx.jsonStruct(200, user);
}
```

## 角色/权限检查

```zig
fn requireRole(role: []const u8) zigzero.api.Middleware {
    return .{
        .func = struct {
            fn exec(ctx: *api.Context, next: api.HandlerFn, _: ?*anyopaque) !void {
                const claims = ctx.getJwtClaims() orelse {
                    try ctx.sendError(401, "unauthorized");
                    return;
                };

                if (!std.mem.eql(u8, claims.role orelse "", role)) {
                    try ctx.sendError(403, "forbidden");
                    return;
                }

                try next(ctx);
            }
        }.exec,
    };
}

// 使用
try server.addRoute(.{
    .method = .DELETE,
    .path = "/api/admin/users/:id",
    .handler = handleDeleteUser,
    .middleware = &.{
        try middleware.jwt(allocator, "secret"),
        requireRole("admin"),
    },
});
```

## 刷新 Token

```zig
fn handleRefreshToken(ctx: *api.Context) !void {
    const claims = ctx.getJwtClaims() orelse {
        try ctx.sendError(401, "invalid token");
        return;
    };

    // 检查是否接近过期（提前 5 分钟刷新）
    const now = std.time.timestamp();
    if (claims.exp - now > 300) {
        try ctx.sendError(400, "token not ready for refresh");
        return;
    }

    const new_token = try middleware.generateToken(ctx.allocator, .{
        .sub = claims.sub,
        .username = claims.username,
        .role = claims.role,
        .exp = now + 3600 * 24 * 7,  // 新 Token 7 天过期
    }, "your-secret-key");
    defer ctx.allocator.free(new_token);

    try ctx.jsonStruct(200, .{ .token = new_token });
}
```

## 多种认证方式

### API Key 认证

```zig
try server.addMiddleware(.{
    .func = struct {
        fn exec(ctx: *api.Context, next: api.HandlerFn, _: ?*anyopaque) !void {
            const api_key = ctx.headers.get("X-API-Key") orelse {
                try ctx.sendError(401, "missing API key");
                return;
            };

            const valid = try db.validateApiKey(api_key);
            if (!valid) {
                try ctx.sendError(403, "invalid API key");
                return;
            }

            try next(ctx);
        }
    }.exec,
});
```

### Basic Auth

```zig
try server.addMiddleware(.{
    .func = struct {
        fn exec(ctx: *api.Context, next: api.HandlerFn, _: ?*anyopaque) !void {
            const auth = ctx.headers.get("Authorization") orelse {
                try ctx.sendError(401, "missing auth header");
                return;
            };

            if (!std.mem.startsWith(u8, auth, "Basic ")) {
                try ctx.sendError(401, "invalid auth scheme");
                return;
            }

            const encoded = auth[6..];
            const decoded = try base64Decode(ctx.allocator, encoded);
            defer ctx.allocator.free(decoded);

            const colon = std.mem.indexOfScalar(u8, decoded, ':') orelse {
                try ctx.sendError(401, "invalid credentials format");
                return;
            };
            const username = decoded[0..colon];
            const password = decoded[colon + 1..];

            const valid = try db.verifyCredentials(username, password);
            if (!valid) {
                try ctx.sendError(401, "invalid credentials");
                return;
            }

            try next(ctx);
        }
    }.exec,
});
```

## OAuth2 集成

```zig
// 1. 登录跳转
fn handleLoginRedirect(ctx: *api.Context) !void {
    const state = try generateRandomState(ctx.allocator);
    defer ctx.allocator.free(state);

    const redirect_url = try std.fmt.allocPrint(
        ctx.allocator,
        "https://oauth.provider.com/authorize?client_id=xxx&redirect_uri=...&state={s}",
        .{state},
    );
    defer ctx.allocator.free(redirect_url);

    try ctx.setHeader("Location", redirect_url);
    ctx.status_code = 302;
    ctx.responded = true;
}

// 2. OAuth 回调处理
fn handleOAuthCallback(ctx: *api.Context) !void {
    const code = ctx.queryParam("code") orelse {
        try ctx.sendError(400, "missing code");
        return;
    };
    const state = ctx.queryParam("state") orelse "";

    // 用 code 换 Access Token
    const token_resp = try oauthExchangeCode(code);
    const user_info = try oauthGetUserInfo(token_resp.access_token);

    // 签发应用自己的 JWT
    const app_token = try middleware.generateToken(ctx.allocator, .{
        .sub = user_info.id,
        .username = user_info.name,
        .role = user_info.role,
        .exp = std.time.timestamp() + 3600 * 24,
    }, "app-secret");

    try ctx.jsonStruct(200, .{ .token = app_token });
}
```

## Token 黑名单

撤销被盗用的 Token：

```zig
var token_blacklist = std.StringHashMap(i64).init(gpa.allocator());

try server.addMiddleware(.{
    .func = struct {
        fn exec(ctx: *api.Context, next: api.HandlerFn, data: ?*anyopaque) !void {
            const bl = @as(*std.StringHashMap(i64), @ptrCast(@alignCast(data.?)));
            const token = extractToken(ctx) orelse {
                try ctx.sendError(401, "no token");
                return;
            };

            // 检查是否在黑名单
            if (bl.contains(token)) {
                try ctx.sendError(401, "token revoked");
                return;
            }

            try next(ctx);
        }
    }.exec,
    .user_data = &token_blacklist,
});

// 登出时加入黑名单
fn handleLogout(ctx: *api.Context) !void {
    const token = extractToken(ctx) orelse return;
    const exp = getTokenExpiry(token);
    try token_blacklist.put(token, exp);
    try ctx.jsonStruct(200, .{ .ok = true });
}
```

## 最佳实践

| 实践 | 说明 |
|------|------|
| 使用 HTTPS | 始终通过 TLS 传输 Token |
| 短期 Token | Access Token 有效期 15min - 1h |
| Refresh Token | 长期凭证存 Redis，仅换发 Access Token |
| 密钥轮换 | 定期更换 JWT 签名密钥 |
| 记录审计 | 记录所有认证事件 |

## 下一步

- [Rate Limiting](rate-limiting.md) — 防止暴力破解
- [Middleware](middleware.md) — 组合认证中间件
- [First Service Tutorial](../getting-started/first-service.md) — 完整认证示例
