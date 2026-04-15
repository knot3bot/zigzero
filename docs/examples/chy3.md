# chy3 — Creator Metaverse Platform

完整的 ZigZero 实战案例，展示如何用 ZigZero 构建元宇宙叙事驱动的创作者变现平台。

## 业务背景

**chy3** 围绕「创作者在元宇宙中的创意变现」这一核心叙事，拆分为三个业务域：

```
问题域 (Problem Domain)  →  创作者痛点发现
    ↓
解决域 (Solution Domain)  →  创作者工具（资产铸造、市场、订阅、版权费）
    ↓
世界域 (World Domain)      →  持久叙事元宇宙引擎（世界、NPC、事件、任务）
```

## 项目结构

```
examples/chy3/
├── chy3.zig              ← 兼容层（重新导出 src.main）
└── src/
    ├── main.zig           ← 入口：生命周期、路由注册、依赖注入
    ├── context.zig        ← AppContext：共享状态 + Metric 注册表指针
    ├── types.zig          ← 所有 DTO（请求/响应结构体）
    ├── domain/
    │   ├── problem.zig    ← 问题域处理器
    │   ├── solution.zig   ← 解决域处理器
    │   └── world.zig      ← 世界域处理器
    └── infra/
        ├── metrics.zig     ← Prometheus 指标初始化
        └── middleware.zig  ← 中间件工厂函数
```

## 架构设计原则

### 1. 依赖注入

通过 `ctx.user_data` 注入 `AppContext`，避免全局变量：

```zig
fn getApp(ctx: *api.Context) *AppContext {
    return @as(*AppContext, @ptrCast(@alignCast(ctx.user_data.?)));
}

pub fn handleMintAsset(ctx: *api.Context) !void {
    const app = getApp(ctx);
    app.asset_count += 1;
    // ...
}
```

### 2. 分层架构

```
infra/     → 基础设施（中间件、指标）
    ↓
domain/    → 业务逻辑（三个领域处理器）
    ↓
main.zig   → 接线层（路由注册、服务组装）
```

### 3. 状态封装

```zig
pub const AppContext = struct {
    allocator: std.mem.Allocator,
    registry: *metric.Registry,

    // 问题域状态
    problem_count: u64 = 0,

    // 解决域状态
    asset_count: u64 = 0,

    // 世界域状态
    world_count: u64 = 0,
    npc_count: u64 = 0,
    quest_count: u64 = 0,

    // 业务辅助方法
    pub fn getProblemInsight(self: *AppContext, category: []const u8) []const u8 { ... }
    pub fn getNarrativeArc(self: *AppContext, genre: []const u8) []const u8 { ... }
    pub fn getNpcLocation(self: *AppContext, npc_type: []const u8) []const u8 { ... }
    pub fn getDifficultyLabel(self: *AppContext, difficulty: u8) []const u8 { ... }
};
```

## 中间件栈

展示了 ZigZero 中间件的完整组合：

```zig
// 全局中间件（所有路由）
try server.addMiddleware(middleware.requestId());
try server.addMiddleware(middleware.logging());
try server.addMiddleware(try middleware.cors(allocator, .{ .max_age = 86400 }));
try server.addMiddleware(middleware.observability(&registry));
try server.addMiddleware(middleware.loadShedding(&shedder));
try server.addMiddleware(middleware.rateLimitByIp(&ip_limiter));

// 路由级中间件（JWT + body size）
try server.addRoute(.{
    .method = .POST,
    .path = "/api/v1/assets/mint",
    .handler = solution.handleMintAsset,
    .middleware = &.{ jwt_auth, max10m },
    .user_data = &app,
});
```

## API 端点

### 问题域

| 方法 | 路径 | 中间件 | 功能 |
|------|------|--------|------|
| POST | `/api/v1/problems/submit` | maxBodySize(64KB) | 提交创作者痛点 |
| GET | `/api/v1/problems/heatmap` | — | 获取痛点热力图 |

### 解决域

