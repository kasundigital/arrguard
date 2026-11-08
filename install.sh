#!/usr/bin/env bash
set -Eeuo pipefail

# Pin to a tag/commit with: ARRGUARD_REF=v0.2.0 bash install.sh
ARRGUARD_REF="${ARRGUARD_REF:-main}"
REPO_RAW="https://raw.githubusercontent.com/kasundigital/arrguard/$ARRGUARD_REF"
INSTALL_DIR="/opt/arrguard"
CONFIG_FILE="/etc/arrguard.conf"
LOG_FILE="/var/log/arrguard.log"

if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
  echo "Run this installer as root (or with sudo)." >&2
  exit 1
fi

echo "Installing ArrGuard ($ARRGUARD_REF)..."

if command -v apt-get >/dev/null 2>&1; then
  apt-get update
  DEBIAN_FRONTEND=noninteractive apt-get install -y curl jq ffmpeg findutils util-linux coreutils
  # Optional: archive test/extract (ARCHIVE_ACTION="extract"). unrar is in
  # Ubuntu "multiverse" / Debian "non-free"; 7zip package name varies by release.
  DEBIAN_FRONTEND=noninteractive apt-get install -y unrar >/dev/null 2>&1 \
    || echo "Note: 'unrar' not installed (enable multiverse/non-free for RAR extraction)."
  DEBIAN_FRONTEND=noninteractive apt-get install -y 7zip >/dev/null 2>&1 \
    || DEBIAN_FRONTEND=noninteractive apt-get install -y p7zip-full >/dev/null 2>&1 \
    || echo "Note: 7-Zip not installed (needed for .7z/.zip extraction)."
else
  echo "Automatic dependency installation currently supports apt-based systems."
  echo "Install curl, jq, ffmpeg, findutils, util-linux and coreutils, then run this installer again."
  exit 1
fi

mkdir -p "$INSTALL_DIR"

for f in arrguard.sh uninstall.sh; do
  curl -fsSL "$REPO_RAW/$f" -o "$INSTALL_DIR/$f.tmp"
  mv "$INSTALL_DIR/$f.tmp" "$INSTALL_DIR/$f"
  chmod 755 "$INSTALL_DIR/$f"
done

if [[ ! -f "$CONFIG_FILE" ]]; then
  curl -fsSL "$REPO_RAW/config.example" -o "$CONFIG_FILE"
  chmod 600 "$CONFIG_FILE"
  echo "Created $CONFIG_FILE"
else
  echo "Keeping existing $CONFIG_FILE"
fi

touch "$LOG_FILE"
chmod 640 "$LOG_FILE"

# Recommended mode: run on the host from a systemd timer as root, so the
# config (API keys) stays root-only and download paths are host paths.
if command -v systemctl >/dev/null 2>&1 && [[ -d /etc/systemd/system ]]; then
  cat >/etc/systemd/system/arrguard.service <<EOF
[Unit]
Description=ArrGuard bad-download check for Sonarr/Radarr
After=network-online.target

[Service]
Type=oneshot
Environment=ARRGUARD_CONFIG=$CONFIG_FILE
ExecStart=$INSTALL_DIR/arrguard.sh
Nice=10
IOSchedulingClass=idle
EOF

  cat >/etc/systemd/system/arrguard.timer <<'EOF'
[Unit]
Description=Run ArrGuard every 15 minutes

[Timer]
OnBootSec=5min
OnUnitActiveSec=15min
Persistent=true

[Install]
WantedBy=timers.target
EOF
  systemctl daemon-reload
  echo "Installed systemd timer (not enabled yet)."
fi

echo
echo "ArrGuard installed."
echo "1. Edit $CONFIG_FILE (API key, PATH_MAPPINGS if Sonarr/Radarr run in Docker)."
echo "2. Keep DRY_RUN=\"true\" and run: sudo $INSTALL_DIR/arrguard.sh"
echo "3. Check $LOG_FILE. When every REJECT line is a release you really want gone,"
echo "   set DRY_RUN=\"false\"."
echo "4. Enable the schedule: sudo systemctl enable --now arrguard.timer"
