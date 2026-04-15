# Configuration

ZigZero 提供灵活的配置系统，支持 YAML、JSON、环境变量和代码字面量。

## 配置加载

### 从 YAML 文件

```yaml
# config.yaml
server:
  port: 8080
  workers: 4
  read_timeout_ms: 30_000
  write_timeout_ms: 30_000

database:
  host: localhost
  port: 5432
  name: myapp
  max_connections: 10

redis:
  address: 127.0.0.1:6379
  db: 0

logging:
  level: info
  file: /var/log/myapp.log
```

```zig
const zigzero = @import("zigzero");
const config = zigzero.config;

pub fn main() !void {
    const cfg = try config.loadFromYamlFile("config.yaml");
    defer cfg.deinit();

    var server = try api.Server.init(gpa.allocator(), cfg.server.port, logger);
    // ...
}
```

### 从 JSON 文件

```json
{
  "server": { "port": 8080, "workers": 4 },
  "database": {
    "host": "localhost",
    "port": 5432,
    "name": "myapp"
  }
}
```

```zig
const cfg = try config.loadFromJsonFile("config.json");
```

### 从环境变量

```bash
export SERVER_PORT=8080
export DATABASE_HOST=prod-db.example.com
export DATABASE_PASSWORD=secret
```

```zig
// config.yaml
server:
  port: ${SERVER_PORT:-8080}
database:
  host: ${DATABASE_HOST}
  password: ${DATABASE_PASSWORD}
```

### 组合配置源

优先级（高到低）：

```
命令行参数 > 环境变量 > YAML/JSON 配置 > 默认值
```

## 配置结构定义

```zig
const ServerConfig = struct {
    port: u16 = 8080,
    workers: u32 = 4,
    read_timeout_ms: u32 = 30_000,
    write_timeout_ms: u32 = 30_000,
};

const DbConfig = struct {
    host: []const u8 = "localhost",
    port: u16 = 5432,
    name: []const u8,
    user: []const u8 = "postgres",
    password: []const u8 = "",
    max_connections: u32 = 10,
};

const RedisConfig = struct {
    address: []const u8 = "127.0.0.1:6379",
    db: u8 = 0,
    password: ?[]const u8 = null,
};

const AppConfig = struct {
    server: ServerConfig,
    database: DbConfig,
    redis: RedisConfig,
    log_level: []const u8 = "info",
};
```

## 配置验证

```zig
pub fn loadConfig(path: []const u8) !AppConfig {
    const raw = try config.loadFromYamlFile(path);

    const cfg = try std.json.parseFromSlice(
        AppConfig,
        raw.allocator,
        raw.content,
        .{
            .ignore_unknown_fields = false,
            .syntax = .yaml,
        },
    );

    // 验证
    if (cfg.value.server.port < 1024) {
        return error.InvalidPort;
    }
    if (cfg.value.database.max_connections < 1) {
        return error.InvalidConnectionLimit;
    }

    return cfg.value;
}
```

## 环境特定配置

### 开发/生产/测试环境

```bash
# config.dev.yaml
database:
  host: localhost

# config.prod.yaml
database:
  host: prod-db.internal
  max_connections: 50
```

```bash
# 启动时指定环境
./my-service --config config.prod.yaml

# 或通过环境变量
export ZIGZERO_ENV=prod
```

### 多环境配置合并

```zig
pub fn loadEnvConfig(env: []const u8) !AppConfig {
    const base = try config.loadFromYamlFile("config.yaml");
    const env_override = try config.loadFromYamlFile(
        try std.fmt.allocPrint(gpa.allocator(), "config.{s}.yaml", .{env}),
    );

    return try config.merge(base, env_override);
}
```

## 配置热重载

```zig
var config_watcher = try config.FileWatcher.init(gpa.allocator(), "config.yaml");
defer config_watcher.deinit();

try config_watcher.onChange(struct {
    fn reload(new_config: AppConfig) !void {
        std.debug.print("Config reloaded!\n", .{});
        try applyNewConfig(new_config);
    }
}.reload);
```

## 从代码配置

不使用文件，直接在代码中设置：

```zig
const cfg = AppConfig{
    .server = .{ .port = 9090, .workers = 2 },
    .database = .{
        .host = "localhost",
        .port = 5432,
        .name = "testdb",
        .password = "test",
    },
    .redis = .{ .address = "localhost:6379" },
    .log_level = "debug",
};
```

## 配置示例：完整微服务

```yaml
# config.yaml
app:
  name: user-service
  env: production

server:
  port: 8080
  workers: 8

database:
  host: ${DB_HOST:-localhost}
  port: ${DB_PORT:-5432}
  name: users
  user: ${DB_USER}
  password: ${DB_PASSWORD}
  max_connections: 20
  ssl: true

redis:
  address: ${REDIS_ADDR:-localhost:6379}
  password: ${REDIS_PASSWORD}
  pool_size: 10

rate_limiting:
  enabled: true
  ip_rate: 100
  ip_burst: 10

circuit_breaker:
  failure_threshold: 5
  timeout_ms: 30_000

observability:
  metrics_enabled: true
  tracing_enabled: true
  sample_rate: 0.1

logging:
  level: ${LOG_LEVEL:-info}
  format: json
  output: stdout
```

## 密钥管理

**不要将密钥提交到代码库：**

```bash
# .gitignore
config.yaml
!config.yaml.example
```

```yaml
# config.yaml.example (不含密钥)
database:
  password: ${DB_PASSWORD}
redis:
  password: ${REDIS_PASSWORD}
jwt:
  secret: ${JWT_SECRET}
```

```bash
# 生产环境变量
export DB_PASSWORD=actual-secure-password
export REDIS_PASSWORD=redis-secret
export JWT_SECRET=your-256-bit-secret
```

## 下一步

- [Authentication](authentication.md) — JWT 认证配置
- [Graceful Shutdown](graceful-shutdown.md) — 配置与生命周期集成
- [First Service Tutorial](../getting-started/first-service.md) — 完整配置示例
