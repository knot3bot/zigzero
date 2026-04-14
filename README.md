# ZigZero

**Zero-cost microservice framework for Zig, aligned with go-zero patterns.**

## Overview

ZigZero is a high-performance microservice framework written in Zig, inspired by go-zero. It provides comprehensive capabilities for building production-ready microservices with zero external dependencies.

## Features

- **HTTP Server** (`api`) - Full HTTP server with routing, middleware, JSON parsing
- **RPC Framework** (`rpc`) - Binary protocol RPC over TCP with circuit breaker
- **HTTP Client** (`http`) - HTTP client with timeout and retries
- **Configuration** (`config`) - JSON configuration loading
- **Logging** (`log`) - Structured logging with levels
- **Circuit Breaker** (`breaker`) - Hystrix-style circuit breaker
- **Rate Limiter** (`limiter`) - Token bucket and sliding window
- **Load Balancer** (`loadbalancer`) - Round robin, random, weighted, least connection
- **Redis Client** (`redis`) - RESP protocol implementation
- **Connection Pool** (`pool`) - Generic connection pooling
- **Health Checks** (`health`) - Health probe registry
- **Service Discovery** (`discovery`) - Static service discovery
- **Distributed Tracing** (`trace`) - OpenTelemetry-compatible tracing
- **Metrics** (`metric`) - Prometheus-compatible metrics
- **Validation** (`validate`) - Input validation utilities
- **Local Cache** (`cache`) - In-memory LRU cache
- **Distributed Lock** (`lock`) - Redis and local locks
- **ORM** (`orm`) - Query builder and model traits
- **Service Context** (`svc`) - Dependency injection context

## Quick Start

```zig
const std = @import("std");
const zigzero = @import("zigzero");
const api = zigzero.api;
const log = zigzero.log;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    const logger = log.Logger.new(.info, "my-service");
    var server = api.Server.init(allocator, 8080, logger);
    defer server.deinit();

    try server.addRoute(.{
        .method = .GET,
        .path = "/health",
        .handler = struct {
            fn handle(ctx: *api.Context) !void {
                try ctx.json(200, "{\"status\":\"ok\"}");
            }
        }.handle,
    });

    try server.start();
}
```

## Installation

Add to your `build.zig`:

```zig
const zigzero = b.dependency("zigzero", .{
    .target = target,
    .optimize = optimize,
});
exe.root_module.addImport("zigzero", zigzero.module("zigzero"));
```

## Examples

See `examples/` directory for complete working examples:

- `examples/api-server/` - Full HTTP API server with middleware, health checks, and validation

## Build & Test

```bash
# Build
zig build

# Run tests
zig build test
```

## Architecture

```
┌─────────────────────────────────────┐
│          接入层 (API Gateway)        │
├─────────────────────────────────────┤
│          服务层 (Service Layer)       │
├─────────────────────────────────────┤
│        服务治理层 (Governance)       │
│  breaker | limiter | loadbalancer    │
├─────────────────────────────────────┤
│       基础设施层 (Infrastructure)     │
│  config | log | redis | pool | http │
│  trace | metric | cache | lock      │
└─────────────────────────────────────┘
```

## Module Reference

| Module | Description | Status |
|--------|-------------|--------|
| `api` | HTTP server, routing, middleware | ✅ Complete |
| `rpc` | RPC framework over TCP | ✅ Complete |
| `http` | HTTP client | ✅ Complete |
| `config` | Configuration management | ✅ Complete |
| `log` | Structured logging | ✅ Complete |
| `breaker` | Circuit breaker | ✅ Complete |
| `limiter` | Rate limiting | ✅ Complete |
| `loadbalancer` | Load balancing | ✅ Complete |
| `redis` | Redis client (RESP) | ✅ Complete |
| `pool` | Connection pooling | ✅ Complete |
| `health` | Health checks | ✅ Complete |
| `discovery` | Service discovery | ✅ Complete |
| `trace` | Distributed tracing | ✅ Complete |
| `metric` | Prometheus metrics | ✅ Complete |
| `validate` | Input validation | ✅ Complete |
| `cache` | In-memory cache | ✅ Complete |
| `lock` | Distributed locking | ✅ Complete |
| `orm` | Query builder | ✅ Complete |
| `svc` | Service context | ✅ Complete |
| `middleware` | JWT, CORS, logging, recovery | ✅ Complete |
| `errors` | Error types | ✅ Complete |

## Requirements

- Zig 0.15.2+
- No external dependencies (uses std library only)

## License

MIT
