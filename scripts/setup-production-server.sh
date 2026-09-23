#!/bin/sh
# Production Server Setup Script for Sullivan Media Infrastructure
# This script prepares a fresh Ubuntu/Debian server for automated deployments
#
# Usage:
#   chmod +x setup-production-server.sh
#   sudo ./setup-production-server.sh
#
# This script will:
# - Install Docker and dependencies
# - Install Tailscale for secure networking
# - Create/configure 'actions' user for CI/CD
# - Add 'jordan' and 'actions' users to docker group
# - Setup SSH for actions user
# - Optionally run generate-secrets.sh automatically

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# Log functions
log_info() { printf "${BLUE}[INFO]${NC} %s\n" "$*"; }
log_success() { printf "${GREEN}[SUCCESS]${NC} %s\n" "$*"; }
log_warn() { printf "${YELLOW}[WARN]${NC} %s\n" "$*"; }
log_error() { printf "${RED}[ERROR]${NC} %s\n" "$*"; }
log_header() {
    printf "\n"
    printf "${BOLD}${CYAN}================================================================================${NC}\n"
    printf "${BOLD}${CYAN}  %s${NC}\n" "$*"
    printf "${BOLD}${CYAN}================================================================================${NC}\n"
    printf "\n"
}

# Check if running as root
if [ "$(id -u)" -ne 0 ]; then
    log_error "Please run this script with sudo"
    exit 1
fi

# Detect OS
if [ -f /etc/os-release ]; then
    . /etc/os-release
    OS=$ID
else
    log_error "Cannot detect OS. This script requires /etc/os-release"
    exit 1
fi

# Check for supported OS
if [ "$OS" != "ubuntu" ] && [ "$OS" != "debian" ]; then
    log_warn "This script is designed for Ubuntu/Debian"
    log_warn "Detected OS: $OS"
    printf "Continue anyway? (y/N) "
    read -r reply
    if [ "$reply" != "y" ] && [ "$reply" != "Y" ]; then
        exit 1
    fi
fi

log_header "Sullivan Media Server Setup"

log_info "OS: $PRETTY_NAME"
log_info "Architecture: $(uname -m)"
log_info "Kernel: $(uname -r)"

# Detect current user (who invoked sudo)
REAL_USER="${SUDO_USER:-$(logname 2>/dev/null)}"
if [ -n "$REAL_USER" ] && [ "$REAL_USER" != "root" ]; then
    log_info "Detected user: $REAL_USER"
else
    REAL_USER=""
fi
printf "\n"

# =============================================================================
# Step 1: Update System
# =============================================================================
log_info "Step 1/10: Updating system packages..."
apt-get update
apt-get upgrade -y
log_success "System updated"
printf "\n"

# =============================================================================
# Step 2: Install System Dependencies
# =============================================================================
log_info "Step 2/10: Installing system dependencies..."
apt-get install -y \
    curl \
    wget \
    git \
    ca-certificates \
    gnupg \
    lsb-release \
    apt-transport-https \
    software-properties-common \
    jq \
    vim \
    htop \
    net-tools \
    ufw \
    openssh-server \
    openssl

log_success "System dependencies installed"
printf "\n"

# =============================================================================
# Step 3: Install Tailscale
# =============================================================================
log_info "Step 3/12: Installing Tailscale..."

if command -v tailscale >/dev/null 2>&1; then
    log_warn "Tailscale is already installed ($(tailscale version | head -1))"
else
    curl -fsSL https://tailscale.com/install.sh | sh
    log_success "Tailscale installed"
fi

# Check Tailscale status
if tailscale status >/dev/null 2>&1; then
    log_success "Tailscale is connected"
    log_info "Tailscale IP: $(tailscale ip -4 2>/dev/null || echo 'Not available')"
else
    log_warn "Tailscale is not connected yet"
    log_info "Run 'sudo tailscale up' to connect after setup"
fi
printf "\n"

# =============================================================================
# Step 4: Install Docker
# =============================================================================
log_info "Step 4/12: Installing Docker..."

if command -v docker >/dev/null 2>&1; then
    log_warn "Docker is already installed ($(docker --version))"
