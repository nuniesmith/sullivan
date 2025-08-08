#!/bin/bash

# Test script for doplarr connectivity
echo "Testing doplarr connectivity..."

# Source environment variables
if [ -f .env ]; then
    source .env
fi

echo "1. Testing Discord connection (check logs)..."
docker exec doplarr curl -s http://localhost:8080/health 2>/dev/null || echo "No health endpoint available"

echo ""
echo "2. Testing Radarr connection from doplarr container..."
docker exec doplarr curl -s -o /dev/null -w "HTTP Status: %{http_code}\n" http://radarr:7878/api/v3/system/status -H "X-Api-Key: ${RADARR_API_KEY}" 2>/dev/null || echo "Failed to connect to Radarr"

echo ""
echo "3. Testing Sonarr connection from doplarr container..."
docker exec doplarr curl -s -o /dev/null -w "HTTP Status: %{http_code}\n" http://sonarr:8989/api/v3/system/status -H "X-Api-Key: ${SONARR_API_KEY}" 2>/dev/null || echo "Failed to connect to Sonarr"

echo ""
echo "4. Checking doplarr logs for errors..."
docker logs doplarr --tail 10 | grep -i "error\|fatal\|exception" || echo "No recent errors found"

echo ""
echo "5. Testing internal network connectivity..."
docker exec doplarr ping -c 1 radarr >/dev/null 2>&1 && echo "✓ Can ping radarr" || echo "✗ Cannot ping radarr"
docker exec doplarr ping -c 1 sonarr >/dev/null 2>&1 && echo "✓ Can ping sonarr" || echo "✗ Cannot ping sonarr"

echo ""
echo "Test completed!"
