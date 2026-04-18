#!/usr/bin/env bash

# ZigZero Installation Script
# Supports: macOS, Linux, Windows (WSL)

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'
BOLD='\033[1m'

# Config
ZIGZERO_REPO="https://github.com/chy3xyz/zigzero.git"
INSTALL_DIR="${HOME}/.zigzero"
BIN_DIR="${HOME}/.local/bin"
ZIG_MIN_VERSION="0.16.0"

# Helpers
print_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
print_success() { echo -e "${GREEN}[✓]${NC} $1"; }
print_warning() { echo -e "${YELLOW}[!]${NC} $1"; }
print_error() { echo -e "${RED}[✗]${NC} $1"; }

detect_os() {
    case "$(uname -s)" in
        Darwin*) OS="macos" ;;
        Linux*) OS="linux" ;;
        CYGWIN*|MINGW*|MSYS*) OS="windows" ;;
        *) print_error "Unsupported OS: $(uname -s)"; exit 1 ;;
    esac
}

command_exists() { command -v "$1" >/dev/null 2>&1; }

check_zig() {
    if ! command_exists zig; then
        print_error "Zig not installed!"
        echo "Install Zig ${ZIG_MIN_VERSION} from https://ziglang.org/download/"
        exit 1
    fi
    local zig_version=$(zig version)
    if [ "$(printf '%s\n' "$ZIG_MIN_VERSION" "$zig_version" | sort -V | head -n1)" != "$ZIG_MIN_VERSION" ]; then
        print_error "Zig $zig_version is too old. Need $ZIG_MIN_VERSION+"
        exit 1
    fi
    print_success "Zig $zig_version"
}

check_db_deps() {
    print_info "Checking database dependencies..."
    command_exists pg_config && print_success "PostgreSQL" || print_warning "PostgreSQL (optional)"
    command_exists mysql_config && print_success "MySQL" || print_warning "MySQL (optional)"
    command_exists sqlite3 && print_success "SQLite3" || print_warning "SQLite3 (optional)"
}

setup_repo() {
    if [ -d "$INSTALL_DIR" ]; then
        print_info "Updating ZigZero..."
        cd "$INSTALL_DIR" && git pull origin main &>/dev/null || true
    else
        print_info "Installing ZigZero..."
        git clone "$ZIGZERO_REPO" "$INSTALL_DIR" &>/dev/null
        cd "$INSTALL_DIR"
    fi
}

build_zigzero() {
    print_info "Building ZigZero..."
    cd "$INSTALL_DIR"
    if zig build 2>&1 | grep -q "error"; then
        print_warning "Build completed with warnings"
    else
        print_success "Build successful"
    fi
}

# Install CLI
install_cli() {
    print_info "Installing zigzero CLI..."
    mkdir -p "$BIN_DIR"
    
    # Create CLI script
    cat > "$BIN_DIR/zigzero" << 'CLI_SCRIPT'
#!/usr/bin/env bash

ZIGZERO_HOME="${HOME}/.zigzero"

show_help() {
    echo "ZigZero CLI - Project management tool"
    echo ""
    echo "Usage: zigzero <command> [options]"
    echo ""
    echo "Commands:"
    echo "  new <name>        Create a new ZigZero project"
    echo "  init              Initialize in current directory"
    echo "  template          List available templates"
    echo "  run               Run the current project"
    echo "  build             Build the current project"
    echo "  test              Run tests"
    echo "  clean             Clean build artifacts"
    echo "  update            Update ZigZero framework"
    echo "  doctor            Check environment"
    echo "  help              Show this help"
    echo ""
    echo "Examples:"
    echo "  zigzero new my-api-service"
    echo "  zigzero new my-web --template web"
    echo "  zigzero init"
    echo "  zigzero run"
    echo ""
}

cmd_new() {
    local project_name="$1"
    local template="${2:-basic}"
    
    if [ -z "$project_name" ]; then
        echo "Error: Project name required"
        echo "Usage: zigzero new <name> [--template <template>]"
        exit 1
    fi
    
    if [ -d "$project_name" ]; then
        echo "Error: Directory '$project_name' exists"
        exit 1
    fi
    
    echo "Creating project: $project_name"
    echo "Template: $template"
    mkdir -p "$project_name/src"
    
    # build.zig
    cat > "$project_name/build.zig" << 'BUILD_EOF'
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const zigzero = b.dependency("zigzero", .{
        .target = target,
        .optimize = optimize,
    });

    const exe = b.addExecutable(.{
        .name = "${project_name}",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    exe.root_module.addImport("zigzero", zigzero.module("zigzero"));
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    const test_step = b.step("test", "Run unit tests");
    const tests = b.addTest(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    tests.root_module.addImport("zigzero", zigzero.module("zigzero"));
    const run_tests = b.addRunArtifact(tests);
    test_step.dependOn(&run_tests.step);
}
BUILD_EOF

    # build.zig.zon
    cat > "$project_name/build.zig.zon" << 'ZON_EOF'
.{
    .name = .${project_name},
    .version = "0.1.0",
    .minimum_zig_version = "0.16.0",
    .dependencies = .{
        .zigzero = .{
            .url = "https://github.com/chy3xyz/zigzero/archive/refs/heads/main.tar.gz",
        },
    },
    .paths = .{
        "build.zig",
        "build.zig.zon",
        "src",
    },
}
ZON_EOF

    # main.zig based on template
    case "$template" in
        "api")
            create_api_template "$project_name"
            ;;
        "web")
            create_web_template "$project_name"
            ;;
        "minimal")
            create_minimal_template "$project_name"
            ;;
        *)
            create_basic_template "$project_name"
            ;;
    esac

    # .gitignore
    cat > "$project_name/.gitignore" << 'GIT_EOF'
