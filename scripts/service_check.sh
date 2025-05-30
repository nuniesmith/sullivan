#!/bin/bash

# Homelab Service Health Check Script
# Monitors all services behind Authelia authentication

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Configuration
DOMAIN="7gram.xyz"
SERVICES=(
    "auth:Auth Service"
    "emby:Emby Media Server"
    "jellyfin:Jellyfin Media Server"  
    "plex:Plex Media Server"
    "sonarr:Sonarr TV Shows"
    "radarr:Radarr Movies"
    "lidarr:Lidarr Music"
    "prowlarr:Prowlarr Indexer"
    "jackett:Jackett Indexer"
    "qbt:qBittorrent"
    "abs:AudioBookShelf"
    "calibre:Calibre E-books"
    "ollama:Ollama AI"
    "portainer:Portainer Docker"
    "homarr:Homarr Dashboard"
    "pihole:Pi-hole DNS"
)

# Function to check HTTP status
check_service() {
    local subdomain=$1
    local name=$2
    local url="https://${subdomain}.${DOMAIN}"
    
    # Check if service responds
    local status_code=$(curl -s -o /dev/null -w "%{http_code}" --connect-timeout 10 "$url")
    local response_time=$(curl -s -o /dev/null -w "%{time_total}" --connect-timeout 10 "$url")
    
    if [ "$status_code" -eq 200 ]; then
        printf "${GREEN}✓${NC} %-25s - OK (${response_time}s)\n" "$name"
        return 0
    elif [ "$status_code" -eq 302 ] || [ "$status_code" -eq 401 ]; then
        printf "${YELLOW}🔒${NC} %-25s - Protected by Auth (${response_time}s)\n" "$name"
        return 0
    elif [ "$status_code" -eq 000 ]; then
        printf "${RED}✗${NC} %-25s - Connection Failed\n" "$name"
        return 1
    else
        printf "${RED}✗${NC} %-25s - HTTP $status_code (${response_time}s)\n" "$name"
        return 1
    fi
}

# Function to check Docker containers
check_containers() {
    echo "Docker Container Status:"
    echo "========================"
    
    local containers=(
        "authelia:Authelia"
        "nginx:Nginx Proxy"
        "mysql:MySQL Database"
        "redis:Redis Cache"
        "emby:Emby"
        "jellyfin:Jellyfin"
        "plex:Plex"
        "sonarr:Sonarr"
        "radarr:Radarr"
        "lidarr:Lidarr"
        "prowlarr:Prowlarr"
        "qbittorrent:qBittorrent"
        "portainer:Portainer"
        "homarr:Homarr"
        "pihole:Pi-hole"
    )
    
    for container_info in "${containers[@]}"; do
        IFS=':' read -r container_name display_name <<< "$container_info"
        
        if docker ps --format "table {{.Names}}" | grep -q "^${container_name}$"; then
            local status=$(docker inspect --format='{{.State.Status}}' "$container_name" 2>/dev/null)
            local health=$(docker inspect --format='{{.State.Health.Status}}' "$container_name" 2>/dev/null)
            
            if [ "$status" = "running" ]; then
                if [ "$health" = "healthy" ] || [ "$health" = "<no value>" ]; then
                    printf "${GREEN}✓${NC} %-20s - Running\n" "$display_name"
                else
                    printf "${YELLOW}⚠${NC} %-20s - Running (Health: $health)\n" "$display_name"
                fi
            else
                printf "${RED}✗${NC} %-20s - $status\n" "$display_name"
            fi
        else
            printf "${RED}✗${NC} %-20s - Not Found\n" "$display_name"
        fi
    done
    echo
}

# Function to check Authelia specifically
check_authelia() {
    echo "Authelia Specific Checks:"
    echo "========================="
    
    # Check if Authelia is responding
    local auth_status=$(curl -s -o /dev/null -w "%{http_code}" "https://auth.${DOMAIN}")
    if [ "$auth_status" -eq 200 ]; then
        printf "${GREEN}✓${NC} Authelia Portal - Accessible\n"
    else
        printf "${RED}✗${NC} Authelia Portal - HTTP $auth_status\n"
    fi
    
    # Check auth verification endpoint
    local verify_status=$(curl -s -o /dev/null -w "%{http_code}" "https://auth.${DOMAIN}/api/verify")
    if [ "$verify_status" -eq 401 ] || [ "$verify_status" -eq 200 ]; then
        printf "${GREEN}✓${NC} Auth Verification - Working\n"
    else
        printf "${RED}✗${NC} Auth Verification - HTTP $verify_status\n"
    fi
    
    # Check database connection
    if docker logs authelia 2>&1 | tail -20 | grep -q "successfully connected to MySQL"; then
        printf "${GREEN}✓${NC} Database Connection - OK\n"
    elif docker logs authelia 2>&1 | tail -20 | grep -q "error"; then
        printf "${RED}✗${NC} Database Connection - Check logs\n"
    else
        printf "${YELLOW}?${NC} Database Connection - Unknown\n"
    fi
    
    # Check Redis connection  
    if docker logs authelia 2>&1 | tail -20 | grep -q "redis"; then
        printf "${GREEN}✓${NC} Redis Connection - OK\n"
    else
        printf "${YELLOW}?${NC} Redis Connection - Check logs\n"
    fi
    
    echo
}

