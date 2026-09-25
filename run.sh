#!/usr/bin/env bash

# SULLIVAN stack management script
# Media & Intensive Services - powerful server handling media, downloads, AI, and user applications
#
# Usage: ./run.sh <command> [service...]
#   Commands: start, stop, restart, rebuild, status, logs, health, cleanup, secrets

set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# Paths
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$SCRIPT_DIR"

# Docker networks used by Sullivan
SULLIVAN_NETWORKS=(
    "frontend"
    "media"
    "download"
    "books"
    "database"
    "monitoring"
    "utilities"
)

# List of services in dependency order (databases first, then base services, then dependent services)
SERVICES=(
    # Database services (must start first)
    "ytdl-mongo-db" "wiki-postgres"
    # Download infrastructure
    "qbittorrent" "prowlarr" "flaresolverr"
    # Media management (ARR stack - depends on qbittorrent/prowlarr)
    "sonarr" "radarr" "lidarr" "bazarr"
    # Post-processing (depends on ARR stack)
    "unpackerr" "seerr" "recyclarr"
    # Media servers
    "emby" "plex"
    # Media processing
    "tdarr"
    # Book management
    "calibre" "calibre-web"
    # Utility services
    "filebot-node" "ytdl_material" "duplicati" "mealie" "grocy" "wiki"
)

COMPOSE_CMD=""

# =============================================================================
# Logging Functions
# =============================================================================

log() {
    local level="$1"; shift
    local timestamp=$(date '+%H:%M:%S')
    case "$level" in
        INFO)  echo -e "${GREEN}[$timestamp INFO]${NC} $*" ;;
        WARN)  echo -e "${YELLOW}[$timestamp WARN]${NC} $*" ;;
        ERROR) echo -e "${RED}[$timestamp ERROR]${NC} $*" ;;
        DEBUG) echo -e "${BLUE}[$timestamp DEBUG]${NC} $*" ;;
        HEADER)
            echo ""
            echo -e "${BOLD}${CYAN}=== $* ===${NC}"
            echo ""
            ;;
    esac
}

# =============================================================================
# Prerequisites & Environment Detection
# =============================================================================

detect_environment() {
    # Cloud/container markers
    if [[ -f /etc/cloud-id || -f /var/lib/cloud/data/instance-id || -n "${AWS_INSTANCE_ID:-}" || -n "${GCP_PROJECT:-}" || -n "${AZURE_SUBSCRIPTION_ID:-}" ]]; then
        echo cloud; return
    fi
    if [[ -f /.dockerenv || -n "${KUBERNETES_SERVICE_HOST:-}" ]]; then
        echo container; return
    fi
    # Memory check
    if command -v free >/dev/null 2>&1; then
        local mem; mem=$(free -m | awk '/^Mem:/{print $2}')
        if [[ -n "$mem" && "$mem" -lt 2048 ]]; then echo resource_constrained; return; fi
    fi
    echo server
}

check_prerequisites() {
    log INFO "Checking prerequisites..."

    if ! command -v docker >/dev/null 2>&1; then
        log ERROR "Docker is not installed"
        exit 1
    fi

    if ! docker info >/dev/null 2>&1; then
        log ERROR "Docker daemon is not running"
        exit 1
    fi

    if command -v docker-compose >/dev/null 2>&1; then
        COMPOSE_CMD="docker-compose"
    elif docker compose version >/dev/null 2>&1; then
        COMPOSE_CMD="docker compose"
    else
        log ERROR "Docker Compose is not available"
        exit 1
    fi

    log INFO "Docker: $(docker --version | cut -d' ' -f3 | tr -d ',')"
    log INFO "Compose: $($COMPOSE_CMD version --short 2>/dev/null || $COMPOSE_CMD version | head -1)"
}

# =============================================================================
# Docker Network Management
# =============================================================================

