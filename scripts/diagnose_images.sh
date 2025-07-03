#!/bin/bash

# Docker Compose Image Diagnostic Script
# This script checks each image individually to identify problematic ones

log() {
  echo "$(date +'%Y-%m-%d %H:%M:%S') - $1"
}

check_individual_images() {
  log "INFO: Checking individual Docker images for architecture compatibility..."
  
  # Extract all unique images from docker-compose.yml
  images=$(grep -E "^\s*image:" /home/jordan/sullivan/docker-compose.yml | awk '{print $2}' | sort -u)
  
  failed_images=()
  
  while IFS= read -r image; do
    if [ -n "$image" ]; then
      log "INFO: Testing pull for image: $image"
      if docker pull "$image" &>/dev/null; then
        log "SUCCESS: $image pulled successfully"
      else
        log "FAILED: $image failed to pull"
        failed_images+=("$image")
      fi
    fi
  done <<< "$images"
  
  if [ ${#failed_images[@]} -gt 0 ]; then
    log "ERROR: The following images failed to pull:"
    for img in "${failed_images[@]}"; do
      echo "  - $img"
    done
    
    log "INFO: Attempting to get detailed error for first failed image..."
    docker pull "${failed_images[0]}"
  else
    log "SUCCESS: All images can be pulled successfully"
  fi
}

# Check if we're in the right directory
if [ ! -f "docker-compose.yml" ]; then
  log "ERROR: docker-compose.yml not found. Please run this script from the sullivan directory."
  exit 1
fi

check_individual_images