# Function to show recent auth attempts
show_auth_activity() {
    echo "Recent Authentication Activity:"
    echo "==============================="
    
    # Show last 10 authentication attempts from Authelia logs
    docker logs authelia 2>&1 | grep -E "(Authentication attempt|Successful authentication|Failed authentication)" | tail -10 | while read line; do
        if echo "$line" | grep -q "Successful"; then
            echo -e "${GREEN}✓${NC} $line"
        elif echo "$line" | grep -q "Failed"; then
            echo -e "${RED}✗${NC} $line"
        else
            echo -e "${YELLOW}?${NC} $line"
        fi
    done
    echo
}

# Function to check SSL certificates
check_ssl() {
    echo "SSL Certificate Status:"
    echo "======================="
    
    local cert_info=$(echo | openssl s_client -servername "auth.${DOMAIN}" -connect "auth.${DOMAIN}:443" 2>/dev/null | openssl x509 -noout -dates 2>/dev/null)
    
    if [ $? -eq 0 ]; then
        local expiry=$(echo "$cert_info" | grep "notAfter" | cut -d= -f2)
        local expiry_date=$(date -d "$expiry" +%s 2>/dev/null)
        local current_date=$(date +%s)
        local days_until_expiry=$(( (expiry_date - current_date) / 86400 ))
        
        if [ $days_until_expiry -gt 30 ]; then
            printf "${GREEN}✓${NC} SSL Certificate - Valid ($days_until_expiry days remaining)\n"
        elif [ $days_until_expiry -gt 7 ]; then
            printf "${YELLOW}⚠${NC} SSL Certificate - Expires soon ($days_until_expiry days remaining)\n"
        else
            printf "${RED}✗${NC} SSL Certificate - Expires very soon ($days_until_expiry days remaining)\n"
        fi
    else
        printf "${RED}✗${NC} SSL Certificate - Unable to verify\n"
    fi
    echo
}

# Main execution
main() {
    echo "========================================"
    echo "  Homelab Service Health Check"
    echo "  $(date)"
    echo "========================================"
    echo
    
    # Check Docker containers first
    check_containers
    
    # Check Authelia specifically
    check_authelia
    
    # Check SSL certificates
    check_ssl
    
    # Check all services
    echo "Service Accessibility Check:"
    echo "============================"
    
    local failed_count=0
    local total_count=${#SERVICES[@]}
    
    for service_info in "${SERVICES[@]}"; do
        IFS=':' read -r subdomain name <<< "$service_info"
        if ! check_service "$subdomain" "$name"; then
            ((failed_count++))
        fi
    done
    
    echo
    echo "Summary:"
    echo "========"
    local success_count=$((total_count - failed_count))
    printf "Services accessible: ${GREEN}%d${NC}/%d\n" "$success_count" "$total_count"
    
    if [ $failed_count -gt 0 ]; then
        printf "Services with issues: ${RED}%d${NC}/%d\n" "$failed_count" "$total_count"
    fi
    
    echo
    
    # Show recent authentication activity
    show_auth_activity
    
    # Overall status
    if [ $failed_count -eq 0 ]; then
        echo -e "${GREEN}Overall Status: All systems operational${NC}"
        exit 0
    else
        echo -e "${RED}Overall Status: Some issues detected${NC}"
        exit 1
    fi
}

# Handle command line arguments
case "$1" in
    --containers|-c)
        check_containers
        ;;
    --authelia|-a)
        check_authelia
        ;;
    --ssl|-s)
        check_ssl
        ;;
    --activity|-l)
        show_auth_activity
        ;;
    --help|-h)
        echo "Usage: $0 [option]"
        echo "Options:"
        echo "  --containers, -c    Check Docker containers only"
        echo "  --authelia, -a      Check Authelia specifically"
        echo "  --ssl, -s           Check SSL certificates"
        echo "  --activity, -l      Show recent auth activity"
        echo "  --help, -h          Show this help"
        echo "  (no option)         Run full health check"
        ;;
    *)
        main
        ;;
esac