#!/usr/bin/env bash
set -Eeuo pipefail

REPO_RAW="https://raw.githubusercontent.com/kasundigital/arrguard/main"
INSTALL_DIR="/opt/arrguard"
CONFIG_FILE="/etc/arrguard.conf"

if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
  echo "Run this installer as root (or with sudo)." >&2
  exit 1
fi

echo "Installing ArrGuard..."

if command -v apt-get >/dev/null 2>&1; then
  apt-get update
  DEBIAN_FRONTEND=noninteractive apt-get install -y curl jq ffmpeg findutils util-linux
else
  echo "Automatic dependency installation currently supports apt-based systems."
  echo "Install curl, jq, ffmpeg, findutils and util-linux, then run this installer again."
  exit 1
fi

mkdir -p "$INSTALL_DIR"

curl -fsSL "$REPO_RAW/arrguard.sh" -o "$INSTALL_DIR/arrguard.sh"
chmod +x "$INSTALL_DIR/arrguard.sh"

if [[ ! -f "$CONFIG_FILE" ]]; then
  curl -fsSL "$REPO_RAW/config.example" -o "$CONFIG_FILE"
  chmod 600 "$CONFIG_FILE"
  echo "Created $CONFIG_FILE"
else
  echo "Keeping existing $CONFIG_FILE"
fi

touch /var/log/arrguard.log
chmod 640 /var/log/arrguard.log

echo
echo "ArrGuard installed."
echo "1. Edit: $CONFIG_FILE"
echo "2. Add /opt/arrguard/arrguard.sh as a Sonarr/Radarr Connect Custom Script."
echo "3. Enable 'On Manual Interaction Required'."
echo "4. Keep DRY_RUN=true first and inspect /var/log/arrguard.log."