else
    # Add Docker's official GPG key
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/$OS/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    chmod a+r /etc/apt/keyrings/docker.gpg

    # Set up Docker repository
    echo \
        "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/$OS \
        $(lsb_release -cs) stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null

    # Install Docker Engine
    apt-get update
    apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

    # Enable and start Docker
    systemctl enable docker
    systemctl start docker

    log_success "Docker installed successfully"
fi

docker --version
docker compose version
printf "\n"

# =============================================================================
# Step 5: Install NVIDIA Container Toolkit (if GPU present)
# =============================================================================
log_info "Step 5/12: Checking for NVIDIA GPU..."

if lspci | grep -i nvidia >/dev/null 2>&1; then
    log_info "NVIDIA GPU detected, installing NVIDIA Container Toolkit..."

    # Add NVIDIA container toolkit repository
    curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey | gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
    curl -s -L https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list | \
        sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' | \
        tee /etc/apt/sources.list.d/nvidia-container-toolkit.list

    apt-get update
    apt-get install -y nvidia-container-toolkit

    # Configure Docker to use NVIDIA runtime
    nvidia-ctk runtime configure --runtime=docker
    systemctl restart docker

    log_success "NVIDIA Container Toolkit installed"
else
    log_info "No NVIDIA GPU detected, skipping NVIDIA Container Toolkit"
fi
printf "\n"

# =============================================================================
# Step 6: Create and Configure Users
# =============================================================================
log_info "Step 6/12: Creating and configuring users..."

# Create actions user for CI/CD
if id "actions" >/dev/null 2>&1; then
    log_warn "User 'actions' already exists"
else
    # Create actions user with no password (key-only auth)
    useradd -m -s /bin/bash -c "GitHub Actions CI/CD User" actions
    log_success "User 'actions' created"
fi

# Add actions to docker group
usermod -aG docker actions
log_success "User 'actions' added to docker group"

# Automation user, separate from the interactive admin so automated changes
# are attributable in logs and revocable on their own -- `userdel -r claude`
# ends its access without rotating jordan's key. Created by hand 2026-09-22;
# kept here so a rebuild does not lose it.
if id "claude" >/dev/null 2>&1; then
    log_warn "User 'claude' already exists"
else
    useradd -m -s /bin/bash -c "Claude automation" claude
    log_success "User 'claude' created"
fi
install -d -m 700 -o claude -g claude /home/claude/.ssh
CLAUDE_KEY='ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIGe/TXKI4lHF5/8scltcJ+gcSc3GPmD80jt94kfYoq8Z claude@oryx'
touch /home/claude/.ssh/authorized_keys
# Append, never overwrite, and never twice -- re-running setup must not drop
# a key someone else added.
grep -qF "$(echo "$CLAUDE_KEY" | awk '{print $2}')" /home/claude/.ssh/authorized_keys 2>/dev/null \
    || echo "$CLAUDE_KEY" >> /home/claude/.ssh/authorized_keys
chown claude:claude /home/claude/.ssh/authorized_keys
chmod 600 /home/claude/.ssh/authorized_keys
passwd -l claude 2>/dev/null || true
usermod -aG docker claude
echo 'claude ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/claude
chmod 440 /etc/sudoers.d/claude
# A malformed drop-in locks everyone out of root, so validate and revert.
visudo -c >/dev/null 2>&1 || { rm -f /etc/sudoers.d/claude; log_error "sudoers invalid - claude sudo reverted"; }
log_success "User 'claude' configured (key, docker, sudo)"

# -----------------------------------------------------------------------------
# SSH hardening. Sullivan had NONE of this: measured 2026-09-22, the live box
# reported passwordauthentication yes, maxauthtries 6, permitrootlogin
# without-password -- stock Ubuntu defaults, on a host publishing services to
# the tailnet.
#
# NAMED 00-, NOT 99-. sshd honours the FIRST occurrence of each keyword across
# sshd_config.d (the opposite of sysctl.d, where last wins), and Ubuntu's
# cloud image ships 50-cloud-init.conf containing "PasswordAuthentication
# yes". freddy learned this the expensive way -- its 99- file set
# "PasswordAuthentication no" and the server kept accepting passwords, while
# the three directives cloud-init does not mention applied normally and made
# the hardening look fine.
# -----------------------------------------------------------------------------
mkdir -p /etc/ssh/sshd_config.d
cat > /etc/ssh/sshd_config.d/00-sullivan-hardening.conf <<'SSHEOF'
# Sullivan Server SSH Hardening
PermitRootLogin no
PasswordAuthentication no
ChallengeResponseAuthentication no
UsePAM yes
PermitEmptyPasswords no
MaxAuthTries 3
MaxSessions 5
LoginGraceTime 30
X11Forwarding no
LogLevel VERBOSE
ClientAliveInterval 300
ClientAliveCountMax 2
AllowUsers actions jordan claude
SSHEOF
chmod 644 /etc/ssh/sshd_config.d/00-sullivan-hardening.conf