setup_networks() {
    log INFO "Setting up Docker networks..."

    for network in "${SULLIVAN_NETWORKS[@]}"; do
        if ! docker network inspect "$network" >/dev/null 2>&1; then
            log INFO "Creating network: $network"
            docker network create "$network" --driver bridge >/dev/null 2>&1 || {
                log WARN "Failed to create network $network (may already exist)"
            }
        else
            log DEBUG "Network $network already exists"
        fi
    done

    log INFO "Docker networks ready"
}

cleanup_networks() {
    log INFO "Cleaning up unused Docker networks..."

    # Remove Sullivan-specific networks if they're not in use
    for network in "${SULLIVAN_NETWORKS[@]}"; do
        if docker network inspect "$network" >/dev/null 2>&1; then
            # Check if any containers are using this network
            local containers
            containers=$(docker network inspect "$network" --format '{{range .Containers}}{{.Name}} {{end}}' 2>/dev/null || echo "")

            if [[ -z "$containers" ]]; then
                log INFO "Removing unused network: $network"
                docker network rm "$network" >/dev/null 2>&1 || true
            else
                log DEBUG "Network $network still in use by: $containers"
            fi
        fi
    done

    # Prune any dangling networks
    docker network prune -f >/dev/null 2>&1 || true
    log INFO "Network cleanup complete"
}

# =============================================================================
# Docker Cleanup Functions
# =============================================================================

cleanup_orphans() {
    log INFO "Cleaning up orphan containers..."

    local cmd_args
    cmd_args=$(build_compose_cmd)

    # Remove orphan containers from compose
    $COMPOSE_CMD $cmd_args down --remove-orphans 2>/dev/null || true

    # Find and remove any stopped containers with sullivan-related names
    local orphans
    orphans=$(docker ps -a --filter "status=exited" --filter "status=dead" --format "{{.Names}}" | grep -E "sullivan|emby|plex|sonarr|radarr|lidarr|qbittorrent|prowlarr|bazarr|calibre|mealie|grocy|wiki|duplicati|ytdl|filebot|seerr|unpackerr|flaresolverr|tdarr|recyclarr" || true)

    if [[ -n "$orphans" ]]; then
        log INFO "Removing orphan containers:"
        for container in $orphans; do
            log INFO "  - $container"
            docker rm -f "$container" 2>/dev/null || true
        done
    fi

    log INFO "Orphan cleanup complete"
}

cleanup_volumes() {
    log INFO "Cleaning up dangling volumes..."
    docker volume prune -f >/dev/null 2>&1 || true
    log INFO "Volume cleanup complete"
}

cleanup_images() {
    log INFO "Cleaning up unused images..."
    docker image prune -f >/dev/null 2>&1 || true
    log INFO "Image cleanup complete"
}

full_cleanup() {
    log HEADER "Full Docker Cleanup"

    cleanup_orphans
    cleanup_networks
    cleanup_volumes
    cleanup_images

    # Docker system prune (careful - removes all unused data)
    log INFO "Running Docker system prune..."
    docker system prune -f >/dev/null 2>&1 || true

    log INFO "Full cleanup complete"

    # Show disk usage
    echo ""
    log INFO "Docker disk usage:"
    docker system df
}

# =============================================================================
# Compose File & Environment
# =============================================================================

get_compose_file() {
    echo "$PROJECT_ROOT/docker-compose.yml"
}

get_env_file() {
    echo "$PROJECT_ROOT/.env"
}

build_compose_cmd() {
    local compose_file
    local env_file
    compose_file=$(get_compose_file)
    env_file=$(get_env_file)

    local cmd="-f $compose_file"
    if [[ -f "$env_file" ]]; then
        cmd="$cmd --env-file $env_file"
    fi

    echo "$cmd"
}

# =============================================================================
# Secret Generation
# =============================================================================

generate_secret() {
    local length="${1:-32}"
    if command -v openssl >/dev/null 2>&1; then
        openssl rand -hex "$((length/2))"
    else
        head -c "$length" /dev/urandom | base64 | tr -d '=+/' | head -c "$length"
    fi
}

