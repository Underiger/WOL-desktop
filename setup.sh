#!/usr/bin/env bash
# One-shot provisioning script for Tomori (Raspberry Pi Zero 1WH, Raspberry Pi OS Lite).
#
# Usage (after flashing and first boot):
#   git clone https://github.com/Underiger/WOL-wake-desktop.git
#   cd WOL-wake-desktop
#   sudo ./setup.sh

set -euo pipefail

if [[ $EUID -ne 0 ]]; then
  echo "Please run as root: sudo ./setup.sh" >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WOL_DIR=/opt/wol
ENV_FILE=/etc/wol-api.env
SERVICE_NAME=wol-api
SERVICE_USER=wolapi

echo "==> Updating system packages"
apt update
apt full-upgrade -y

echo "==> Installing base packages (wakeonlan, curl, python3)"
apt install -y wakeonlan curl wget python3

echo "==> Installing log2ram (azlux repo)"
if ! dpkg -s log2ram >/dev/null 2>&1; then
  KEYRING=/usr/share/keyrings/azlux-archive-keyring.gpg
  wget -O "$KEYRING" https://azlux.fr/repo.gpg
  echo "deb [signed-by=$KEYRING] http://packages.azlux.fr/debian/ $(lsb_release -sc) main" \
    > /etc/apt/sources.list.d/azlux.list
  apt update
  apt install -y log2ram
else
  echo "log2ram already installed, skipping"
fi

echo "==> Installing Tailscale"
if ! command -v tailscale >/dev/null 2>&1; then
  curl -fsSL https://tailscale.com/install.sh | sh
else
  echo "Tailscale already installed, skipping"
fi

echo "==> Creating service user ($SERVICE_USER)"
if ! id -u "$SERVICE_USER" >/dev/null 2>&1; then
  useradd --system --no-create-home --shell /usr/sbin/nologin "$SERVICE_USER"
fi

echo "==> Deploying wol-api to $WOL_DIR"
mkdir -p "$WOL_DIR"
cp "$SCRIPT_DIR/wol-api/server.py" "$WOL_DIR/server.py"
chown -R "$SERVICE_USER:$SERVICE_USER" "$WOL_DIR"
chmod 755 "$WOL_DIR"
chmod 644 "$WOL_DIR/server.py"

if [[ ! -f "$ENV_FILE" ]]; then
  echo "==> Generating $ENV_FILE with a random token"
  cp "$SCRIPT_DIR/configs/wol-api.env.example" "$ENV_FILE"
  TOKEN="$(python3 -c 'import secrets; print(secrets.token_hex(32))')"
  sed -i "s/^WOL_TOKEN=.*/WOL_TOKEN=${TOKEN}/" "$ENV_FILE"
else
  echo "$ENV_FILE already exists, leaving it untouched"
fi
chown root:root "$ENV_FILE"
chmod 600 "$ENV_FILE"

echo "==> Installing systemd service"
cp "$SCRIPT_DIR/configs/wol-api.service" "/etc/systemd/system/${SERVICE_NAME}.service"
systemctl daemon-reload
systemctl enable "$SERVICE_NAME"
systemctl restart "$SERVICE_NAME"

echo
echo "======================================================"
echo " Setup complete."
echo
echo " 1) Join your tailnet (interactive, do this manually):"
echo "      sudo tailscale up"
echo "    Then approve the device in the Tailscale admin console."
echo
echo " 2) WOL_TOKEN for calling POST /wake:"
grep '^WOL_TOKEN=' "$ENV_FILE"
echo "    Stored in $ENV_FILE (mode 600, root only). Keep it secret."
echo
echo " 3) Try it:"
echo "      curl http://<tailscale-ip>:8080/status"
echo "      curl -X POST http://<tailscale-ip>:8080/wake \\"
echo "        -H \"Authorization: Bearer \$(grep '^WOL_TOKEN=' $ENV_FILE | cut -d= -f2)\""
echo "======================================================"
