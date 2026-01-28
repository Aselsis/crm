#!/bin/bash
# CRM Update Script
# Usage: ./update.sh [--migrate] [--build]

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMPOSE_FILE="${SCRIPT_DIR}/docker-compose.prod.yml"

# Parse arguments
DO_MIGRATE=false
DO_BUILD=false

for arg in "$@"; do
    case $arg in
        --migrate) DO_MIGRATE=true ;;
        --build) DO_BUILD=true ;;
        --all) DO_MIGRATE=true; DO_BUILD=true ;;
        *) echo "Unknown option: $arg"; exit 1 ;;
    esac
done

# If no args, do both
if [ "$DO_MIGRATE" = false ] && [ "$DO_BUILD" = false ]; then
    DO_MIGRATE=true
    DO_BUILD=true
fi

echo "=== CRM Update Script ==="

# Pull latest code
echo "Pulling latest code..."
cd "${SCRIPT_DIR}/.."
git pull

# Build frontend assets
if [ "$DO_BUILD" = true ]; then
    echo "Building frontend assets..."
    docker compose -f "$COMPOSE_FILE" exec -T frappe bash -c "cd /home/frappe/frappe-bench && bench build --app crm"
fi

# Run migrations
if [ "$DO_MIGRATE" = true ]; then
    echo "Running migrations..."
    docker compose -f "$COMPOSE_FILE" exec -T frappe bash -c "cd /home/frappe/frappe-bench && bench --site \${SITE_NAME:-crm.localhost} migrate"
fi

# Clear cache
echo "Clearing cache..."
docker compose -f "$COMPOSE_FILE" exec -T frappe bash -c "cd /home/frappe/frappe-bench && bench --site \${SITE_NAME:-crm.localhost} clear-cache"

# Restart frappe
echo "Restarting services..."
docker compose -f "$COMPOSE_FILE" restart frappe

echo "=== Update complete! ==="
