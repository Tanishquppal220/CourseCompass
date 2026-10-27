#!/usr/bin/env bash
# ==============================================================================
# CourseCompass - EC2 Cloud-Init Bootstrap Script
# Automatically provisioned via aws-ec2-deploy skill
# Runs on first boot as root (secrets injected via launch_instance.sh)
# ==============================================================================

set -euo pipefail
exec > >(tee -a /var/log/app_bootstrap.log) 2>&1

echo "=================================================================="
echo "  🚀 Starting Cloud-Init Bootstrap for CourseCompass"
echo "  Timestamp: $(date -u)"
echo "=================================================================="

# 1. Configure 2GB Swap Space (Essential for 1GB RAM instances)
if [[ ! -f /swapfile ]]; then
  echo "[1/8] Creating 2GB Swapfile..."
  fallocate -l 2G /swapfile || dd if=/dev/zero of=/swapfile bs=1M count=2048
  chmod 600 /swapfile
  mkswap /swapfile
  swapon /swapfile
  echo '/swapfile none swap sw 0 0' >> /etc/fstab
  sysctl vm.swappiness=10
  echo 'vm.swappiness=10' >> /etc/sysctl.conf
  echo "✓ 2GB swap configured."
fi

# 2. Install Essential System Packages
echo "[2/8] Installing base system dependencies..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y --no-install-recommends \
  python3 \
  python3-pip \
  python3-venv \
  git \
  curl \
  wget \
  libgl1 \
  libglib2.0-0 \
  build-essential

# 3. Install Package Managers (uv and Node.js 20 LTS)
echo "[3/8] Installing uv and Node.js 20 LTS..."
curl -LsSf https://astral.sh/uv/install.sh | env UV_INSTALL_DIR="/usr/local/bin" sh
chmod +x /usr/local/bin/uv || true

curl -fsSL https://deb.nodesource.com/setup_20.x | bash -
apt-get install -y nodejs

# 4. Install Cloudflare Tunnel CLI (cloudflared)
echo "[4/8] Installing cloudflared CLI..."
ARCH=$(uname -m)
if [[ "$ARCH" == "aarch64" || "$ARCH" == "arm64" ]]; then
  CF_URL="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-arm64"
else
  CF_URL="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64"
fi
wget -q -O /usr/local/bin/cloudflared "$CF_URL"
chmod +x /usr/local/bin/cloudflared

# 5. Clone Repository
APP_DIR="/home/ubuntu/CourseCompass"
echo "[5/8] Cloning CourseCompass repository..."
rm -rf "$APP_DIR"
git clone --depth 1 -b main https://github.com/Tanishquppal220/CourseCompass.git "$APP_DIR"
chown -R ubuntu:ubuntu "$APP_DIR"

# 6. Build Frontend Static Assets
echo "[6/8] Building Frontend SPA..."
cd "$APP_DIR/frontend"
sudo -u ubuntu npm ci
sudo -u ubuntu npm run build

# 7. Configure Backend & Python Dependencies
echo "[7/8] Configuring Python environment and dependencies..."
cd "$APP_DIR/backend"

# Apply runtime environment variables injected via launch_instance
if [[ -f /home/ubuntu/.app_env ]]; then
  cp /home/ubuntu/.app_env "$APP_DIR/backend/.env"
  chown ubuntu:ubuntu "$APP_DIR/backend/.env"
  chmod 600 "$APP_DIR/backend/.env"
  rm -f /home/ubuntu/.app_env
  echo "✓ Applied production environment variables."
fi

# Create virtualenv with Python 3.13 via uv
sudo -u ubuntu /usr/local/bin/uv venv .venv --python 3.13

# Install CPU-only PyTorch first to save disk
echo "Installing CPU-only PyTorch wheel..."
sudo -u ubuntu /usr/local/bin/uv pip install --no-cache --index-url https://download.pytorch.org/whl/cpu torch torchvision

# Install remaining project dependencies
echo "Installing project dependencies..."
sudo -u ubuntu /usr/local/bin/uv pip install --no-cache -r pyproject.toml
sudo -u ubuntu /usr/local/bin/uv cache clean || true

# 8. Configure Systemd Services
echo "[8/8] Configuring systemd services..."

# Pre-create cloudflared log file with write permissions
touch /var/log/cloudflared.log
chmod 666 /var/log/cloudflared.log

# Service 1: Application Backend Service
cat << 'EOF' > /etc/systemd/system/coursecompass-app.service
[Unit]
Description=CourseCompass Application Service
After=network.target

[Service]
Type=simple
User=ubuntu
WorkingDirectory=/home/ubuntu/CourseCompass/backend
ExecStart=/home/ubuntu/CourseCompass/backend/.venv/bin/uvicorn app.main:app --host 127.0.0.1 --port 8000
Restart=always
RestartSec=3
Environment=PYTHONUNBUFFERED=1

[Install]
WantedBy=multi-user.target
EOF

# Service 2: Cloudflare Quick Tunnel Service
cat << 'EOF' > /etc/systemd/system/coursecompass-tunnel.service
[Unit]
Description=Cloudflare Quick Tunnel for CourseCompass
After=coursecompass-app.service
Wants=coursecompass-app.service

[Service]
Type=simple
User=ubuntu
ExecStart=/usr/local/bin/cloudflared tunnel --url http://127.0.0.1:8000 --logfile /var/log/cloudflared.log
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

# Enable & Start Services
systemctl daemon-reload
systemctl enable coursecompass-app.service coursecompass-tunnel.service
systemctl restart coursecompass-app.service coursecompass-tunnel.service

# Extract and persist public tunnel URL
echo "Extracting live Cloudflare HTTPS URL..."
TUNNEL_URL=""
for i in {1..40}; do
  if [[ -f /var/log/cloudflared.log ]]; then
    TUNNEL_URL=$(grep -o 'https://[-a-zA-Z0-9.]*\.trycloudflare\.com' /var/log/cloudflared.log | tail -n 1 || true)
    if [[ -n "$TUNNEL_URL" ]]; then
      break
    fi
  fi
  sleep 2
done

if [[ -n "$TUNNEL_URL" ]]; then
  echo "$TUNNEL_URL" > /home/ubuntu/TUNNEL_URL.txt
  chown ubuntu:ubuntu /home/ubuntu/TUNNEL_URL.txt
  echo "✓ Cloudflare Tunnel Live: $TUNNEL_URL"
else
  echo "Notice: Cloudflare tunnel initializing in background. Check /var/log/cloudflared.log"
fi

# Signal completion
touch /home/ubuntu/BOOTSTRAP_COMPLETE
chown ubuntu:ubuntu /home/ubuntu/BOOTSTRAP_COMPLETE
echo "=================================================================="
echo "  🎉 Bootstrap completed successfully at $(date -u)"
echo "=================================================================="
