#!/bin/bash
# Initialize PostgreSQL and MySQL databases for ZigZero testing.
# Supports: macOS (Homebrew), Ubuntu/Debian (apt), Fedora/RHEL (dnf)
#
# Usage:
#   ./scripts/init-db.sh              # Interactive (create all)
#   ./scripts/init-db.sh --postgres  # PostgreSQL only
#   ./scripts/init-db.sh --mysql     # MySQL only
#   ./scripts/init-db.sh --clean    # Drop test databases
#
# Environment variables (override defaults):
#   PGPASSWORD, PGUSER, PGDATABASE  — PostgreSQL credentials
#   MYSQL_ROOT_PASSWORD, MYSQL_PASSWORD, MYSQL_DATABASE — MySQL credentials

set -e

# --- Defaults ---
PGUSER="${PGUSER:-zigzero}"
PGPASSWORD="${PGPASSWORD:-zigzero}"
PGDATABASE="${PGDATABASE:-zigzero_test}"
PGHOST="${PGHOST:-localhost}"
PGPORT="${PGPORT:-5432}"

MYSQL_USER="${MYSQL_USER:-zigzero}"
MYSQL_PASSWORD="${MYSQL_PASSWORD:-zigzero}"
MYSQL_DATABASE="${MYSQL_DATABASE:-zigzero_test}"
MYSQL_ROOT_PASSWORD="${MYSQL_ROOT_PASSWORD:-root}"
MYSQL_HOST="${MYSQL_HOST:-localhost}"
MYSQL_PORT="${MYSQL_PORT:-3306}"

# --- Detect platform ---
detect_postgres_cmd() {
    if command -v psql &>/dev/null; then
        echo "psql"
    elif command -v pg_isready &>/dev/null; then
        # Homebrew on macOS puts postgres in a versioned path
        for p in /usr/local/opt/postgresql@*/bin/psql \
                 /opt/homebrew/opt/postgresql@*/bin/psql; do
            if [ -x "$p" ]; then echo "$p"; return 0; fi
        done
    fi
    return 1
}

detect_mysql_cmd() {
    if command -v mysql &>/dev/null; then
        echo "mysql"
    elif command -v mysqladmin &>/dev/null; then
        # Homebrew on macOS puts mysql in a versioned path
        for m in /usr/local/opt/mysql*/bin/mysql \
                 /opt/homebrew/opt/mysql*/bin/mysql; do
            if [ -x "$m" ]; then echo "$m"; return 0; fi
        done
    fi
    return 1
}

mysql_cmd() {
    detect_mysql_cmd
}

postgres_cmd() {
    detect_postgres_cmd
}

# --- PostgreSQL ---
init_postgres() {
    local psql
    psql=$(detect_postgres_cmd) || {
        echo "[skip] PostgreSQL client (psql) not found"
        return 0
    }

    echo "[postgres] Connecting to $PGHOST:$PGPORT..."

    # Check connection
    PGPASSWORD="$PGPASSWORD" $psql -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" -d postgres -c "SELECT 1" &>/dev/null || {
        echo "[postgres] Cannot connect as $PGUSER. Trying peer/socket auth..."
        # Try without password (peer auth on localhost)
        $psql -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" -d postgres -c "SELECT 1" &>/dev/null || {
            echo "[postgres] ERROR: Cannot connect to PostgreSQL."
            echo "            Ensure PostgreSQL is running and user '$PGUSER' exists."
            echo "            Try: createuser -h $PGHOST -p $PGPORT -U $(whoami) $PGUSER"
            return 1
        }
    }

    # Create user
    echo "[postgres] Ensuring user '$PGUSER' exists..."
    PGPASSWORD="$PGPASSWORD" $psql -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" -d postgres -c "SELECT 1" &>/dev/null \
        || PGPASSWORD="$PGPASSWORD" $psql -h "$PGHOST" -p "$PGPORT" -U postgres -c \
            "CREATE USER $PGUSER WITH PASSWORD '$PGPASSWORD' LOGIN CREATEDB;" 2>/dev/null \
        || echo "[postgres] User '$PGUSER' may already exist or cannot be created (permission denied)"

    # Create database
    echo "[postgres] Ensuring database '$PGDATABASE' exists..."
    PGPASSWORD="$PGPASSWORD" $psql -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" -d postgres -c \
        "SELECT datname FROM pg_database WHERE datname = '$PGDATABASE'" 2>/dev/null | grep -q "$PGDATABASE" \
        || PGPASSWORD="$PGPASSWORD" $psql -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" -d postgres -c \
            "CREATE DATABASE $PGDATABASE OWNER $PGUSER;" 2>/dev/null \
        || echo "[postgres] Database '$PGDATABASE' may already exist"

    # Grant privileges
    PGPASSWORD="$PGPASSWORD" $psql -h "$PGHOST" -p "$PGPORT" -U postgres -c \
        "GRANT ALL PRIVILEGES ON DATABASE $PGDATABASE TO $PGUSER;" 2>/dev/null || true

    echo "[postgres] Done. Connection: host=$PGHOST port=$PGPORT dbname=$PGDATABASE user=$PGUSER"
}

