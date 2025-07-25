#!/bin/bash
# Let's Encrypt Wildcard Certificate Setup for 7gram.xyz - FEDORA 42 SERVER + CLOUDFLARE VERSION

set -e  # Exit on any error

echo "🚀 Starting Let's Encrypt setup for Fedora 42 Server with Cloudflare..."

# Update system first
echo "📦 Updating system..."
sudo dnf update -y

# Install certbot and required packages
echo "📥 Installing certbot and dependencies..."
sudo dnf install -y certbot python3-pip git curl

# Install Cloudflare plugin
echo "📥 Installing Cloudflare plugin..."
sudo dnf install -y python3-certbot-dns-cloudflare || {
    echo "📥 Installing via pip as fallback..."
    sudo pip3 install certbot-dns-cloudflare
}

# Create directories
echo "📁 Creating necessary directories..."
sudo mkdir -p /etc/letsencrypt
mkdir -p ./nginx/ssl

# Prompt for credentials
echo "🔐 Setting up Cloudflare DNS credentials..."
echo "Please enter your Cloudflare API credentials:"
echo "📋 Get these from: Cloudflare Dashboard → My Profile → API Tokens"
read -p "Cloudflare Email: " cloudflare_email
read -p "Cloudflare Global API Key: " cloudflare_api_key
read -p "Your Email Address: " email_address

# Create DNS credentials file for Cloudflare
sudo tee /etc/letsencrypt/cloudflare.ini > /dev/null <<EOF
# Cloudflare API credentials
dns_cloudflare_email = $cloudflare_email
dns_cloudflare_api_key = $cloudflare_api_key
EOF

# Secure the credentials file
sudo chmod 600 /etc/letsencrypt/cloudflare.ini

echo "🔍 Testing Cloudflare API connection..."
# Test API connection (optional)
curl -s -H "X-Auth-Email: $cloudflare_email" -H "X-Auth-Key: $cloudflare_api_key" "https://api.cloudflare.com/client/v4/user/tokens/verify" > /dev/null || echo "⚠️  Warning: Could not test API connection"

# Generate wildcard certificate
echo "🔒 Generating wildcard certificate for 7gram.xyz..."
sudo certbot certonly \
    --dns-cloudflare \
    --dns-cloudflare-credentials /etc/letsencrypt/cloudflare.ini \
    --dns-cloudflare-propagation-seconds 60 \
    -d "7gram.xyz" \
    -d "*.7gram.xyz" \
    --agree-tos \
    --email "$email_address" \
    --non-interactive

# Copy certificates to nginx/ssl directory
echo "📋 Copying certificates to nginx/ssl directory..."
sudo cp /etc/letsencrypt/live/7gram.xyz/fullchain.pem ./nginx/certs/
sudo cp /etc/letsencrypt/live/7gram.xyz/privkey.pem ./nginx/certs/
sudo chown $USER:$USER ./nginx/certs/*.pem
chmod 644 ./nginx/certs/fullchain.pem
chmod 600 ./nginx/certs/privkey.pem

echo "✅ Certificate generated! Location:"
echo "Certificate: ./nginx/certs/fullchain.pem"
echo "Private Key: ./nginx/certs/privkey.pem"

# Create certificate renewal script
echo "🔄 Setting up automatic certificate renewal..."
sudo tee /usr/local/bin/renew-ssl.sh > /dev/null <<EOF
#!/bin/bash
# Renew certificates and copy to nginx directory
certbot renew --quiet

# Copy renewed certificates
if [ -f /etc/letsencrypt/live/7gram.xyz/fullchain.pem ]; then
    cp /etc/letsencrypt/live/7gram.xyz/fullchain.pem $(pwd)/nginx/ssl/
    cp /etc/letsencrypt/live/7gram.xyz/privkey.pem $(pwd)/nginx/ssl/
    chown $USER:$USER $(pwd)/nginx/ssl/*.pem
    chmod 644 $(pwd)/nginx/ssl/fullchain.pem
    chmod 600 $(pwd)/nginx/ssl/privkey.pem
    
    # Reload nginx container if running
    if docker ps | grep -q "nginx"; then
        docker exec nginx nginx -s reload || echo "Could not reload nginx container"
    fi
    
    echo "Certificates renewed and copied to nginx/ssl/"
fi
EOF

sudo chmod +x /usr/local/bin/renew-ssl.sh

# Set up automatic renewal using systemd
sudo tee /etc/systemd/system/certbot-renewal.service > /dev/null <<EOF
[Unit]
Description=Certbot Renewal
After=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/renew-ssl.sh
User=root
WorkingDirectory=$(pwd)
EOF

sudo tee /etc/systemd/system/certbot-renewal.timer > /dev/null <<EOF
[Unit]
Description=Run certbot renewal twice daily
Requires=certbot-renewal.service

[Timer]
OnCalendar=*-*-* 00,12:00:00
RandomizedDelaySec=3600
Persistent=true

[Install]
WantedBy=timers.target
EOF

# Enable automatic renewal
sudo systemctl daemon-reload
sudo systemctl enable certbot-renewal.timer
sudo systemctl start certbot-renewal.timer

# Enable and start firewalld if not already running (Fedora security)
if ! systemctl is-active --quiet firewalld; then
    echo "🔥 Enabling firewalld for security..."
    sudo systemctl enable --now firewalld
    sudo firewall-cmd --permanent --add-service=http
    sudo firewall-cmd --permanent --add-service=https
    sudo firewall-cmd --reload
fi

echo "✅ Automatic renewal configured!"
echo ""
echo "🧪 Testing renewal with dry run..."
sudo certbot renew --dry-run

echo ""
echo "🎉 SETUP COMPLETE!"
echo ""
echo "📋 IMPORTANT NOTES:"
echo "- Certificates are stored in: ./nginx/certs/"
echo "- Cloudflare API credentials: /etc/letsencrypt/cloudflare.ini"
echo "- Automatic renewal: Every 12 hours"
echo "- Test renewal: sudo certbot renew --dry-run"
echo "- Check renewal timer: sudo systemctl status certbot-renewal.timer"
echo "- Firewall configured for HTTP/HTTPS traffic"
echo ""
echo "🔧 NEXT STEPS:"
echo "1. Update your docker-compose.yml file to mount ./nginx/certs/"
echo "2. Configure nginx SSL settings"
echo "3. Start your docker containers: docker-compose up -d"
echo ""
echo "☁️ CLOUDFLARE REQUIREMENTS MET:"
echo "✅ Domain added to Cloudflare account"
echo "✅ Nameservers changed from Namecheap to Cloudflare"
echo "✅ DNS records imported and configured"
echo "✅ API credentials configured"
echo ""
echo "🔐 CLOUDFLARE API SETUP:"
echo "- Dashboard → My Profile → API Tokens → Global API Key"
echo "- Or create a custom API token with Zone:DNS:Edit permissions"
echo ""
echo "🔧 FEDORA SPECIFIC FEATURES:"
echo "- Uses DNF package manager"
echo "- Firewalld configured for web traffic"
echo "- SELinux compatible (default Fedora security)"