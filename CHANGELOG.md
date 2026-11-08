# Changelog

All notable changes to ArrGuard will be documented here.

## [0.3.0] - 2026-11-08

### Added

- `ARCHIVE_ACTION="extract"`: tests archives in downloads with no usable video and
  extracts intact ones (RAR via `unrar`, 7z/zip via `7z`). Password-protected, corrupt,
  incomplete and no-video-inside archives are rejected. Extraction goes to a hidden
  `.arrguard-extract` folder (ignored by Sonarr/Radarr) and is moved into place only
  when complete; ownership is copied from the download folder.
- `EXTRACT_MIN_FREE_MIB` free-space guard before extracting.
- Installer installs `unrar` / `7zip` when available.

### Fixed

- A video was rejected as unreadable when `ffprobe` hit its timeout. Timeouts now
  log a warning and keep the file. (Was pushed after v0.2.0 was merged.)

## [0.2.0] - 2026-11-08

### Fixed

- Good releases could be deleted: items in the `importing`/`imported` state (and any
  `completed` item) were inspected. Now only `importPending` and `importBlocked` are.
- Torrents waiting for Unpackerr/extraction were rejected as `ARCHIVE_NO_VIDEO` or
  `SMALL_VIDEO`. Archives next to a missing/small video now wait (`ARCHIVE_ACTION="skip"`).
- Downloads still being imported/extracted are skipped (`MIN_AGE_MINUTES`).
- Unknown items in the client category were inspected and could be deleted. Now off by
  default (`INCLUDE_UNKNOWN_ITEMS="false"`).
- Replacement search never worked: POST bodies were invalid JSON and Sonarr's queue has no
  `episodeIds`. Replacement now uses Sonarr/Radarr's own redownload (`skipRedownload=false`).
- The Connect **Test** button triggered a full live scan. It now exits immediately.
- `DRY_RUN` typos enabled live mode. Only an explicit false value does now.
- Season packs were rejected once per episode. Each download is inspected once.
- A parent folder named "sample" could flag a real file as a sample.
- Unreadable config or log file no longer fails silently / aborts the run.
- `PATH_MAPPINGS` with trailing slashes did not match.
- Queue reads are paged (previously capped at 200 items).
- `ffprobe` has a timeout; `.dat` is no longer treated as video.

### Added

- Per-app minimum sizes: `SONARR_MIN_VIDEO_SIZE_MIB`, `RADARR_MIN_VIDEO_SIZE_MIB`
- systemd service + timer installed by `install.sh` (not enabled by default)
- Auto-detects the calling app when run from Sonarr/Radarr Connect
- `ARRGUARD_REF` to pin the installer to a tag
- Mock-API integration tests (`tests/run-tests.sh`), run in CI

## [0.1.1] - 2026-10-01

### Added

- Docker/container path translation with `PATH_MAPPINGS`
- Docker path-mapping and networking documentation
- Safe guidance for host-vs-container download paths

## [0.1.0] - 2026-10-01

### Added

- Initial public release
- Sonarr and Radarr queue scanning
- Automatic app detection
- Small-video detection
- Sample-only release detection
- No-video detection
- Archive-without-video detection
- ffprobe video-stream validation
- Optional download-client removal
- Release blocklisting
- Automatic replacement search
- Dry-run mode
- File locking to prevent overlapping runs
- One-command Ubuntu/Debian installer
- Uninstaller
- ShellCheck CI workflow