# Validate BEFORE reloading. A bad config that gets reloaded on a remote box
# is how you lose the machine.
if sshd -t 2>/dev/null; then
    systemctl reload ssh 2>/dev/null || systemctl reload sshd 2>/dev/null || true
    log_success "SSH hardening applied (password auth disabled, key-only)"
else
    rm -f /etc/ssh/sshd_config.d/00-sullivan-hardening.conf
    log_error "sshd config invalid - hardening reverted, server left as it was"
fi

# Configure jordan user if it exists or if we detected them
if [ -n "$REAL_USER" ]; then
    if id "$REAL_USER" >/dev/null 2>&1; then
        # Add jordan (or current user) to docker group
        if ! groups "$REAL_USER" | grep -q docker; then
            usermod -aG docker "$REAL_USER"
            log_success "User '$REAL_USER' added to docker group"
        else
            log_info "User '$REAL_USER' already in docker group"
        fi
    fi
elif id "jordan" >/dev/null 2>&1; then
    # Specifically check for jordan user
    if ! groups jordan | grep -q docker; then
        usermod -aG docker jordan
        log_success "User 'jordan' added to docker group"
    else
        log_info "User 'jordan' already in docker group"
    fi
fi

# Set password policy for actions (disable password login)
passwd -l actions 2>/dev/null || true
log_info "Password login disabled for 'actions' user (SSH key only)"

printf "\n"

# =============================================================================
# Step 7: Setup SSH for Actions User
# =============================================================================
log_info "Step 7/12: Setting up SSH for 'actions' user..."

ACTIONS_HOME="/home/actions"
SSH_DIR="$ACTIONS_HOME/.ssh"

# Create .ssh directory
sudo -u actions mkdir -p "$SSH_DIR"
chmod 700 "$SSH_DIR"

# Create authorized_keys file
sudo -u actions touch "$SSH_DIR/authorized_keys"
chmod 600 "$SSH_DIR/authorized_keys"

log_success "SSH directory created for actions user"
log_warn "Run generate-secrets.sh to create SSH keys"
printf "\n"

# =============================================================================
# Step 8: Create Project Directories
# =============================================================================
log_info "Step 8/12: Creating project directories..."

sudo -u actions mkdir -p "$ACTIONS_HOME/sullivan"
sudo -u actions mkdir -p "$ACTIONS_HOME/logs"
sudo -u actions mkdir -p "$ACTIONS_HOME/backups"
sudo -u actions mkdir -p "$ACTIONS_HOME/data"

# Create media mount point directories (adjust paths as needed)
log_info "Creating media directories..."
mkdir -p /mnt/media/{movies,shows,music,books,downloads}
chown -R "$REAL_USER:$REAL_USER" /mnt/media 2>/dev/null || chown -R actions:actions /mnt/media

log_success "Directories created"
printf "\n"

# =============================================================================
# Step 9: Setup Environment File Template
# =============================================================================
log_info "Step 9/12: Creating .env template..."

ENV_FILE="$ACTIONS_HOME/sullivan/.env"

if [ ! -f "$ENV_FILE" ]; then
    sudo -u actions tee "$ENV_FILE" > /dev/null <<'EOF'
# Sullivan Media Infrastructure - Environment Variables
# Generated by setup-production-server.sh
# Update these values before deploying!

# =============================================================================
# CORE SETTINGS
# =============================================================================
TZ=America/Toronto
PUID=1000
PGID=100
LIBVA_DRIVER_NAME=iHD

