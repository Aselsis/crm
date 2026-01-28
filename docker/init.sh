#!/bin/bash
set -euo pipefail

if [ "${1:-}" != "--as-frappe" ] && [ "$(id -u)" -eq 0 ]; then
    mkdir -p /home/frappe/frappe-bench
    chown -R frappe:frappe /home/frappe/frappe-bench
    exec su - frappe -c "bash /workspace/crm/docker/init.sh --as-frappe"
fi

BENCH_DIR="/home/frappe/frappe-bench"
SITE_NAME="crm.localhost"
WORKSPACE_DIR="/workspace/crm"

# Docker bind-mounts can trigger git's "dubious ownership" protection.
git config --global --add safe.directory "${WORKSPACE_DIR}" || true
git config --global --add safe.directory "${BENCH_DIR}/apps/crm" || true

cd /home/frappe

if [ ! -d "${BENCH_DIR}/apps/frappe" ]; then
    echo "Creating new bench..."
    bench init --ignore-exist --skip-redis-config-generation frappe-bench --version version-15 --python python3.11
else
    echo "Bench already exists, skipping bench init"
fi

cd "${BENCH_DIR}"

# Use containers instead of localhost
bench set-mariadb-host mariadb
bench set-redis-cache-host redis://redis:6379
bench set-redis-queue-host redis://redis:6379
bench set-redis-socketio-host redis://redis:6379

# Remove redis, watch from Procfile (we use container services)
sed -i '/redis/d' ./Procfile
sed -i '/watch/d' ./Procfile

mkdir -p archived/apps

APP_LINK="${BENCH_DIR}/apps/crm"
if [ -L "${APP_LINK}" ] && [ "$(readlink -f "${APP_LINK}")" = "${WORKSPACE_DIR}" ]; then
    echo "CRM app already linked, skipping get-app"
else
    bench get-app --overwrite --soft-link "${WORKSPACE_DIR}"
fi

if [ ! -f "${BENCH_DIR}/sites/${SITE_NAME}/site_config.json" ]; then
    bench new-site "${SITE_NAME}" \
        --force \
        --mariadb-root-password 123 \
        --admin-password admin \
        --no-mariadb-socket
fi

if ! bench --site "${SITE_NAME}" list-apps 2>/dev/null | grep -Fxq crm; then
    bench --site "${SITE_NAME}" install-app crm
fi

bench --site "${SITE_NAME}" set-config developer_mode 1
bench --site "${SITE_NAME}" set-config ignore_csrf 1
bench --site "${SITE_NAME}" set-config mute_emails 1
bench --site "${SITE_NAME}" set-config server_script_enabled 1
bench --site "${SITE_NAME}" clear-cache
bench use "${SITE_NAME}"

exec bench start
