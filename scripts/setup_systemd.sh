#!/bin/bash

# Sullivan Server Setup Script
# This script sets up systemd services for automated Docker updates and cleanup

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Log function
log() {
    echo -e "${GREEN}[$(date +'%Y-%m-%d %H:%M:%S')]${NC} $1"
}

warn() {
    echo -e "${YELLOW}[$(date +'%Y-%m-%d %H:%M:%S')] WARNING:${NC} $1"
}

error() {
    echo -e "${RED}[$(date +'%Y-%m-%d %H:%M:%S')] ERROR:${NC} $1"
}

# Check if running as the correct user
if [ "$USER" != "actions_user" ]; then
    warn "This script should be run as 'actions_user'. Current user: $USER"
    read -p "Continue anyway? (y/N): " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        exit 1
    fi
fi

# Get the script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SULLIVAN_DIR="$(dirname "$SCRIPT_DIR")"

log "Setting up Sullivan server automation..."
log "Sullivan directory: $SULLIVAN_DIR"

# Check if we have sudo access
if ! sudo -n true 2>/dev/null; then
    error "This script requires sudo access. Please ensure the user has sudo privileges."
    exit 1
fi

# Make sure scripts are executable
log "Making scripts executable..."
chmod +x "$SULLIVAN_DIR/scripts/"*.sh

# Install systemd services
log "Installing systemd services..."

# Copy service files
sudo cp "$SULLIVAN_DIR/systemd/sullivan-update.service" /etc/systemd/system/
sudo cp "$SULLIVAN_DIR/systemd/sullivan-update.timer" /etc/systemd/system/
sudo cp "$SULLIVAN_DIR/systemd/sullivan-cleanup.service" /etc/systemd/system/
sudo cp "$SULLIVAN_DIR/systemd/sullivan-cleanup.timer" /etc/systemd/system/

# Update the service files with the correct paths and user
log "Updating service file paths..."
sudo sed -i "s|/home/actions_user/sullivan|$SULLIVAN_DIR|g" /etc/systemd/system/sullivan-update.service
sudo sed -i "s|User=actions_user|User=$USER|g" /etc/systemd/system/sullivan-update.service
sudo sed -i "s|/home/actions_user/sullivan|$SULLIVAN_DIR|g" /etc/systemd/system/sullivan-cleanup.service
sudo sed -i "s|User=actions_user|User=$USER|g" /etc/systemd/system/sullivan-cleanup.service

# Reload systemd
log "Reloading systemd daemon..."
sudo systemctl daemon-reload

# Enable and start the timers
log "Enabling and starting timers..."
sudo systemctl enable sullivan-update.timer
sudo systemctl enable sullivan-cleanup.timer
sudo systemctl start sullivan-update.timer
sudo systemctl start sullivan-cleanup.timer

# Check status
log "Checking timer status..."
sudo systemctl status sullivan-update.timer --no-pager -l
sudo systemctl status sullivan-cleanup.timer --no-pager -l

# Show next run times
log "Timer schedule:"
systemctl list-timers sullivan-* --no-pager

# Create log rotation for Docker logs
log "Setting up log rotation for Docker..."
sudo tee /etc/logrotate.d/docker-sullivan > /dev/null << 'EOF'
/var/lib/docker/containers/*/*.log {
    daily
    missingok
    rotate 7
    compress
    delaycompress
    copytruncate
    notifempty
    create 0644 root root
}
EOF

log "Setup completed successfully!"
log ""
log "Summary:"
log "- Daily updates: Runs daily at a random time"
log "- Weekly cleanup: Runs weekly to clean Docker cache and logs"
log "- Log rotation: Docker logs rotated daily, kept for 7 days"
log ""
log "To check logs:"
log "  sudo journalctl -u sullivan-update.service -f"
log "  sudo journalctl -u sullivan-cleanup.service -f"
log ""
log "To manually run updates:"
log "  sudo systemctl start sullivan-update.service"
log "  sudo systemctl start sullivan-cleanup.service"
