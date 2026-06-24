#!/bin/bash
#Installs cloudflared, creates and configures a Cloudflare tunnel (DNS route + YAML using latest credentials), tests and runs it forwarding a hostname to a local port, and installs a systemd service for automatic startup.

# If you are installed cloudflared on a server, you can skip the first 30 lines of this script.
# Download and install Cloudflared
wget https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64.deb
sudo dpkg -i cloudflared-linux-amd64.deb
cloudflared --version


# Clean up installation file
rm -f cloudflared-linux-amd64.deb
echo "Installation file cleaned up"



# Login to Cloudflare
echo "Copy the link and paste it into your browser to authenticate"
cloudflared login
# Copy the link and paste it into your browser to authenticate









##############################


# Prompt for tunnel name
read -p "Enter tunnel name (press Enter for default 'sample-tunnel'): " TUNNEL_NAME
TUNNEL_NAME=${TUNNEL_NAME:-sample-tunnel}

# Prompt for domain
read -p "Enter your website domain (press Enter for default 'example.com'): " DOMAIN
DOMAIN=${DOMAIN:-example.com}


# Prompt for local port
read -p "Enter local port (press Enter for default '80'): " LOCAL_PORT
LOCAL_PORT=${LOCAL_PORT:-80}


cloudflared tunnel create "$TUNNEL_NAME"


cloudflared tunnel route dns --overwrite-dns "$TUNNEL_NAME" "$DOMAIN"


# Automatically get the most recent JSON credentials file
CREDENTIALS_FILE=$(ls -t /root/.cloudflared/*.json 2>/dev/null | head -n1)

if [ -z "$CREDENTIALS_FILE" ]; then
    echo "Error: No credentials file found in /root/.cloudflared/"
    exit 1
fi

echo "Using credentials file: $CREDENTIALS_FILE"


# Create tunnel configuration file
sudo bash -c "cat > /root/.cloudflared/$TUNNEL_NAME.yml <<EOF
tunnel: $TUNNEL_NAME
credentials-file: $CREDENTIALS_FILE

ingress:
  - hostname: $DOMAIN
    service: http://localhost:$LOCAL_PORT
  - service: http_status:404
EOF"



# Test the tunnel configuration
echo "Testing tunnel configuration..."
TEST_COMMAND="cloudflared --config /root/.cloudflared/$TUNNEL_NAME.yml  --loglevel debug tunnel run $TUNNEL_NAME"
$TEST_COMMAND &
TUNNEL_PID=$!
sleep 20
kill $TUNNEL_PID 2>/dev/null




# Create systemd service
sudo bash -c "cat > /etc/systemd/system/cloudflared-$TUNNEL_NAME.service <<EOF
[Unit]
Description=Cloudflared Tunnel - $TUNNEL_NAME
After=network.target

[Service]
Type=simple
User=root
ExecStart=/usr/local/bin/cloudflared --config /root/.cloudflared/$TUNNEL_NAME.yml tunnel run $TUNNEL_NAME
Restart=on-failure
RestartSec=5s

[Install]
WantedBy=multi-user.target
EOF"



# Reload systemd and enable service
sudo systemctl daemon-reload
sudo systemctl enable cloudflared-$TUNNEL_NAME
sudo systemctl start cloudflared-$TUNNEL_NAME
sudo systemctl restart cloudflared-$TUNNEL_NAME

# Check service status
sudo systemctl status cloudflared-$TUNNEL_NAME

echo ""
echo "=========================================="
echo "Setup complete!"
echo "=========================================="
echo "Tunnel name: $TUNNEL_NAME"
echo "Domain: $DOMAIN"
echo "Local port: $LOCAL_PORT"
echo "Credentials: $CREDENTIALS_FILE"
echo ""
echo "Useful commands:"
echo "  Restart service: sudo systemctl restart cloudflared-$TUNNEL_NAME"
echo "  Stop service: sudo systemctl stop cloudflared-$TUNNEL_NAME"
echo "  View logs: sudo journalctl -u cloudflared-$TUNNEL_NAME -f"
echo ""
echo "Debug/Testing command:"
echo "  $TEST_COMMAND"
echo "=========================================="