# =============================================================================
# MEDIA PATHS (Update to match your storage)
# =============================================================================
MEDIA_PATH=/mnt/media
MEDIA_PATH_MOVIES=/mnt/media/movies
MEDIA_PATH_SHOWS=/mnt/media/shows
MEDIA_PATH_MUSIC=/mnt/media/music
MEDIA_PATH_MUSIC_VIDEOS=/mnt/media/music_videos
MEDIA_PATH_EDU=/mnt/media/edu
MEDIA_PATH_BOOKS=/mnt/media/books
MEDIA_PATH_AUDIOBOOKS=/mnt/media/books/audiobooks
MEDIA_PATH_EBOOKS=/mnt/media/books/ebooks

# =============================================================================
# DOWNLOAD PATHS
# =============================================================================
DOWNLOAD_PATH_COMPLETE=/mnt/media/downloads/complete
DOWNLOAD_PATH_INCOMPLETE=/mnt/media/downloads/incomplete

# =============================================================================
# BACKUP CONFIGURATION
# =============================================================================
BACKUP_DESTINATION=/mnt/media/backup
BACKUP_RETENTION_DAYS=30

# =============================================================================
# API KEYS (Get these from each service after first startup)
# =============================================================================
SONARR_API_KEY=CHANGE_ME
RADARR_API_KEY=CHANGE_ME
LIDARR_API_KEY=CHANGE_ME
PROWLARR_API_KEY=CHANGE_ME

# =============================================================================
# FILEBOT SETTINGS
# =============================================================================
FILEBOT_USER=admin
FILEBOT_PASSWORD=CHANGE_ME

# =============================================================================
# DISCORD INTEGRATION
# =============================================================================
DISCORD_TOKEN=CHANGE_ME

# =============================================================================
# DATABASE PASSWORDS
# =============================================================================
WIKI_DB_PASSWORD=CHANGE_ME
MEALIE_DB_PASSWORD=CHANGE_ME
NEXTCLOUD_MYSQL_PASSWORD=CHANGE_ME

# =============================================================================
# WATCHTOWER SETTINGS
# =============================================================================
WATCHTOWER_SCHEDULE="0 2 * * *"
WATCHTOWER_NOTIFICATION_URL=
EOF

    chmod 600 "$ENV_FILE"
    chown actions:actions "$ENV_FILE"

    log_success ".env template created at $ENV_FILE"
    log_warn "IMPORTANT: Edit $ENV_FILE with your actual credentials!"
else
    log_warn ".env file already exists at $ENV_FILE"
fi
printf "\n"

# =============================================================================
# Step 10: Configure Firewall (Optional)
# =============================================================================
log_info "Step 10/12: Configuring firewall (UFW)..."

printf "Do you want to configure UFW firewall? (y/N) "
read -r reply
if [ "$reply" = "y" ] || [ "$reply" = "Y" ]; then
    # Allow SSH
    ufw allow 22/tcp comment 'SSH'

    # Allow HTTP/HTTPS
    ufw allow 80/tcp comment 'HTTP'
    ufw allow 443/tcp comment 'HTTPS'

    # Media Services
    ufw allow 8096/tcp comment 'Emby'
    ufw allow 8097/tcp comment 'Jellyfin'
    ufw allow 32400/tcp comment 'Plex'
    
    # Download Management
    ufw allow 8989/tcp comment 'Sonarr'
    ufw allow 7878/tcp comment 'Radarr'
    ufw allow 8686/tcp comment 'Lidarr'
    ufw allow 9696/tcp comment 'Prowlarr'
    ufw allow 8080/tcp comment 'qBittorrent'
    
    # Utilities
    ufw allow 9000/tcp comment 'Portainer'
    ufw allow 7575/tcp comment 'Homarr'

    # Enable UFW
    ufw --force enable

    log_success "Firewall configured and enabled"
    ufw status
else
    log_warn "Skipping firewall configuration"
fi
printf "\n"

# =============================================================================
# Step 11: Setup Log Rotation
# =============================================================================
log_info "Step 11/12: Setting up log rotation..."

LOGROTATE_CONF="/etc/logrotate.d/sullivan"