# --- MySQL ---
init_mysql() {
    local mysql
    mysql=$(detect_mysql_cmd) || {
        echo "[skip] MySQL client (mysql) not found"
        return 0
    }

    echo "[mysql] Connecting to $MYSQL_HOST:$MYSQL_PORT..."

    # Try socket connection on macOS
    local socket_opts=""
    if [ -S /tmp/mysql.sock ]; then
        socket_opts="-S /tmp/mysql.sock"
    elif [ -S /tmp/mysqlx.sock ]; then
        socket_opts="-S /tmp/mysqlx.sock"
    fi

    # Check root connection
    mysql $socket_opts -u root -p"$MYSQL_ROOT_PASSWORD" -h "$MYSQL_HOST" -e "SELECT 1" &>/dev/null || {
        echo "[mysql] Cannot connect as root. Trying socket auth (no password)..."
        mysql $socket_opts -u root -h "$MYSQL_HOST" -e "SELECT 1" &>/dev/null || {
            echo "[mysql] ERROR: Cannot connect to MySQL."
            echo "            Ensure MySQL is running and root has password '$MYSQL_ROOT_PASSWORD',"
            echo "            or remove password for socket auth."
            return 1
        }
    }

    # Create user
    echo "[mysql] Ensuring user '$MYSQL_USER' exists..."
    mysql $socket_opts -u root -p"$MYSQL_ROOT_PASSWORD" -h "$MYSQL_HOST" -e \
        "CREATE USER IF NOT EXISTS '$MYSQL_USER'@'localhost' IDENTIFIED BY '$MYSQL_PASSWORD';" 2>/dev/null \
        || mysql $socket_opts -u root -h "$MYSQL_HOST" -e \
            "CREATE USER IF NOT EXISTS '$MYSQL_USER'@'localhost' IDENTIFIED BY '$MYSQL_PASSWORD';" 2>/dev/null \
        || echo "[mysql] User '$MYSQL_USER' may already exist"

    # Create database
    echo "[mysql] Ensuring database '$MYSQL_DATABASE' exists..."
    mysql $socket_opts -u root -p"$MYSQL_ROOT_PASSWORD" -h "$MYSQL_HOST" -e \
        "CREATE DATABASE IF NOT EXISTS $MYSQL_DATABASE;" 2>/dev/null \
        || mysql $socket_opts -u root -h "$MYSQL_HOST" -e \
            "CREATE DATABASE IF NOT EXISTS $MYSQL_DATABASE;" 2>/dev/null \
        || echo "[mysql] Database '$MYSQL_DATABASE' may already exist"

    # Grant privileges
    mysql $socket_opts -u root -p"$MYSQL_ROOT_PASSWORD" -h "$MYSQL_HOST" -e \
        "GRANT ALL PRIVILEGES ON $MYSQL_DATABASE.* TO '$MYSQL_USER'@'localhost';" 2>/dev/null || true

    # Create database via non-root user if root doesn't work
    mysql $socket_opts -u "$MYSQL_USER" -p"$MYSQL_PASSWORD" -h "$MYSQL_HOST" -e \
        "CREATE DATABASE IF NOT EXISTS $MYSQL_DATABASE;" 2>/dev/null || true

    echo "[mysql] Done. Connection: host=$MYSQL_HOST port=$MYSQL_PORT database=$MYSQL_DATABASE user=$MYSQL_USER"
}

# --- Clean ---
clean_postgres() {
    local psql
    psql=$(detect_postgres_cmd) || return 0
    echo "[postgres] Dropping database '$PGDATABASE'..."
    PGPASSWORD="$PGPASSWORD" $psql -h "$PGHOST" -p "$PGPORT" -U postgres -c \
        "DROP DATABASE IF EXISTS $PGDATABASE;" 2>/dev/null || echo "[postgres] Could not drop database"
}

clean_mysql() {
    local mysql
    mysql=$(detect_mysql_cmd) || return 0
    local socket_opts=""
    if [ -S /tmp/mysql.sock ]; then socket_opts="-S /tmp/mysql.sock"; fi
    echo "[mysql] Dropping database '$MYSQL_DATABASE'..."
    mysql $socket_opts -u root -p"$MYSQL_ROOT_PASSWORD" -h "$MYSQL_HOST" -e \
        "DROP DATABASE IF EXISTS $MYSQL_DATABASE;" 2>/dev/null || echo "[mysql] Could not drop database"
}

# --- Main ---
main() {
    local mode="${1:-all}"

    case "$mode" in
        --postgres)
            echo "=== PostgreSQL Setup ==="
            init_postgres
            ;;
        --mysql)
            echo "=== MySQL Setup ==="
            init_mysql
            ;;
        --clean)
            echo "=== Cleaning databases ==="
            clean_postgres
            clean_mysql
            echo "Done."
            ;;
        --help|-h)
            echo "Usage: $0 [--postgres|--mysql|--clean|--help]"
            exit 0
            ;;
        all|"")
            echo "=== PostgreSQL Setup ==="
            init_postgres
            echo ""
            echo "=== MySQL Setup ==="
            init_mysql
            echo ""
            echo "All done. Run tests with:"
            echo "  DB=postgres zig build test   # PostgreSQL tests"
            echo "  DB=mysql   zig build test   # MySQL tests"
            echo "  zig build test              # SQLite tests only"
            ;;
        *)
            echo "Unknown argument: $mode"
            echo "Usage: $0 [--postgres|--mysql|--clean|--help]"
            exit 1
            ;;
    esac
}

main "$@"