| 方法 | 路径 | 中间件 | 功能 |
|------|------|--------|------|
| POST | `/api/v1/assets/mint` | JWT + 10MB | 铸造创意资产 |
| GET | `/api/v1/marketplace/list` | — | 浏览市场 |
| POST | `/api/v1/subscriptions/subscribe` | JWT | 订阅创作者 |
| GET | `/api/v1/royalties` | — | 版权费分布 |

### 世界域

| 方法 | 路径 | 中间件 | 功能 |
|------|------|--------|------|
| POST | `/api/v1/worlds/create` | JWT | 创建叙事世界 |
| POST | `/api/v1/worlds/:id/npcs` | JWT | 生成 AI NPC |
| POST | `/api/v1/worlds/:id/events` | — | 触发叙事事件 |
| POST | `/api/v1/worlds/:id/quests` | JWT | 发布任务 |
| GET | `/api/v1/worlds/stats` | — | 世界统计 |

### 可观测性

| 方法 | 路径 | 功能 |
|------|------|------|
| GET | `/health` | 健康检查 |
| GET | `/metrics` | Prometheus 指标 |

## 运行

```bash
zig build chy3
./zig-out/bin/chy3

# 输出
chy3 — Creator Metaverse Platform
============================================================
  问题域 (Problem)  Pain point discovery → /api/v1/problems/*
  解决域 (Solution) Creator tools      → /api/v1/assets/* /marketplace/* /subscriptions/*
  世界域 (World)   Metaverse engine   → /api/v1/worlds/*
  Observability                    → /health /metrics
============================================================
[1776254157] [chy3-server] [INFO] Server listening on port 8080
```

## 测试端点

```bash
# 健康检查
curl http://localhost:8080/health

# 提交痛点
curl -X POST http://localhost:8080/api/v1/problems/submit \
  -H "Content-Type: application/json" \
  -d '{"creator_id":"alice","category":"monetization","description":"hard to monetize","severity":5}'

# 生成 JWT 并铸造资产
TOKEN=$(curl -s -X POST http://localhost:8080/api/v1/auth/login \
  -H "Content-Type: application/json" \
  -d '{"username":"admin","password":"admin"}' | jq -r .token)

curl -X POST http://localhost:8080/api/v1/assets/mint \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"creator_id":"alice","asset_type":"narrative","metadata":"story_ch1"}'

# 创建元宇宙世界
curl -X POST http://localhost:8080/api/v1/worlds/create \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"creator_id":"alice","name":"IronRealms","genre":"fantasy"}'

# 查看 Prometheus 指标
curl http://localhost:8080/metrics
```

## 展示的 ZigZero 特性

| 特性 | 用例 |
|------|------|
| `api.Server` | HTTP 服务器 |
| `RouteGroup` | 路由分组 |
| `middleware.requestId()` | 请求 ID 生成 |
| `middleware.logging()` | 结构化日志 |
| `middleware.cors()` | CORS 支持 |
| `middleware.jwt()` | JWT 认证 |
| `middleware.maxBodySize()` | 请求体限制 |
| `middleware.observability()` | Prometheus 指标 |
| `middleware.loadShedding()` | 自适应负载丢弃 |
| `middleware.rateLimitByIp()` | IP 速率限制 |
| `metric.Registry` | Prometheus 注册表 |
| `health.Registry` | 健康检查 |
| `limiter.IpLimiter` | Token bucket 限流 |
| `load.newAdaptiveShedder()` | 负载 shedder |
| `lifecycle.Manager` | 优雅关闭 |
| `log.Logger` | 结构化日志 |
| `mq.Queue` | 消息总线 |

## 扩展方向

- **数据持久化** — 使用 `sqlx` 将状态存入 PostgreSQL
- **Redis 缓存** — 使用 `redis` 缓存市场数据
- **WebSocket 推送** — 使用 `websocket` 实时推送 NPC 对话
- **服务发现** — 使用 `discovery` + `etcd` 实现多实例部署
- **分布式锁** — 使用 `lock` 保护世界状态
- **Cron 任务** — 使用 `cron` 定时结算版权费