generate_password() {
    if command -v openssl >/dev/null 2>&1; then
        openssl rand -base64 12 | tr -d '=+/' | head -c 16
    else
        head -c 12 /dev/urandom | base64 | tr -d '=+/' | head -c 16
    fi
}

update_env_var() {
    local env_file="$1"
    local var_name="$2"
    local var_value="$3"

    local current_value
    current_value=$(grep "^${var_name}=" "$env_file" 2>/dev/null | cut -d'=' -f2- || echo "")

    # Skip if already has a real value (not a placeholder)
    if [[ -n "$current_value" && "$current_value" != "your_"* && "$current_value" != "changeme_"* && "$current_value" != "COPY_FROM_"* && "$current_value" != "PLACEHOLDER_"* ]]; then
        log DEBUG "$var_name already configured, skipping"
        return
    fi

    if grep -q "^${var_name}=" "$env_file" 2>/dev/null; then
        sed -i "s|^${var_name}=.*|${var_name}=${var_value}|" "$env_file"
    else
        echo "${var_name}=${var_value}" >> "$env_file"
    fi
    log INFO "Updated $var_name"
}

generate_secrets() {
    local env_file
    env_file=$(get_env_file)

    # Create .env file if it doesn't exist
    if [[ ! -f "$env_file" ]]; then
        log INFO ".env file not found, creating it first..."
        create_env_file
    fi

    log HEADER "Generating Secrets"

    # Backup existing .env
    cp "$env_file" "$env_file.bak.$(date +%Y%m%d_%H%M%S)"

    # Generate database passwords
    update_env_var "$env_file" "WIKI_DB_PASSWORD" "$(generate_password)"
    update_env_var "$env_file" "MEALIE_DB_PASSWORD" "$(generate_password)"
    update_env_var "$env_file" "FILEBOT_PASSWORD" "$(generate_password)"
    update_env_var "$env_file" "DUPLICATI_ENCRYPTION_KEY" "$(generate_password)"

    # Set API key placeholders (will be replaced by GitHub Actions secrets)
    update_env_var "$env_file" "SONARR_API_KEY" "PLACEHOLDER_SET_IN_GITHUB_SECRETS"
    update_env_var "$env_file" "RADARR_API_KEY" "PLACEHOLDER_SET_IN_GITHUB_SECRETS"
    update_env_var "$env_file" "LIDARR_API_KEY" "PLACEHOLDER_SET_IN_GITHUB_SECRETS"
    update_env_var "$env_file" "PROWLARR_API_KEY" "PLACEHOLDER_SET_IN_GITHUB_SECRETS"

    log INFO "Secrets generated!"
    echo ""
    log INFO "Database passwords and encryption keys have been auto-generated."
    log WARN "API keys will be injected from GitHub Actions secrets during deployment."
    log WARN "If running manually, update these in .env:"
    log WARN "  SONARR_API_KEY, RADARR_API_KEY, LIDARR_API_KEY, PROWLARR_API_KEY"
}

# =============================================================================
# Environment File Creation
# =============================================================================

