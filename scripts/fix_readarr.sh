#!/bin/bash

# Quick fix script for readarr architecture issues

log() {
  echo "$(date +'%Y-%m-%d %H:%M:%S') - $1"
}

log "INFO: Checking and fixing readarr containers..."

# Stop the problematic containers
log "INFO: Stopping readarr containers..."
docker compose stop readarr.audio readarr.ebooks

# Remove the old containers (keeps data in volumes)
log "INFO: Removing old containers..."
docker compose rm -f readarr.audio readarr.ebooks

# Pull the working images
log "INFO: Pulling hotio readarr images..."
docker pull hotio/readarr:latest

# Start the containers with new images
log "INFO: Starting readarr containers with fixed images..."
docker compose up -d readarr.audio readarr.ebooks

# Check if they're running
log "INFO: Checking container status..."
docker compose ps readarr.audio readarr.ebooks

log "INFO: Readarr fix completed!"
log "INFO: You can access them at:"
log "INFO: - Audiobooks: http://localhost:8787"
log "INFO: - Ebooks: http://localhost:8585"