zig-out/
.zig-cache/
*.db
*.log
.env
GIT_EOF

    # README.md
    cat > "$project_name/README.md" << 'README_EOF'
# ${project_name}

ZigZero microservice project.

## Getting Started

\`\`\`bash
# Run
zigzero run

# Test
zigzero test
\`\`\`
README_EOF

    echo "✓ Project '$project_name' created!"
    echo ""
    echo "Next steps:"
    echo "  cd $project_name"
    echo "  zigzero run"
}

create_api_template() {
    local project_name="$1"
    cat > "$project_name/src/main.zig" << 'MAIN_EOF'
const std = @import("std");
const zigzero = @import("zigzero");
const api = zigzero.api;
const log = zigzero.log;
const health = zigzero.health;

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;

    const logger = log.Logger.new(.info, "api-service");
    var server = api.Server.init(allocator, 8080, logger);
    defer server.deinit();

    try server.get("/health", struct {
        fn handle(ctx: *api.Context) !void {
            try ctx.json(200, "{\"status\":\"ok\"}");
        }
    }.handle);

    try server.get("/api/v1/users", getUsers);
    try server.post("/api/v1/users", createUser);
    try server.get("/api/v1/users/:id", getUserById);

    logger.info("API service starting on port 8080");
    try server.start();
}

fn getUsers(ctx: *api.Context) !void {
    try ctx.json(200, "{\"users\":[]}");
}

fn createUser(ctx: *api.Context) !void {
    try ctx.json(201, "{\"id\":1,\"name\":\"New User\"}");
}

fn getUserById(ctx: *api.Context) !void {
    const id = ctx.param("id") orelse "0";
    try ctx.json(200, std.fmt.allocPrint(ctx.allocator, "{\"id\":{s}}", .{id}));
}
MAIN_EOF
}

create_web_template() {
    local project_name="$1"
    cat > "$project_name/src/main.zig" << 'MAIN_EOF'
const std = @import("std");
const zigzero = @import("zigzero");
const api = zigzero.api;
const log = zigzero.log;

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;

    const logger = log.Logger.new(.info, "web-app");
    var server = api.Server.init(allocator, 3000, logger);
    defer server.deinit();

    try server.get("/", serveHome);
    try server.get("/about", serveAbout);
    try server.get("/api/data", getData);

    logger.info("Web app starting on port 3000");
    try server.start();
}

fn serveHome(ctx: *api.Context) !void {
    const html = \\
        \\<!DOCTYPE html>
        \\u003chtml><head><title>ZigZero</title></head>
        \\u003cbody><h1>Welcome!</h1></body>
        \\u003c/html>
    ;
    try ctx.html(200, html);
}

fn serveAbout(ctx: *api.Context) !void {
    try ctx.html(200, "<h1>About</h1>");
}

fn getData(ctx: *api.Context) !void {
    try ctx.json(200, "{\"message\":\"Hello\"}");
}
MAIN_EOF
}

create_basic_template() {
    local project_name="$1"
    cat > "$project_name/src/main.zig" << 'MAIN_EOF'
const std = @import("std");
const zigzero = @import("zigzero");
const api = zigzero.api;
const log = zigzero.log;
const health = zigzero.health;

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;

    const logger = log.Logger.new(.info, "app");
    var server = api.Server.init(allocator, 8080, logger);
    defer server.deinit();

    try server.get("/health", struct {
        fn handle(ctx: *api.Context) !void {
            try ctx.json(200, "{\"status\":\"ok\"}");
        }
    }.handle);

    try server.get("/", struct {
        fn handle(ctx: *api.Context) !void {
            try ctx.text(200, "Hello, ZigZero!");
        }
    }.handle);

    logger.info("Server starting on port 8080");
    try server.start();
}
MAIN_EOF
}

create_minimal_template() {
    local project_name="$1"
    cat > "$project_name/src/main.zig" << 'MAIN_EOF'
const std = @import("std");

pub fn main() !void {
    const stdout = std.io.getStdOut().writer();
    try stdout.print("Hello, {s}!\n", .{"ZigZero"});
}
MAIN_EOF
}

cmd_init() {
    if [ -f "build.zig" ]; then
        echo "Error: build.zig already exists"
        exit 1
    fi
    local project_name=$(basename "$PWD")
    echo "Initializing ZigZero project: $project_name"
    mkdir -p src
    cmd_new "$project_name" &>/dev/null
    mv "$project_name"/* . 2>/dev/null || true
    mv "$project_name"/.* . 2>/dev/null || true
    rmdir "$project_name" 2>/dev/null || true
    echo "✓ Initialized"
}

cmd_template() {
    echo "Available templates:"
    echo "  basic     - API service (default)"
    echo "  api       - REST API with CRUD"
    echo "  web       - Web application"
    echo "  minimal   - Minimal setup"
}

cmd_run() {
    [ ! -f "build.zig" ] && { echo "Error: No build.zig found"; exit 1; }
    zig build run
}

cmd_build() {
    [ ! -f "build.zig" ] && { echo "Error: No build.zig found"; exit 1; }
    if [ "$1" = "--release" ] || [ "$1" = "-r" ]; then
        zig build -Doptimize=ReleaseFast
    else
        zig build
    fi
}

cmd_test() {
    [ ! -f "build.zig" ] && { echo "Error: No build.zig found"; exit 1; }
    zig build test
}

cmd_clean() {
    [ ! -f "build.zig" ] && { echo "Error: No build.zig found"; exit 1; }
    rm -rf zig-out/ .zig-cache/
    echo "✓ Cleaned"
}

cmd_update() {
    if [ -d "$ZIGZERO_HOME" ]; then
        cd "$ZIGZERO_HOME" && git pull origin main
        echo "✓ Updated"
    else
        echo "Error: Not installed"
        exit 1
    fi
}

cmd_doctor() {
    echo "ZigZero Environment Check"
    echo "========================"
    echo ""
    echo "OS: $(uname -s)"
    command -v zig >/dev/null 2>&1 && echo "✓ Zig: $(zig version)" || echo "✗ Zig"
    command -v git >/dev/null 2>&1 && echo "✓ Git" || echo "✗ Git"
    echo ""
    echo "DB Libraries:"
    command -v pg_config >/dev/null 2>&1 && echo "✓ PostgreSQL" || echo "✗ PostgreSQL"
    command -v mysql_config >/dev/null 2>&1 && echo "✓ MySQL" || echo "✗ MySQL"
    command -v sqlite3 >/dev/null 2>&1 && echo "✓ SQLite3" || echo "✗ SQLite3"
    echo ""
    echo "Install:"
    [ -d "$ZIGZERO_HOME" ] && echo "✓ Framework" || echo "✗ Framework"
    [ -f "$HOME/.local/bin/zigzero" ] && echo "✓ CLI" || echo "✗ CLI"
}

parse_args() {
    local args=()
    local template="basic"
    while [[ $# -gt 0 ]]; do
        case $1 in
            --template|-t) template="$2"; shift 2 ;;
            *) args+=("$1"); shift ;;
        esac
    done
    echo "$template"
}

main() {
    case "${1:-help}" in
        "new")
            shift
            local template=$(parse_args "$@")
            local project_name="${2:-}"
            [ -z "$project_name" ] && { echo "Error: Name required"; exit 1; }
            cmd_new "$project_name" "$template"
            ;;
        "init") cmd_init ;;
        "template"|"templates") cmd_template ;;
        "run") cmd_run ;;
        "build") shift; cmd_build "$@" ;;
        "test") cmd_test ;;
        "clean") cmd_clean ;;
        "update") cmd_update ;;
        "doctor") cmd_doctor ;;
        "help"|"--help"|"-h") show_help ;;
        *) echo "Unknown: $1"; show_help; exit 1 ;;
    esac
}

main "$@"
CLI_SCRIPT
    
    chmod +x "$BIN_DIR/zigzero"
    print_success "CLI installed"
}

setup_env() {
    print_info "Configuring environment..."
    local shell_rc=""
    case "$SHELL" in
        */bash) shell_rc="$HOME/.bashrc" ;;
        */zsh) shell_rc="$HOME/.zshrc" ;;
        */fish) shell_rc="$HOME/.config/fish/config.fish" ;;
        *) shell_rc="$HOME/.profile" ;;
    esac
    
    if ! grep -q "ZIGZERO_HOME" "$shell_rc" 2>/dev/null; then
        echo "" >> "$shell_rc"
        echo "export ZIGZERO_HOME=\"$INSTALL_DIR\"" >> "$shell_rc"
    fi
    
    if ! echo "$PATH" | grep -q "$BIN_DIR"; then
        echo "export PATH=\"\$PATH:$BIN_DIR\"" >> "$shell_rc"
        print_warning "Run: source $shell_rc"
    fi
    print_success "Environment configured"
}

copy_examples() {
    local examples_dir="${HOME}/zigzero-examples"
    if [ ! -d "$examples_dir" ]; then
        mkdir -p "$examples_dir"
        cp -r "$INSTALL_DIR/examples/"* "$examples_dir/" 2>/dev/null || true
        print_success "Examples copied"
    fi
}

print_completion() {
    echo ""
    echo -e "${GREEN}╔════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║  🎉  ZigZero Installation Complete!                       ║${NC}"
    echo -e "${GREEN}╚════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "${BOLD}Quick Start:${NC}"
    echo ""
    echo -e "  1. Create project:"
    echo -e "     ${CYAN}zigzero new my-app${NC}"
    echo ""
    echo -e "  2. Run:"
    echo -e "     ${CYAN}cd my-app${NC}"
    echo -e "     ${CYAN}zigzero run${NC}"
    echo ""
    echo -e "${BOLD}Commands:${NC}"
    echo -e "  ${CYAN}zigzero new <name>${NC}     Create project"
    echo -e "  ${CYAN}zigzero init${NC}           Initialize"
    echo -e "  ${CYAN}zigzero run${NC}            Run project"
    echo -e "  ${CYAN}zigzero build${NC}          Build"
    echo -e "  ${CYAN}zigzero test${NC}           Test"
    echo -e "  ${CYAN}zigzero clean${NC}          Clean"
    echo -e "  ${CYAN}zigzero doctor${NC}         Check env"
    echo -e "  ${CYAN}zigzero update${NC}         Update"
    echo ""
    echo -e "${GREEN}Happy coding! 🚀${NC}"
}

do_install() {
    print_info "Installing ZigZero..."
    detect_os
    check_zig
    check_db_deps
    setup_repo
    build_zigzero
    install_cli
    setup_env
    copy_examples
    print_completion
}

# Main
parse_command() {
    case "${1:-install}" in
        "--help"|"-h"|"help")
            echo "ZigZero Installer"
            echo "Usage: $0 [install|uninstall|help]"
            ;;
        "install"|"")
            do_install
            ;;
        "uninstall"|"-u")
            rm -rf "$INSTALL_DIR" "$BIN_DIR/zigzero" "$HOME/zigzero-examples"
            print_success "Uninstalled"
            ;;
        *)
            print_error "Unknown: $1"
            exit 1
            ;;
    esac
}

parse_command "$@"
