#!/bin/bash
set -euo pipefail

# Production init script for Frappe CRM

if [ "${1:-}" != "--as-frappe" ] && [ "$(id -u)" -eq 0 ]; then
    echo "Running as root, setting up permissions..."

    # Create all necessary directories
    mkdir -p /home/frappe/frappe-bench/apps
    mkdir -p /home/frappe/frappe-bench/sites
    mkdir -p /home/frappe/frappe-bench/logs
    mkdir -p /home/frappe/frappe-bench/config
    mkdir -p /home/frappe/frappe-bench/archived/apps

    # Set ownership for entire frappe home
    chown -R frappe:frappe /home/frappe

    # Switch to frappe user and continue
    exec su - frappe -c "bash /workspace/crm/docker/init_prod.sh --as-frappe"
fi

BENCH_DIR="/home/frappe/frappe-bench"
SITE_NAME="${SITE_NAME:-crm.localhost}"
WORKSPACE_DIR="/workspace/crm"
DB_ROOT_PASSWORD="${DB_ROOT_PASSWORD:-change_me_in_production}"
ADMIN_PASSWORD="${ADMIN_PASSWORD:-admin}"

# Docker bind-mounts can trigger git's "dubious ownership" protection.
git config --global --add safe.directory "${WORKSPACE_DIR}" || true
git config --global --add safe.directory "${BENCH_DIR}/apps/crm" || true

# Wait for MariaDB to be ready (and credentials to be correct)
echo "Waiting for MariaDB..."
db_ready=0
for i in {1..30}; do
    if mysqladmin ping -h mariadb -u root -p"${DB_ROOT_PASSWORD}" --silent 2>/dev/null; then
        db_ready=1
        echo "MariaDB is ready!"
        break
    fi
    echo "Waiting for MariaDB... ($i/30)"
    sleep 2
done

if [ "${db_ready}" -ne 1 ]; then
    echo "ERROR: Could not connect to MariaDB as root."
    echo "Either MariaDB is not reachable or DB_ROOT_PASSWORD is wrong for the existing DB volume."
    echo "Fix options:"
    echo "  1) Set DB_ROOT_PASSWORD to the correct existing root password (same value used when the mariadb-data volume was first created)."
    echo "  2) Reset the DB volume (DATA LOSS): docker compose -f docker/docker-compose.prod.yml down -v"
    exit 1
fi

cd /home/frappe

# Initialize bench if not exists
if [ ! -d "${BENCH_DIR}/apps/frappe" ]; then
    echo "Creating new bench..."
    bench init --ignore-exist --skip-redis-config-generation frappe-bench --version version-15 --python python3.11
else
    echo "Bench already exists, skipping bench init"
fi

cd "${BENCH_DIR}"

# Configure database and redis hosts
bench set-mariadb-host mariadb
bench set-redis-cache-host redis://redis-cache:6379
bench set-redis-queue-host redis://redis-queue:6379
bench set-redis-socketio-host redis://redis-queue:6379

# Production Procfile - remove unnecessary services
sed -i '/redis/d' ./Procfile
sed -i '/watch/d' ./Procfile

mkdir -p archived/apps

# Link CRM app
APP_LINK="${BENCH_DIR}/apps/crm"
if [ -L "${APP_LINK}" ] && [ "$(readlink -f "${APP_LINK}")" = "${WORKSPACE_DIR}" ]; then
    echo "CRM app already linked, skipping get-app"
else
    bench get-app --overwrite --soft-link "${WORKSPACE_DIR}"
fi

# Create site if not exists, or recreate if database connection is broken
SITE_DIR="${BENCH_DIR}/sites/${SITE_NAME}"
SITE_CONFIG="${SITE_DIR}/site_config.json"

create_site() {
    echo "Creating new site: ${SITE_NAME}"
    bench new-site "${SITE_NAME}" \
        --force \
        --mariadb-root-password "${DB_ROOT_PASSWORD}" \
        --admin-password "${ADMIN_PASSWORD}" \
        --no-mariadb-socket
}

if [ ! -f "${SITE_CONFIG}" ]; then
    create_site
else
    # Site config exists, verify database connection works
    echo "Site config exists, verifying database connection..."

    # Extract database name from site_config.json
    DB_NAME=$(grep -o '"db_name"[[:space:]]*:[[:space:]]*"[^"]*"' "${SITE_CONFIG}" | cut -d'"' -f4)

    if [ -n "${DB_NAME}" ]; then
        # Test if we can connect to the database
        if ! mysql -h mariadb -u root -p"${DB_ROOT_PASSWORD}" -e "SELECT 1 FROM ${DB_NAME}.tabDefaultValue LIMIT 1" 2>/dev/null; then
            echo "WARNING: Database connection failed for existing site."
            echo "The site config exists but the database '${DB_NAME}' or its user is not accessible."
            echo "Removing old site config and recreating site..."

            # Backup old site config
            mv "${SITE_DIR}" "${SITE_DIR}.backup.$(date +%Y%m%d%H%M%S)" 2>/dev/null || true

            # Drop the old database if it exists (clean slate)
            mysql -h mariadb -u root -p"${DB_ROOT_PASSWORD}" -e "DROP DATABASE IF EXISTS \`${DB_NAME}\`" 2>/dev/null || true
            mysql -h mariadb -u root -p"${DB_ROOT_PASSWORD}" -e "DROP USER IF EXISTS '${DB_NAME}'@'%'" 2>/dev/null || true

            create_site
        else
            echo "Database connection verified successfully."
        fi
    else
        echo "WARNING: Could not extract db_name from site_config.json"
        echo "Recreating site..."
        mv "${SITE_DIR}" "${SITE_DIR}.backup.$(date +%Y%m%d%H%M%S)" 2>/dev/null || true
        create_site
    fi
fi

# Install CRM app if not installed
if ! bench --site "${SITE_NAME}" list-apps 2>/dev/null | grep -Fxq crm; then
    echo "Installing CRM app..."
    bench --site "${SITE_NAME}" install-app crm
fi

# Production configuration
echo "Applying production configuration..."
bench --site "${SITE_NAME}" set-config developer_mode 0
bench --site "${SITE_NAME}" set-config ignore_csrf 0
bench --site "${SITE_NAME}" set-config mute_emails 0
bench --site "${SITE_NAME}" set-config server_script_enabled 1
bench --site "${SITE_NAME}" set-config maintenance_mode 0

# Build assets for production
echo "Building assets..."
bench build --app crm

# Clear cache
bench --site "${SITE_NAME}" clear-cache

# Set default site
bench use "${SITE_NAME}"

echo "========================================"
echo "Production setup complete!"
echo "Site: ${SITE_NAME}"
echo "========================================"

# Start production server with gunicorn
exec bench start
