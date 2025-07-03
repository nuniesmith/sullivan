#!/bin/bash

# Exit on any error
set -e

# Log function with timestamps
log() {
  echo "$(date +'%Y-%m-%d %H:%M:%S') - $1"
}

# Function to pull images in staggered groups
pull_images_staggered() {
  log "INFO: Pulling images in staggered groups to reduce resource pressure..."
  
  # Group 1: AI Services (smaller, less likely to conflict)
  log "INFO: Pulling AI services..."
  docker compose pull ollama open-webui || log "WARNING: Some AI service pulls failed, continuing..."
  sleep 5
  
  # Group 2: Database Services (critical, pull early)
  log "INFO: Pulling database services..."
  docker compose pull ytdl-mongo-db wiki-postgres || log "WARNING: Some database pulls failed, continuing..."
  sleep 5
  
  # Group 3: Media Services (large images, pull separately)
  log "INFO: Pulling media services..."
  docker compose pull emby || log "WARNING: Emby pull failed, continuing..."
  sleep 3
  docker compose pull jellyfin || log "WARNING: Jellyfin pull failed, continuing..."
  sleep 3
  docker compose pull plex || log "WARNING: Plex pull failed, continuing..."
  sleep 3
  docker compose pull audiobookshelf calibre calibre-web || log "WARNING: Some book service pulls failed, continuing..."
  sleep 5
  
  # Group 4: Download Management (important for media pipeline)
  log "INFO: Pulling download management services..."
  docker compose pull qbittorrent jackett flaresolverr || log "WARNING: Some download service pulls failed, continuing..."
  sleep 3
  docker compose pull sonarr radarr lidarr || log "WARNING: Some *arr service pulls failed, continuing..."
  sleep 3
  docker compose pull readarr.audio readarr.ebooks || log "WARNING: Some readarr service pulls failed, continuing..."
  sleep 3
  docker compose pull unpackerr doplarr || log "WARNING: Some support service pulls failed, continuing..."
  sleep 5
  
  # Group 5: Utility Services
  log "INFO: Pulling utility services..."
  docker compose pull filebot-node ytdl_material duplicati || log "WARNING: Some utility pulls failed, continuing..."
  sleep 3
  docker compose pull mealie grocy syncthing wiki || log "WARNING: Some app pulls failed, continuing..."
  sleep 3
  
  # Group 6: Monitoring Services (pull last)
  log "INFO: Pulling monitoring services..."
  docker compose pull watchtower || log "WARNING: Watchtower pull failed, continuing..."
  
  log "INFO: Staggered image pull completed."
}

# Function to restart services in dependency order
restart_services_ordered() {
  log "INFO: Restarting services in dependency order..."
  
  # Stop all services first
  log "INFO: Stopping all services..."
  docker compose down
  
  # Start databases first
  log "INFO: Starting database services..."
  docker compose up -d ytdl-mongo-db wiki-postgres
  sleep 10
  
  # Start AI services
  log "INFO: Starting AI services..."
  docker compose up -d ollama
  sleep 15  # Give Ollama time to initialize
  docker compose up -d open-webui
  sleep 5
  
  # Start media services (GPU-intensive, start with delays)
  log "INFO: Starting media services..."
  docker compose up -d emby
  sleep 10
  docker compose up -d jellyfin plex
  sleep 10
  
  # Start download infrastructure
  log "INFO: Starting download infrastructure..."
  docker compose up -d qbittorrent jackett flaresolverr
  sleep 10
  
  # Start *arr services
  log "INFO: Starting automation services..."
  docker compose up -d sonarr radarr lidarr readarr.audio readarr.ebooks
  sleep 10
  docker compose up -d unpackerr doplarr
  sleep 5
  
  # Start book services
  log "INFO: Starting book services..."
  docker compose up -d audiobookshelf calibre calibre-web
  sleep 5
  
  # Start remaining utility services
  log "INFO: Starting utility services..."
  docker compose up -d filebot-node ytdl_material duplicati mealie grocy syncthing
  sleep 5
  
  # Start wiki (depends on postgres)
  log "INFO: Starting wiki..."
  docker compose up -d wiki
  sleep 5
  
  # Start monitoring last
  log "INFO: Starting monitoring services..."
  docker compose up -d watchtower
  
  log "INFO: All services started successfully."
}

# Update Docker containers with improved error handling
update_docker_containers() {
  log "INFO: Starting Docker container update process..."

  # Step 1: Pull images in staggered groups
  pull_images_staggered

  # Step 2: Restart services in proper order
  restart_services_ordered

  # Step 3: Clean up unused resources
  log "INFO: Cleaning up unused Docker resources..."
  docker system prune -f || log "WARNING: Failed to clean up some unused resources, continuing..."

  log "INFO: Docker container update process completed successfully."
}

# Function to update a single service
update_single_service() {
  local service=$1
  log "INFO: Updating single service: $service"
  
  # Pull the image for the specific service
  log "INFO: Pulling image for $service..."
  docker compose pull "$service" || { log "ERROR: Failed to pull image for $service"; return 1; }
  
  # Restart the specific service
  log "INFO: Restarting $service..."
  docker compose up -d "$service" || { log "ERROR: Failed to restart $service"; return 1; }
  
  log "INFO: Successfully updated $service"
}

# Function to check Docker system resources
check_docker_resources() {
  log "INFO: Checking Docker system resources..."
  echo "=== Docker System Info ==="
  docker system df
  echo "=== Available Disk Space ==="
  df -h /var/lib/docker 2>/dev/null || df -h /
  echo "=== Memory Usage ==="
  free -h
}

# Main function
main() {
  case "${1:-all}" in
    "all")
      log "INFO: Starting full Docker update script..."
      check_docker_resources
      # Check if docker-compose is installed
      if ! command -v docker compose &>/dev/null; then
        log "ERROR: docker-compose is not installed or not in PATH."
        exit 1
      fi
      # Run the update process
      update_docker_containers
      ;;
    "single")
      if [ -z "$2" ]; then
        log "ERROR: Please specify a service name for single update. Usage: $0 single <service_name>"
        exit 1
      fi
      log "INFO: Starting single service update for: $2"
      update_single_service "$2"
      ;;
    "check")
      log "INFO: Checking Docker system resources..."
      check_docker_resources
      ;;
    "help"|"-h"|"--help")
      echo "Usage: $0 [all|single <service>|check|help]"
      echo "  all     - Update all services (default)"
      echo "  single  - Update a single service"
      echo "  check   - Check Docker system resources"
      echo "  help    - Show this help message"
      exit 0
      ;;
    *)
      log "ERROR: Unknown option: $1. Use 'help' for usage information."
      exit 1
      ;;
  esac
}

# Run the main function with all arguments
main "$@"