create_env_file() {
    local env_file
    env_file=$(get_env_file)

    if [[ -f "$env_file" ]]; then
        log INFO ".env file exists"
        return 0
    fi

    log INFO "Creating .env file..."

    cat > "$env_file" <<'EOF'
# =============================================================================
# SULLIVAN - Environment Configuration
# =============================================================================
# Generated by run.sh - Update values as needed

# Core Settings
TZ=America/Toronto
PUID=1000
PGID=100
LIBVA_DRIVER_NAME=iHD

# =============================================================================
# Media Paths (Update to match your storage)
# =============================================================================
MEDIA_PATH=/mnt/media
MEDIA_PATH_MOVIES=/mnt/media/movies
MEDIA_PATH_SHOWS=/mnt/media/shows
MEDIA_PATH_MUSIC=/mnt/media/music
MEDIA_PATH_MUSIC_VIDEOS=/mnt/media/music_videos
MEDIA_PATH_EDU=/mnt/media/edu
MEDIA_PATH_BOOKS=/mnt/media/books
MEDIA_PATH_AUDIOBOOKS=/mnt/media/books/audiobooks
MEDIA_PATH_EBOOKS=/mnt/media/ebooks

# Download Paths (OS drive for fast I/O, *arr apps move to /mnt/media after processing)
DOWNLOAD_PATH_COMPLETE=/media/qbittorrent/complete
DOWNLOAD_PATH_INCOMPLETE=/media/qbittorrent/incomplete

# YouTube Paths
YOUTUBE_AUDIO_PATH=/mnt/media/youtube/audio
YOUTUBE_VIDEO_PATH=/mnt/media/youtube/video

# Backup
BACKUP_DESTINATION=/mnt/media/backup

# =============================================================================
# API Keys (Injected from GitHub Secrets during deployment)
# =============================================================================
SONARR_API_KEY=PLACEHOLDER_SET_IN_GITHUB_SECRETS
RADARR_API_KEY=PLACEHOLDER_SET_IN_GITHUB_SECRETS
LIDARR_API_KEY=PLACEHOLDER_SET_IN_GITHUB_SECRETS
PROWLARR_API_KEY=PLACEHOLDER_SET_IN_GITHUB_SECRETS

# =============================================================================
# Seerr (Media Requests - configure via web UI at :5055)
# =============================================================================

# =============================================================================
# Service Credentials (Auto-generated by run.sh secrets)
# =============================================================================
FILEBOT_USER=admin
FILEBOT_PASSWORD=changeme_filebot_password

# =============================================================================
# Database Passwords (Auto-generated by run.sh secrets)
# =============================================================================
WIKI_DB_USER=wikijs
WIKI_DB_NAME=wiki
WIKI_DB_PASSWORD=changeme_wiki_password
MEALIE_DB_PASSWORD=changeme_mealie_password

# =============================================================================
# Backup Encryption (Auto-generated by run.sh secrets)
# =============================================================================
DUPLICATI_ENCRYPTION_KEY=changeme_duplicati_key

EOF

    log INFO ".env file created at $env_file"
    log WARN "Please review and update the configuration!"

    # Generate initial secrets
    generate_secrets
}

# =============================================================================
# Media Path Management
# =============================================================================

create_directories() {
    log INFO "Checking media directories..."

    local env_file
    env_file=$(get_env_file)

    if [[ -f "$env_file" ]]; then
        source "$env_file"
    fi

    local dirs=(
        "${MEDIA_PATH:-/mnt/media}"
        "${MEDIA_PATH_MOVIES:-/mnt/media/movies}"
        "${MEDIA_PATH_SHOWS:-/mnt/media/shows}"
        "${MEDIA_PATH_MUSIC:-/mnt/media/music}"
        "${MEDIA_PATH_BOOKS:-/mnt/media/books}"
        "${DOWNLOAD_PATH_COMPLETE:-/media/qbittorrent/complete}"
        "${DOWNLOAD_PATH_INCOMPLETE:-/media/qbittorrent/incomplete}"
        "${YOUTUBE_AUDIO_PATH:-/mnt/media/youtube/audio}"
        "${YOUTUBE_VIDEO_PATH:-/mnt/media/youtube/video}"
    )

    local missing=0
    for dir in "${dirs[@]}"; do
        if [[ ! -d "$dir" ]]; then
            if mkdir -p "$dir" 2>/dev/null; then
                log INFO "Created: $dir"
            else
                log WARN "Cannot create: $dir (check permissions)"
                missing=$((missing + 1))
            fi
        fi
    done

    if [[ $missing -gt 0 ]]; then
        log WARN "$missing directories could not be created - ensure they exist on the host"
        log WARN "Continuing anyway (directories may already exist or be mounted)..."
    else
        log INFO "All media directories ready"
    fi
    # Don't fail on missing directories - they may be pre-existing mounts
    return 0
}

