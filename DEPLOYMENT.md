# Sullivan Server GitHub Actions Deployment

This repository contains automated deployment configuration for the Sullivan media server using GitHub Actions.

## Architecture

The deployment uses a jump host pattern:
1. **GitHub Actions Runner** → **nginx.7gram.xyz** (jump host) → **Sullivan Server** (via Tailscale)
2. All connections use SSH with key-based authentication
3. The Sullivan server is accessible via Tailscale network

## Setup Requirements

### 1. SSH Key Setup

You need to configure SSH keys for the deployment:

1. Generate an SSH key pair (if you don't have one):
   ```bash
   ssh-keygen -t ed25519 -C "github-actions-sullivan"
   ```

2. Add the public key to `~/.ssh/authorized_keys` on both:
   - `actions_user@nginx.7gram.xyz`
   - `actions_user@sullivan` (or `actions_user@sullivan.tailfef10.ts.net`)

3. Add the private key to GitHub repository secrets as `SSH_PRIVATE_KEY`

### 2. GitHub Secrets

Configure these secrets in your GitHub repository:

- `SSH_PRIVATE_KEY`: The private SSH key for accessing both nginx and sullivan servers

### 3. Server Setup

#### On Sullivan Server

1. Ensure `actions_user` exists and has Docker access:
   ```bash
   sudo usermod -aG docker actions_user
   ```

2. Give `actions_user` sudo privileges for systemd operations:
   ```bash
   sudo visudo
   # Add: actions_user ALL=(ALL) NOPASSWD: /bin/systemctl, /usr/bin/tee, /bin/cp
   ```

3. Run the setup script to install systemd services:
   ```bash
   cd ~/sullivan
   ./scripts/setup_systemd.sh
   ```

#### On nginx.7gram.xyz (Jump Host)

1. Ensure `actions_user` can SSH to Sullivan without password
2. Test the connection:
   ```bash
   ssh actions_user@sullivan
   # or
   ssh actions_user@sullivan.tailfef10.ts.net
   ```

## Automated Services

### Daily Updates (`sullivan-update.timer`)
- **Schedule**: Daily at a randomized time
- **Function**: Pulls latest Docker images and restarts services
- **Script**: `scripts/update_docker.sh all`
- **Logs**: `sudo journalctl -u sullivan-update.service -f`

### Weekly Cleanup (`sullivan-cleanup.timer`)
- **Schedule**: Weekly at a randomized time  
- **Function**: Cleans Docker cache, unused images, and rotates logs
- **Commands**: 
  - `docker system prune -af --volumes`
  - `docker image prune -af`
  - `journalctl --vacuum-time=7d`
- **Logs**: `sudo journalctl -u sullivan-cleanup.service -f`

## Manual Operations

### Deploy Changes
Push to main branch or run workflow manually from GitHub Actions.

### Manual Service Control
```bash
# Run update immediately
sudo systemctl start sullivan-update.service

# Run cleanup immediately
sudo systemctl start sullivan-cleanup.service

# Check timer status
systemctl list-timers sullivan-*

# View logs
sudo journalctl -u sullivan-update.service -f
sudo journalctl -u sullivan-cleanup.service -f
```

### Update Single Service
```bash
cd ~/sullivan
./scripts/update_docker.sh single <service_name>
```

## File Structure

```
sullivan/
├── .github/workflows/
│   └── deploy-sullivan.yml     # GitHub Actions workflow
├── systemd/                    # Systemd service definitions
│   ├── sullivan-update.service
│   ├── sullivan-update.timer
│   ├── sullivan-cleanup.service
│   └── sullivan-cleanup.timer
├── scripts/
│   ├── update_docker.sh        # Main update script
│   ├── setup_systemd.sh        # Setup automation services
│   └── clean_docker.sh         # Docker cleanup utilities
└── docker-compose.yml          # Main service definitions
```

## Troubleshooting

### SSH Connection Issues
1. Verify SSH key is added to both servers
2. Test manual SSH connection: `ssh actions_user@nginx.7gram.xyz`
3. Check SSH agent forwarding is working

### Docker Permission Issues
```bash
# Ensure user is in docker group
sudo usermod -aG docker actions_user
# Re-login to apply group changes
```

### Systemd Service Issues
```bash
# Check service status
sudo systemctl status sullivan-update.service
sudo systemctl status sullivan-cleanup.service

# Reload if services are modified
sudo systemctl daemon-reload
sudo systemctl restart sullivan-update.timer
```

### Tailscale DNS Resolution
If `sullivan` hostname doesn't resolve:
```bash
# Use full Tailscale hostname
ssh actions_user@sullivan.tailfef10.ts.net
```

## Security Notes

- SSH keys should be Ed25519 or RSA 4096-bit minimum
- The `actions_user` has limited sudo privileges for specific systemd operations only
- All connections are encrypted via SSH
- Tailscale provides additional network security layer
- Docker containers run with non-root users where possible
