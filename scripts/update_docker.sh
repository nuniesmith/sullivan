#!/bin/bash

# This script updates all Docker services by pulling the latest images,
# stopping all services, starting them again, and cleaning up unused resources.

set -e

log() {
  echo "$(date +'%Y-%m-%d %H:%M:%S') - $1"
}

if ! command -v docker compose &>/dev/null; then
  log "ERROR: docker compose is not installed or not in PATH."
  exit 1
fi

log "INFO: Starting Docker update process..."

log "INFO: Pulling all images..."
docker compose pull

log "INFO: Stopping all services..."
docker compose down

log "INFO: Starting all services..."
docker compose up -d

log "INFO: Cleaning up unused Docker resources..."
docker system prune -f

log "INFO: Docker update process completed successfully."