# =============================================================================
# Stack Operations
# =============================================================================

pull_images() {
    local services=("$@")
    log HEADER "Pulling Docker Images"

    local cmd_args
    cmd_args=$(build_compose_cmd)

    if [[ ${#services[@]} -eq 0 || "${services[*]}" == "all" ]]; then
        $COMPOSE_CMD $cmd_args pull --ignore-pull-failures 2>&1 | grep -v "Pulling" || true
    else
        $COMPOSE_CMD $cmd_args pull --ignore-pull-failures "${services[@]}" 2>&1 | grep -v "Pulling" || true
    fi

    log INFO "Image pull complete"
}

start_services() {
    local services=("$@")

    log HEADER "Starting Sullivan Services"

    # Setup
    create_env_file
    setup_networks
    create_directories

    local cmd_args
    cmd_args=$(build_compose_cmd)

    # Clean orphans first
    log INFO "Cleaning up before start..."
    $COMPOSE_CMD $cmd_args down --remove-orphans 2>/dev/null || true

    # Start services
    if [[ ${#services[@]} -eq 0 || "${services[*]}" == "all" ]]; then
        log INFO "Starting all services..."
        $COMPOSE_CMD $cmd_args up -d
    else
        log INFO "Starting services: ${services[*]}"
        $COMPOSE_CMD $cmd_args up -d "${services[@]}"
    fi

    log INFO "Waiting for services to initialize..."
    sleep 5

    show_status
    show_endpoints
}

stop_services() {
    local services=("$@")

    log HEADER "Stopping Sullivan Services"

    local cmd_args
    cmd_args=$(build_compose_cmd)

    if [[ ${#services[@]} -eq 0 || "${services[*]}" == "all" ]]; then
        log INFO "Stopping all services..."
        $COMPOSE_CMD $cmd_args down --remove-orphans
        cleanup_networks
    else
        log INFO "Stopping services: ${services[*]}"
        $COMPOSE_CMD $cmd_args stop "${services[@]}"
    fi

    log INFO "Services stopped"
}

restart_services() {
    local services=("$@")

    log HEADER "Restarting Sullivan Services"

    local cmd_args
    cmd_args=$(build_compose_cmd)

    if [[ ${#services[@]} -eq 0 || "${services[*]}" == "all" ]]; then
        log INFO "Restarting all services..."
        $COMPOSE_CMD $cmd_args restart
    else
        log INFO "Restarting services: ${services[*]}"
        $COMPOSE_CMD $cmd_args restart "${services[@]}"
    fi

    sleep 3
    show_status
}

rebuild_services() {
    local services=("$@")

    log HEADER "Rebuilding Sullivan Services"
    log INFO "This will stop, pull new images, and restart services"

    local cmd_args
    cmd_args=$(build_compose_cmd)

    # Stop services
    if [[ ${#services[@]} -eq 0 || "${services[*]}" == "all" ]]; then
        log INFO "Stopping all services..."
        $COMPOSE_CMD $cmd_args down --remove-orphans
    else
        log INFO "Stopping services: ${services[*]}"
        $COMPOSE_CMD $cmd_args stop "${services[@]}"
    fi

    # Cleanup
    cleanup_orphans
    cleanup_images

    # Setup networks
    setup_networks

    # Pull fresh images
    pull_images "${services[@]}"

    # Start services
    if [[ ${#services[@]} -eq 0 || "${services[*]}" == "all" ]]; then
        log INFO "Starting all services..."
        $COMPOSE_CMD $cmd_args up -d
    else
        log INFO "Starting services: ${services[*]}"
        $COMPOSE_CMD $cmd_args up -d "${services[@]}"
    fi

    log INFO "Waiting for services to initialize..."
    sleep 5

    show_status
    show_endpoints
}

# =============================================================================
# Status & Health
# =============================================================================

show_status() {
    log HEADER "Service Status"

    local cmd_args
    cmd_args=$(build_compose_cmd)

    $COMPOSE_CMD $cmd_args ps --format "table {{.Name}}\t{{.Status}}\t{{.Ports}}" 2>/dev/null || \
    $COMPOSE_CMD $cmd_args ps
}

show_logs() {
    local services=("$@")

    local cmd_args
    cmd_args=$(build_compose_cmd)

    if [[ ${#services[@]} -eq 0 || "${services[*]}" == "all" ]]; then
        $COMPOSE_CMD $cmd_args logs -f --tail=100
    else
        $COMPOSE_CMD $cmd_args logs -f --tail=100 "${services[@]}"
    fi
}

health_check() {
    log HEADER "Health Check"

    local cmd_args
    cmd_args=$(build_compose_cmd)

    # Get all running containers
    local containers
    containers=$($COMPOSE_CMD $cmd_args ps -q 2>/dev/null || echo "")

    if [[ -z "$containers" ]]; then
        log WARN "No containers running"
        return 1
    fi

    local healthy=0
    local unhealthy=0
    local no_check=0

    for container_id in $containers; do
        local name
        local health
        name=$(docker inspect --format='{{.Name}}' "$container_id" | sed 's/^\///')
        health=$(docker inspect --format='{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$container_id" 2>/dev/null || echo "unknown")

        case "$health" in
            healthy)
                echo -e "  ${GREEN}✓${NC} $name: healthy"
                ((healthy++))
                ;;
            unhealthy)
                echo -e "  ${RED}✗${NC} $name: unhealthy"
                ((unhealthy++))
                ;;
            starting)
                echo -e "  ${YELLOW}◐${NC} $name: starting"
                ((no_check++))
                ;;
            none)
                local state
                state=$(docker inspect --format='{{.State.Status}}' "$container_id" 2>/dev/null || echo "unknown")
                if [[ "$state" == "running" ]]; then
                    echo -e "  ${BLUE}●${NC} $name: running (no healthcheck)"
                else
                    echo -e "  ${YELLOW}○${NC} $name: $state"
                fi
                ((no_check++))
                ;;
            *)
                echo -e "  ${YELLOW}?${NC} $name: $health"
                ((no_check++))
                ;;
        esac
    done

    echo ""
    log INFO "Summary: $healthy healthy, $unhealthy unhealthy, $no_check other"

    [[ $unhealthy -eq 0 ]]
}

show_endpoints() {
    echo ""
    log HEADER "Service Endpoints"

    echo "Media Servers:"
    echo "  Emby:            http://localhost:8096"
    echo "  Plex:            http://localhost:32400/web"
    echo ""
    echo "Download Management:"
    echo "  qBittorrent:     http://localhost:8080"
    echo "  Prowlarr:        http://localhost:9696"
    echo "  Sonarr:          http://localhost:8989"
    echo "  Radarr:          http://localhost:7878"
    echo "  Lidarr:          http://localhost:8686"
    echo "  Bazarr:          http://localhost:6767"
    echo "  Seerr:           http://localhost:5055"
    echo "  Tdarr:           http://localhost:8265"
    echo ""
    echo "Books:"
    echo "  Calibre:         http://localhost:8083"
    echo "  Calibre-Web:     http://localhost:8082"
    echo ""
    echo "Utilities:"
    echo "  Mealie:          http://localhost:9925"
    echo "  Wiki.js:         http://localhost:8090"
    echo "  Grocy:           http://localhost:9283"
    echo "  Duplicati:       http://localhost:8200"
    echo "  YouTube DL:      http://localhost:8998"
    echo ""
}

show_info() {
    log HEADER "System Information"

    echo "Environment: $(detect_environment)"
    echo "Hostname:    $(hostname)"
    echo "User:        $USER"
    echo "Docker:      $(docker --version | cut -d' ' -f3 | tr -d ',')"
    echo "Compose:     $($COMPOSE_CMD version --short 2>/dev/null || echo 'unknown')"

    if command -v free >/dev/null 2>&1; then
        echo "Memory:      $(free -h | awk '/^Mem:/{print $2}') total, $(free -h | awk '/^Mem:/{print $7}') available"
    fi

    echo "Disk:        $(df -h / | awk 'NR==2{print $4}') available on /"

    echo ""
    log INFO "Docker disk usage:"
    docker system df 2>/dev/null || true
}

# =============================================================================
# Usage & Help
# =============================================================================

usage() {
    cat <<EOF
${BOLD}SULLIVAN${NC} - Media Infrastructure Management

${BOLD}Usage:${NC}
    $(basename "$0") <command> [services...]

${BOLD}Commands:${NC}
    ${GREEN}start${NC}       Start services (creates .env if needed)
    ${GREEN}stop${NC}        Stop services and cleanup
    ${GREEN}restart${NC}     Restart services
    ${GREEN}rebuild${NC}     Stop, pull new images, and start fresh
    ${GREEN}status${NC}      Show service status
    ${GREEN}logs${NC}        Tail service logs (Ctrl+C to exit)
    ${GREEN}health${NC}      Run health checks
    ${GREEN}pull${NC}        Pull latest images without starting
    ${GREEN}cleanup${NC}     Full Docker cleanup (orphans, networks, images)
    ${GREEN}secrets${NC}     Generate/update secrets in .env
    ${GREEN}info${NC}        Show system and Docker info
    ${GREEN}help${NC}        Show this help

${BOLD}Services:${NC}
    Specify service names to target specific services, or omit for all.

    Media:      emby, plex
    Downloads:  qbittorrent, prowlarr, sonarr, radarr, lidarr, bazarr, flaresolverr
    Requests:   seerr
    Processing: tdarr, recyclarr, unpackerr
    Books:      calibre, calibre-web
    Utils:      mealie, wiki, grocy, duplicati, filebot-node
    Other:      ytdl_material

${BOLD}Examples:${NC}
    $(basename "$0") start                    # Start all services
    $(basename "$0") start emby sonarr        # Start only emby and sonarr
    $(basename "$0") stop                     # Stop all services
    $(basename "$0") rebuild sonarr radarr    # Rebuild ARR services
    $(basename "$0") logs emby                # Tail emby logs
    $(basename "$0") cleanup                  # Full Docker cleanup

${BOLD}Files:${NC}
    Config:     $PROJECT_ROOT/.env
    Compose:    $PROJECT_ROOT/docker-compose.yml

EOF
}

# =============================================================================
# Main
# =============================================================================

main() {
    # Must have at least one argument
    if [[ $# -lt 1 ]]; then
        usage
        exit 1
    fi

    # Get command
    local command="$1"
    shift

    # Remaining args are services
    local services=("$@")

    # Change to project directory
    cd "$PROJECT_ROOT"

    # Check prerequisites for most commands
    case "$command" in
        help|-h|--help)
            usage
            exit 0
            ;;
        *)
            check_prerequisites
            ;;
    esac

    # Execute command
    case "$command" in
        start)
            start_services "${services[@]}"
            ;;
        stop)
            stop_services "${services[@]}"
            ;;
        restart)
            restart_services "${services[@]}"
            ;;
        rebuild)
            rebuild_services "${services[@]}"
            ;;
        status|ps)
            show_status
            ;;
        logs|log)
            show_logs "${services[@]}"
            ;;
        health|check)
            health_check
            ;;
        pull)
            pull_images "${services[@]}"
            ;;
        cleanup|clean)
            full_cleanup
            ;;
        secrets)
            create_env_file
            generate_secrets
            ;;
        info)
            show_info
            ;;
        endpoints|urls)
            show_endpoints
            ;;
        *)
            log ERROR "Unknown command: $command"
            echo ""
            usage
            exit 1
            ;;
    esac
}

main "$@"
