#!/usr/bin/env bash
set -Eeuo pipefail

if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
  echo "Run as root (or with sudo)." >&2
  exit 1
fi

if command -v systemctl >/dev/null 2>&1; then
  systemctl disable --now arrguard.timer >/dev/null 2>&1 || true
  rm -f /etc/systemd/system/arrguard.timer /etc/systemd/system/arrguard.service
  systemctl daemon-reload >/dev/null 2>&1 || true
fi

rm -rf /opt/arrguard
rm -f /run/lock/arrguard.lock

if [[ "${PURGE_CONFIG:-0}" == "1" ]]; then
  rm -f /etc/arrguard.conf /var/log/arrguard.log
  echo "ArrGuard removed, including configuration and log."
else
  echo "ArrGuard removed."
  echo "Configuration kept at /etc/arrguard.conf"
  echo "Log kept at /var/log/arrguard.log"
fi
