#!/bin/bash

# Docker Complete Cleanup Script
# This script removes all Docker resources including:
# - Containers (running and stopped)
# - Images
# - Networks
# - Volumes
# - Build cache

echo "=== Docker Cleanup Script ==="
echo "This will remove ALL Docker resources from your system."
echo "Warning: This action is irreversible and will delete all Docker data!"

# Stop all running containers
echo "Stopping all running containers..."
docker_running=$(docker ps -q)
if [ -n "$docker_running" ]; then
    docker stop $(docker ps -q)
    echo "All containers stopped."
else
    echo "No running containers found."
fi

# Remove all containers
echo "Removing all containers..."
docker_containers=$(docker ps -a -q)
if [ -n "$docker_containers" ]; then
    docker rm -f $(docker ps -a -q)
    echo "All containers removed."
else
    echo "No containers found to remove."
fi

# Remove all images
echo "Removing all Docker images..."
docker_images=$(docker images -q)
if [ -n "$docker_images" ]; then
    docker rmi -f $(docker images -q)
    echo "All images removed."
else
    echo "No images found to remove."
fi

# Remove all volumes
echo "Removing all Docker volumes..."
docker_volumes=$(docker volume ls -q)
if [ -n "$docker_volumes" ]; then
    docker volume rm $(docker volume ls -q)
    echo "All volumes removed."
else
    echo "No volumes found to remove."
fi

# Remove all networks (except default ones)
echo "Removing all custom Docker networks..."
docker_networks=$(docker network ls --filter type=custom -q)
if [ -n "$docker_networks" ]; then
    docker network rm $(docker network ls --filter type=custom -q)
    echo "All custom networks removed."
else
    echo "No custom networks found to remove."
fi

# Clean up build cache
echo "Cleaning up build cache..."
docker builder prune -f
echo "Build cache cleaned."

# Optional: System prune (uncomment if needed)
echo "Performing system prune..."
docker system prune -a -f --volumes
echo "System prune complete."

echo "=== Docker Cleanup Complete ==="
echo "All Docker resources have been removed from your system."