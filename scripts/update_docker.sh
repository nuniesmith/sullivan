#!/bin/bash

# Exit on any error
set -e

# Log function with timestamps
log() {
  echo "$(date +'%Y-%m-%d %H:%M:%S') - $1"
}

# Update Docker containers
update_docker_containers() {
  log "INFO: Starting Docker container update process..."

  # Step 1: Pull the latest images for all services in the Compose file
  log "INFO: Pulling the latest images for all services..."
  docker compose pull || { log "ERROR: Failed to pull images."; exit 1; }

  # Step 2: Recreate containers with the latest images
  log "INFO: Recreating containers with the latest images..."
  docker compose down
  docker compose up -d || { log "ERROR: Failed to recreate containers."; exit 1; }

  # Step 3: Clean up unused resources
  log "INFO: Cleaning up unused Docker resources..."
  docker system prune -f || { log "ERROR: Failed to clean up unused resources."; exit 1; }

  log "INFO: Docker container update process completed successfully."
}

# Main function
main() {
  log "INFO: Starting Docker update script..."

  # Check if docker-compose is installed
  if ! command -v docker compose &>/dev/null; then
    log "ERROR: docker-compose is not installed or not in PATH."
    exit 1
  fi

  # Run the update process
  update_docker_containers
}

# Run the main function
main