tee "$LOGROTATE_CONF" > /dev/null <<'EOF'
/home/actions/logs/*.log {
    daily
    rotate 30
    compress
    delaycompress
    notifempty
    missingok
    create 0640 actions actions
    sharedscripts
    postrotate
        if [ -x /usr/bin/docker ]; then
            /usr/bin/docker ps -q | xargs -r docker restart 2>/dev/null || true
        fi
    endscript
}
EOF

log_success "Log rotation configured"
printf "\n"

# =============================================================================
# Setup Systemd Service (Optional)
# =============================================================================
log_info "Optional: Setting up systemd service for auto-start..."

printf "Do you want to create a systemd service for auto-start on boot? (y/N) "
read -r reply
if [ "$reply" = "y" ] || [ "$reply" = "Y" ]; then

    SYSTEMD_SERVICE="/etc/systemd/system/sullivan.service"

    tee "$SYSTEMD_SERVICE" > /dev/null <<'EOF'
[Unit]
Description=Sullivan Media Infrastructure
After=docker.service
Requires=docker.service

[Service]
Type=oneshot
RemainAfterExit=yes
User=actions
Group=actions
WorkingDirectory=/home/actions/sullivan
ExecStart=/bin/bash -c 'cd /home/actions/sullivan && docker compose up -d'
ExecStop=/bin/bash -c 'cd /home/actions/sullivan && docker compose down'
TimeoutStartSec=0

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable sullivan.service

    log_success "Systemd service created and enabled"
    log_info "Service will auto-start on boot"
    log_info "Manual control:"
    printf "  sudo systemctl start sullivan\n"
    printf "  sudo systemctl stop sullivan\n"
    printf "  sudo systemctl status sullivan\n"
else
    log_warn "Skipping systemd service creation"
fi
printf "\n"

# =============================================================================
# Display Summary
# =============================================================================
# =============================================================================
# Step 12: Generate Secrets (Optional)
# =============================================================================
log_info "Step 12/12: Generate secrets..."

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
GENERATE_SECRETS_SCRIPT="$SCRIPT_DIR/generate-secrets.sh"

if [ -f "$GENERATE_SECRETS_SCRIPT" ]; then
    printf "Do you want to generate secrets now? This will create SSH keys and secure credentials. (Y/n) "
    read -r reply
    if [ "$reply" != "n" ] && [ "$reply" != "N" ]; then
        log_info "Running generate-secrets.sh..."
        chmod +x "$GENERATE_SECRETS_SCRIPT"
        "$GENERATE_SECRETS_SCRIPT"
        SECRETS_GENERATED=true
    else
        log_warn "Skipping secrets generation - run manually later:"
        log_warn "  sudo $GENERATE_SECRETS_SCRIPT"
        SECRETS_GENERATED=false
    fi
else
    log_warn "generate-secrets.sh not found at: $GENERATE_SECRETS_SCRIPT"
    log_warn "You'll need to create SSH keys and secrets manually"
    SECRETS_GENERATED=false
fi
printf "\n"

# =============================================================================
# Display Summary
# =============================================================================
log_header "Sullivan Server Setup Complete!"

log_info "System Information:"
printf "  OS: %s\n" "$(lsb_release -d | cut -f2)"
printf "  Architecture: %s\n" "$(uname -m)"
printf "  Kernel: %s\n" "$(uname -r)"
printf "  CPU: %s cores\n" "$(nproc)"
printf "  RAM: %s\n" "$(free -h | awk '/^Mem:/ {print $2}')"
printf "  Disk: %s available\n" "$(df -h / | awk 'NR==2 {print $4}')"
printf "\n"

log_header "Next Steps"

if [ "$SECRETS_GENERATED" = true ]; then
    printf "${BOLD}${GREEN}✓ Secrets Generated!${NC}\n"
    printf "   Check the output above for the credentials file location\n\n"

    printf "${BOLD}${GREEN}1. Configure GitHub Secrets${NC}\n"
    printf "   Copy the secrets from the credentials file to GitHub:\n"
    printf "   ${CYAN}https://github.com/YOUR_USERNAME/sullivan/settings/secrets/actions${NC}\n"
    printf "   See: ${CYAN}cat scripts/ACTION_ITEMS.md${NC}\n\n"

    printf "${BOLD}${GREEN}2. Edit Environment Variables${NC}\n"
    printf "   Update the .env file with your actual credentials:\n"
    printf "   ${CYAN}sudo -u actions vim %s${NC}\n\n" "$ENV_FILE"

    printf "${BOLD}${GREEN}3. Test SSH Connection${NC}\n"
    printf "   After copying the SSH key to your local machine:\n"
    printf "   ${CYAN}ssh -i ~/.ssh/sullivan_deploy actions@%s${NC}\n\n" "$(hostname -I | awk '{print $1}')"
else
    printf "${BOLD}${GREEN}1. Generate Secrets and SSH Keys${NC}\n"
    printf "   Run the companion script to generate secure credentials:\n"
    printf "   ${CYAN}sudo %s${NC}\n\n" "$GENERATE_SECRETS_SCRIPT"

    printf "${BOLD}${GREEN}2. Configure GitHub Secrets${NC}\n"
    printf "   The generate-secrets.sh script will output values for GitHub\n"
    printf "   See: ${CYAN}cat scripts/ACTION_ITEMS.md${NC}\n\n"

    printf "${BOLD}${GREEN}3. Edit Environment Variables${NC}\n"
    printf "   Update the .env file with your actual credentials:\n"
    printf "   ${CYAN}sudo -u actions vim %s${NC}\n\n" "$ENV_FILE"

    printf "${BOLD}${GREEN}4. Test SSH Connection${NC}\n"
    printf "   After adding the SSH key to authorized_keys:\n"
    printf "   ${CYAN}ssh actions@%s${NC}\n\n" "$(hostname -I | awk '{print $1}')"
fi

printf "${BOLD}${GREEN}4. Verify Docker Access${NC}\n"
printf "   Test Docker without sudo:\n"
if [ -n "$REAL_USER" ]; then
    printf "   ${CYAN}su - %s${NC}\n" "$REAL_USER"
    printf "   ${CYAN}docker ps${NC}\n"
    printf "   ${YELLOW}Note: You may need to log out and back in for docker group to take effect${NC}\n\n"
else
    printf "   ${CYAN}su - actions${NC}\n"
    printf "   ${CYAN}docker ps${NC}\n\n"
fi

printf "${BOLD}${GREEN}5. Clone Repository (First Time)${NC}\n"
printf "   The CI/CD will handle this, or clone manually:\n"
printf "   ${CYAN}sudo -u actions git clone https://github.com/YOUR_USERNAME/sullivan.git %s/sullivan${NC}\n\n" "$ACTIONS_HOME"

printf "${BOLD}${GREEN}6. Test Deployment${NC}\n"
printf "   Test starting the services:\n"
printf "   ${CYAN}cd %s/sullivan && docker compose up -d${NC}\n\n" "$ACTIONS_HOME"

log_header "User Configuration Summary"

printf "Users configured for Docker:\n"
printf "  ${GREEN}✓${NC} actions - CI/CD deployment user (password disabled, SSH key only)\n"
if [ -n "$REAL_USER" ] && id "$REAL_USER" >/dev/null 2>&1; then
    printf "  ${GREEN}✓${NC} %s - Admin user (added to docker group)\n" "$REAL_USER"
elif id "jordan" >/dev/null 2>&1; then
    printf "  ${GREEN}✓${NC} jordan - Admin user (added to docker group)\n"
fi
printf "\n"
printf "${YELLOW}IMPORTANT: Log out and back in for docker group changes to take effect!${NC}\n"
printf "\n"

log_header "Security Reminders"

log_warn "IMPORTANT:"
if [ "$SECRETS_GENERATED" = false ]; then
    printf "  - Run generate-secrets.sh to create secure credentials\n"
fi
printf "  - Review generated credentials file and copy to GitHub Secrets\n"
printf "  - Delete credentials file after copying: sudo rm /tmp/sullivan_credentials_*.txt\n"
printf "  - Change all default passwords in .env\n"
printf "  - Keep SSH keys secure and never commit them\n"
printf "  - Review firewall rules regularly\n"
printf "  - Enable monitoring and alerts\n"
printf "  - Set up automated backups\n"
printf "  - Keep Docker and system packages updated\n"
printf "\n"

log_success "Server is ready for deployment!"

if [ -n "$REAL_USER" ]; then
    printf "\n${BOLD}${CYAN}Quick Start for %s:${NC}\n" "$REAL_USER"
    printf "  1. Log out and back in (for docker group)\n"
    printf "  2. Test Docker: ${CYAN}docker ps${NC}\n"
    printf "  3. Review secrets guide: ${CYAN}cat scripts/ACTION_ITEMS.md${NC}\n"
    printf "\n"
fi

exit 0
