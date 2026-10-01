#!/usr/bin/env bash
set -Eeuo pipefail

if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
  echo "Run as root (or with sudo)." >&2
  exit 1
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
