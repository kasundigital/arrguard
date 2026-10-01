# ArrGuard

Automatic bad-download recovery for **Sonarr** and **Radarr**.

ArrGuard checks completed/problematic downloads and can automatically reject unusable releases, remove them from the download client, blocklist the bad release, and trigger a replacement search.

> **Status:** v0.1.1 — early public release. Start with `DRY_RUN=true`.

## What it detects

- Very small media files (configurable minimum size)
- Sample-only releases
- Completed downloads with no usable video
- Unreadable/corrupt video streams using `ffprobe`
- Archive-only downloads where no video was extracted
- Missing output paths (warning by default; optional reject)
- Common TV/movie video formats including MKV, MP4, M4V, MOV, AVI, WMV, WebM, TS/M2TS, MPG/MPEG, VOB, OGV/OGM, 3GP, RM/RMVB, MXF, DV and others

When a release is rejected, ArrGuard can:

1. Remove it from the download client
2. Blocklist the release in Sonarr/Radarr
3. Trigger a new episode/movie search

## Install

Ubuntu/Debian:

```bash
curl -fsSL https://raw.githubusercontent.com/kasundigital/arrguard/main/install.sh | sudo bash
```

Then edit:

```bash
sudo nano /etc/arrguard.conf
```

Add your Sonarr and/or Radarr API key and keep this enabled for the first test:

```ini
DRY_RUN="true"
```

Run manually:

```bash
sudo /opt/arrguard/arrguard.sh
```

Watch the log:

```bash
sudo tail -f /var/log/arrguard.log
```

When the log looks correct, set:

```ini
DRY_RUN="false"
```

## Sonarr Connect setup

Go to:

**Settings → Connect → + → Custom Script**

Use:

```text
Name: ArrGuard
Path: /opt/arrguard/arrguard.sh
```

Recommended trigger:

- ✅ On Manual Interaction Required

You can also run ArrGuard manually at any time; each run scans the current queue.

## Radarr Connect setup

Use the same script:

```text
/opt/arrguard/arrguard.sh
```

Set `APP="radarr"` in `/etc/arrguard.conf` if the machine only runs Radarr.

For hosts with both apps, use separate config files and wrappers (multi-instance support will be improved in a future release).

## Configuration

Example:

```ini
APP="auto"

SONARR_URL="http://127.0.0.1:8989"
SONARR_API_KEY=""

RADARR_URL="http://127.0.0.1:7878"
RADARR_API_KEY=""

MIN_VIDEO_SIZE_MIB="100"
DRY_RUN="true"

CHECK_SAMPLE="true"
CHECK_VIDEO_STREAM="true"
CHECK_ARCHIVES="true"

REMOVE_FROM_CLIENT="true"
BLOCKLIST="true"
SEARCH_AGAIN="true"

REJECT_NO_VIDEO="true"
REJECT_MISSING_PATH="false"

# Optional Docker/container path translation:
PATH_MAPPINGS=""
```

## Docker and path mapping

ArrGuard can be used when Sonarr or Radarr runs in Docker, but **the download path reported by Sonarr/Radarr must be accessible to ArrGuard**.

This matters because Sonarr may report a container path such as:

```text
/downloads/complete/Some.Release
```

while the same directory on the Docker host is actually:

```text
/mnt/downloads/complete/Some.Release
```

If ArrGuard runs on the **host**, configure a path translation in `/etc/arrguard.conf`:

```ini
PATH_MAPPINGS="/downloads=/mnt/downloads"
```

Multiple mappings are separated with semicolons:

```ini
PATH_MAPPINGS="/downloads=/mnt/downloads;/media=/mnt/media"
```

Example Docker Compose volume:

```yaml
services:
  sonarr:
    volumes:
      - /mnt/downloads:/downloads
      - /mnt/media/tv:/tv
```

With that example, ArrGuard running on the host needs:

```ini
PATH_MAPPINGS="/downloads=/mnt/downloads;/tv=/mnt/media/tv"
```

### Docker networking

If ArrGuard runs on the host and the Sonarr/Radarr port is published, URLs such as these are fine:

```ini
SONARR_URL="http://127.0.0.1:8989"
RADARR_URL="http://127.0.0.1:7878"
```

If ArrGuard is later run inside another container on the same Docker network, use the service name instead, for example:

```ini
SONARR_URL="http://sonarr:8989"
RADARR_URL="http://radarr:7878"
```

Do not use `127.0.0.1` from one container to reach a different container.

### Important

A wrong Docker path mapping can make a perfectly good download look missing. For this reason:

```ini
REJECT_MISSING_PATH="false"
```

is the safe default. Verify your mappings and run with `DRY_RUN="true"` before enabling automatic removal/blocklisting.

## Safety

ArrGuard can remove downloads and blocklist releases. Test with `DRY_RUN=true` first.

A missing path can be caused by remote path mappings or mount problems rather than a bad release, so `REJECT_MISSING_PATH` is disabled by default.

## Requirements

- Linux
- Bash
- curl
- jq
- ffmpeg / ffprobe
- findutils
- util-linux (`flock`)
- Sonarr or Radarr API access

## Uninstall

```bash
sudo /opt/arrguard/uninstall.sh
```

To also remove config and logs:

```bash
sudo PURGE_CONFIG=1 /opt/arrguard/uninstall.sh
```

## Roadmap

- Better incomplete RAR/7z detection
- Password-protected archive detection
- Multiple Sonarr/Radarr instances
- Configurable minimum sizes per app/profile
- Notifications/webhooks
- Optional systemd timer mode
- Automated integration tests

## License

MIT License. See [LICENSE](LICENSE).

## Support

If ArrGuard saves you time, you can support development through the project author's Buy Me a Coffee link when it is added to the project profile.

Designed & developed by **Kasun Indika**.
