#!/usr/bin/env bash
set -Eeuo pipefail

VERSION="0.3.0"
CONFIG_FILE="${ARRGUARD_CONFIG:-/etc/arrguard.conf}"

APP="auto"
SONARR_URL="http://127.0.0.1:8989"
SONARR_API_KEY=""
RADARR_URL="http://127.0.0.1:7878"
RADARR_API_KEY=""
# Global fallback minimum. Per-app values below override it when set.
MIN_VIDEO_SIZE_MIB="100"
SONARR_MIN_VIDEO_SIZE_MIB=""
RADARR_MIN_VIDEO_SIZE_MIB=""
DRY_RUN="true"
CHECK_SAMPLE="true"
CHECK_VIDEO_STREAM="true"
CHECK_ARCHIVES="true"
# What to do when a download contains archives but no usable video:
#   skip    = leave it alone (extraction by Unpackerr/client may still be pending)
#   extract = look inside + test the archive; extract it if it is intact and
#             contains video, reject it if it is password-protected, corrupt,
#             incomplete or has no video inside (needs unrar and/or 7z)
#   reject  = treat it as a bad release without testing
ARCHIVE_ACTION="skip"
# Free space to keep on the download disk after extracting (MiB).
EXTRACT_MIN_FREE_MIB="1024"
# Skip downloads whose files changed within this many minutes
# (import, extraction or move may still be in progress). 0 disables.
MIN_AGE_MINUTES="10"
FFPROBE_TIMEOUT="60"
REMOVE_FROM_CLIENT="true"
BLOCKLIST="true"
# When true, Sonarr/Radarr's own failed-download handling searches for a
# replacement after the release is blocklisted (requires BLOCKLIST=true).
SEARCH_AGAIN="true"
REJECT_NO_VIDEO="true"
REJECT_MISSING_PATH="false"
# Include downloads in the client category that Sonarr/Radarr does not
# recognise. Off by default: those may not be media at all.
INCLUDE_UNKNOWN_ITEMS="false"
# Optional Docker/container-to-host path mappings, separated by semicolons.
# Example: /downloads=/mnt/downloads;/media=/mnt/media
PATH_MAPPINGS=""
LOG_FILE="/var/log/arrguard.log"
LOCK_FILE="/run/lock/arrguard.lock"

if [[ -r "$CONFIG_FILE" ]]; then
  # shellcheck disable=SC1090
  source "$CONFIG_FILE"
elif [[ -e "$CONFIG_FILE" ]]; then
  echo "ArrGuard: ERROR | Config $CONFIG_FILE exists but is not readable by $(id -un)." >&2
  exit 1
fi

# Logging must never be the reason a run aborts.
if ! { mkdir -p "$(dirname "$LOG_FILE")" && touch "$LOG_FILE"; } 2>/dev/null; then
  echo "ArrGuard: WARNING | Cannot write $LOG_FILE as $(id -un); logging to stderr only." >&2
  LOG_FILE=""
fi

log() {
  local line
  line="$(date '+%Y-%m-%d %H:%M:%S') | $*"
  if [[ -n "$LOG_FILE" ]]; then
    printf '%s\n' "$line" | tee -a "$LOG_FILE"
  else
    printf '%s\n' "$line" >&2
  fi
}

bool_true() {
  [[ "${1,,}" == "true" || "$1" == "1" || "${1,,}" == "yes" ]]
}

# Fail-safe: anything other than an explicit false value keeps dry-run on.
is_dry_run() {
  local v="${DRY_RUN,,}"
  v="${v//[[:space:]]/}"
  [[ "$v" != "false" && "$v" != "0" && "$v" != "no" ]]
}

command_exists() {
  command -v "$1" >/dev/null 2>&1
}

# Sonarr/Radarr Connect "Test" button: exit cleanly without scanning anything.
event_type="${sonarr_eventtype:-${radarr_eventtype:-}}"
if [[ "$event_type" == "Test" ]]; then
  log "INFO | Connect test event received; exiting without scanning."
  exit 0
fi

for cmd in curl jq find stat sort head grep awk flock; do
  if ! command_exists "$cmd"; then
    log "ERROR | Missing dependency: $cmd"
    exit 1
  fi
done

for var in MIN_VIDEO_SIZE_MIB MIN_AGE_MINUTES FFPROBE_TIMEOUT EXTRACT_MIN_FREE_MIB; do
  if [[ ! "${!var}" =~ ^[0-9]+$ ]]; then
    log "ERROR | $var must be a whole number (got '${!var}')."
    exit 1
  fi
done

if ! { mkdir -p "$(dirname "$LOCK_FILE")" && : >>"$LOCK_FILE"; } 2>/dev/null; then
  LOCK_FILE="${TMPDIR:-/tmp}/arrguard-$(id -u).lock"
fi
exec 9>>"$LOCK_FILE"
if ! flock -n 9; then
  log "INFO | Another ArrGuard run is already active; exiting."
  exit 0
fi

api_url=""
api_key=""
app_name=""

api_get_raw() {
  local base="$1"
  local key="$2"
  local endpoint="$3"
  curl -fsS --max-time 30 -H "X-Api-Key: $key" "$base/api/v3/$endpoint"
}

use_app() {
  app_name="$1"
  if [[ "$1" == "sonarr" ]]; then
    api_url="$SONARR_URL"
    api_key="$SONARR_API_KEY"
  else
    api_url="$RADARR_URL"
    api_key="$RADARR_API_KEY"
  fi
}

detect_app() {
  case "$APP" in
    sonarr|radarr)
      use_app "$APP"
      return
      ;;
  esac

  # Invoked by a Connect Custom Script: the caller tells us which app it is.
  if [[ -n "${sonarr_eventtype:-}" ]]; then use_app sonarr; return; fi
  if [[ -n "${radarr_eventtype:-}" ]]; then use_app radarr; return; fi

  if [[ -n "$SONARR_API_KEY" ]] && api_get_raw "$SONARR_URL" "$SONARR_API_KEY" "system/status" >/dev/null 2>&1; then
    use_app sonarr
    return
  fi

  if [[ -n "$RADARR_API_KEY" ]] && api_get_raw "$RADARR_URL" "$RADARR_API_KEY" "system/status" >/dev/null 2>&1; then
    use_app radarr
    return
  fi

  log "ERROR | Could not detect Sonarr or Radarr. Check APP, URL and API key."
  exit 1
}

api_get() {
  api_get_raw "$api_url" "$api_key" "$1"
}

api_delete() {
  curl -fsS --max-time 30 -X DELETE \
    -H "X-Api-Key: $api_key" \
    "$api_url/api/v3/$1"
}

min_size_mib() {
  local v=""
  if [[ "$app_name" == "sonarr" ]]; then
    v="$SONARR_MIN_VIDEO_SIZE_MIB"
  else
    v="$RADARR_MIN_VIDEO_SIZE_MIB"
  fi
  if [[ "$v" =~ ^[0-9]+$ ]]; then
    printf '%s' "$v"
  else
    printf '%s' "$MIN_VIDEO_SIZE_MIB"
  fi
}

is_video_file() {
  local file="${1,,}"
  case "$file" in
    *.mkv|*.mk3d|*.mp4|*.m4v|*.mov|*.qt|*.avi|*.divx|*.xvid|*.wmv|*.asf|*.webm|*.flv|*.f4v|*.ts|*.m2ts|*.mts|*.m2t|*.mpg|*.mpeg|*.mpeg1|*.mpeg2|*.mpe|*.mpv|*.vob|*.ogv|*.ogm|*.3gp|*.3g2|*.rm|*.rmvb|*.mxf|*.nut|*.dv|*.vro)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

# Only the part of the path inside the download folder is checked, so a
# parent directory name can never make a file look like a sample.
is_sample_file() {
  local root="$1"
  local file="$2"
  local rel
  if [[ -d "$root" ]]; then
    rel="${file#"$root"}"
  else
    rel="/${file##*/}"
  fi
  rel="${rel,,}"
  case "$rel" in
    */sample/*|*/samples/*|sample/*|samples/*|*sample.mkv|*sample.mp4|*sample.avi|*-sample.*|*_sample.*|*.sample.*)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

find_largest_video() {
  local root="$1"
  local file size

  while IFS= read -r -d '' file; do
    if is_video_file "$file"; then
      size="$(stat -c '%s' "$file" 2>/dev/null || echo 0)"
      printf '%s|%s\n' "$size" "$file"
    fi
  done < <(find "$root" -name "$EXTRACT_TMP_NAME" -prune -o -type f -print0 2>/dev/null) |
    sort -t'|' -k1,1nr |
    head -n1
}

has_archive_files() {
  local root="$1"
  find "$root" -name "$EXTRACT_TMP_NAME" -prune -o -type f \( \
    -iname "*.rar" -o -iname "*.r[0-9][0-9]" -o -iname "*.[0-9][0-9][0-9]" -o \
    -iname "*.7z" -o -iname "*.zip" -o \
    -iname "*.tar" -o -iname "*.gz" -o -iname "*.bz2" -o -iname "*.xz" \
  \) -print -quit 2>/dev/null | grep -q .
}

# ---- archive test + extract ------------------------------------------------

EXTRACT_TMP_NAME=".arrguard-extract"

# First volume of every archive set in the download (one per set).
archive_candidates() {
  local root="$1"
  find "$root" -name "$EXTRACT_TMP_NAME" -prune -o -type f \( \
    -iname "*.rar" -o -iname "*.7z" -o -iname "*.7z.001" -o -iname "*.zip" \
  \) -print 2>/dev/null | while IFS= read -r f; do
    local lower="${f,,}"
    # multi-part RAR: keep only part1/part01/part001
    if [[ "$lower" =~ \.part([0-9]+)\.rar$ ]]; then
      (( 10#${BASH_REMATCH[1]} == 1 )) || continue
    fi
    printf '%s\n' "$f"
  done | sort
}

archive_tool() {
  local lower="${1,,}"
  if [[ "$lower" == *.rar ]]; then
    command_exists unrar && { printf 'unrar'; return 0; }
    command_exists 7z && { printf '7z'; return 0; }
  else
    command_exists 7z && { printf '7z'; return 0; }
  fi
  return 1
}

# Prints the file names inside the archive. -p- / -p- : never prompt for a password.
archive_list() {
  local tool="$1" file="$2"
  if [[ "$tool" == "unrar" ]]; then
    unrar lb -p- "$file" </dev/null 2>/dev/null
  else
    7z l -slt -p- "$file" </dev/null 2>/dev/null |
      awk '/^----------/{f=1;next} f && /^Path = /{sub(/^Path = /,""); print}'
  fi
}

# Total unpacked size in bytes.
archive_size() {
  local tool="$1" file="$2"
  if [[ "$tool" == "unrar" ]]; then
    unrar l -v -p- "$file" </dev/null 2>/dev/null |
      awk 'NF{last=$1} END{if (last ~ /^[0-9]+$/) print last; else print 0}'
  else
    7z l -slt -p- "$file" </dev/null 2>/dev/null |
      awk '/^----------/{f=1} f && /^Size = /{s+=$3} END{print s+0}'
  fi
}

# Returns the tool's exit code: 0 = intact.
archive_test() {
  local tool="$1" file="$2"
  if [[ "$tool" == "unrar" ]]; then
    unrar t -p- -idq "$file" </dev/null >/dev/null 2>&1
  else
    7z t -p- -bso0 -bsp0 -bse0 "$file" </dev/null >/dev/null 2>&1
  fi
}

archive_extract() {
  local tool="$1" file="$2" dest="$3"
  if [[ "$tool" == "unrar" ]]; then
    unrar x -o+ -p- -idq -y "$file" "$dest/" </dev/null >/dev/null 2>&1
  else
    7z x -p- -aoa -bso0 -bsp0 -bse0 -o"$dest" "$file" </dev/null >/dev/null 2>&1
  fi
}

archive_fail_reason() {
  local tool="$1" rc="$2"
  if [[ "$tool" == "unrar" && "$rc" == "11" ]]; then
    printf 'ARCHIVE_PASSWORD'
  elif [[ "$tool" == "unrar" ]]; then
    printf 'ARCHIVE_CORRUPT'
  else
    printf 'ARCHIVE_PASSWORD_OR_CORRUPT'
  fi
}

# Handles a download whose usable video is missing/small but has archives.
# Either rejects it, extracts it (next run sees the video), or waits.
handle_archives() {
  local item="$1" root="$2" title="$3"
  local -a candidates=() video_archives=() video_tools=()
  local c i tool names rc fail_reason="" total=0 size avail dir tmp

  mapfile -t candidates < <(archive_candidates "$root")
  if (( ${#candidates[@]} == 0 )); then
    log "WAIT | Archive type not supported for extraction | $title"
    return 0
  fi

  for c in "${candidates[@]}"; do
    if ! tool="$(archive_tool "$c")"; then
      log "WARNING | unrar/7z not installed; cannot inspect archive | $title"
      return 0
    fi
    rc=0
    names="$(archive_list "$tool" "$c")" || rc=$?
    if grep -qiE '\.(mkv|mk3d|mp4|m4v|mov|avi|wmv|webm|ts|m2ts|mts|mpg|mpeg|vob|ogv|3gp|rmvb|mxf)$' <<<"$names"; then
      video_archives+=("$c")
      video_tools+=("$tool")
    elif [[ -z "$names" ]]; then
      # Nothing listed: encrypted headers or a broken first volume.
      rc=0
      archive_test "$tool" "$c" || rc=$?
      if (( rc != 0 )); then
        fail_reason="$(archive_fail_reason "$tool" "$rc")"
      fi
    fi
  done

  if (( ${#video_archives[@]} == 0 )); then
    reject_queue_item "$item" "${fail_reason:-ARCHIVE_NO_VIDEO_INSIDE}"
    return 0
  fi

  for i in "${!video_archives[@]}"; do
    size="$(archive_size "${video_tools[$i]}" "${video_archives[$i]}")"
    total=$((total + size))
  done

  avail="$(df -P -B1 "$root" 2>/dev/null | awk 'NR==2{print $4}')"
  if [[ "$avail" =~ ^[0-9]+$ ]] && (( avail < total + EXTRACT_MIN_FREE_MIB * 1024 * 1024 )); then
    log "WAIT | Not enough free space to extract ($((total / 1024 / 1024)) MiB needed, $((avail / 1024 / 1024)) MiB free) | $title"
    return 0
  fi

  for i in "${!video_archives[@]}"; do
    rc=0
    archive_test "${video_tools[$i]}" "${video_archives[$i]}" || rc=$?
    if (( rc != 0 )); then
      log "BAD | Archive test failed (rc=$rc) | ${video_archives[$i]##*/}"
      reject_queue_item "$item" "$(archive_fail_reason "${video_tools[$i]}" "$rc")"
      return 0
    fi
  done

  if is_dry_run; then
    log "DRYRUN | Archive OK; would extract $((total / 1024 / 1024)) MiB | $title"
    return 0
  fi

  for i in "${!video_archives[@]}"; do
    c="${video_archives[$i]}"
    dir="$(dirname "$c")"
    tmp="$dir/$EXTRACT_TMP_NAME"
    # Extract into a hidden folder (ignored by Sonarr/Radarr) so a
    # half-written file is never imported, then move into place.
    [[ -n "$dir" && -d "$dir" ]] || continue
    rm -rf -- "$tmp"
    mkdir -p -- "$tmp"
    if ! archive_extract "${video_tools[$i]}" "$c" "$tmp"; then
      rm -rf -- "$tmp"
      log "ERROR | Extraction failed | ${c##*/} | $title"
      return 0
    fi
    chown -R --reference="$dir" -- "$tmp" 2>/dev/null || true
    find "$tmp" -mindepth 1 -maxdepth 1 -exec mv -f -t "$dir" -- {} +
    rmdir -- "$tmp" 2>/dev/null || rm -rf -- "$tmp"
  done

  log "EXTRACTED | $((total / 1024 / 1024)) MiB | $title"
}

recently_modified() {
  local root="$1"
  (( MIN_AGE_MINUTES > 0 )) || return 1
  find "$root" -mmin "-$MIN_AGE_MINUTES" -print -quit 2>/dev/null | grep -q .
}

video_readable() {
  local file="$1"
  local -a cmd

  if ! bool_true "$CHECK_VIDEO_STREAM"; then
    return 0
  fi

  if ! command_exists ffprobe; then
    log "WARNING | ffprobe not installed; skipping stream validation."
    return 0
  fi

  cmd=(ffprobe -v error -select_streams v:0
    -show_entries stream=codec_type
    -of default=noprint_wrappers=1:nokey=1 "$file")
  if command_exists timeout && (( FFPROBE_TIMEOUT > 0 )); then
    cmd=(timeout "$FFPROBE_TIMEOUT" "${cmd[@]}")
  fi

  local out rc=0
  out="$("${cmd[@]}" </dev/null 2>/dev/null)" || rc=$?

  # Timeout (124) or ffprobe killed: we could not decide, so never reject on it.
  if (( rc == 124 || rc == 137 )); then
    log "WARNING | ffprobe timed out after ${FFPROBE_TIMEOUT}s; not rejecting | $file"
    return 0
  fi

  grep -q '^video$' <<<"$out"
}

map_output_path() {
  local path="$1"
  local mapping from to suffix
  local -a mappings

  if [[ -z "$PATH_MAPPINGS" ]]; then
    printf '%s' "$path"
    return
  fi

  IFS=';' read -r -a mappings <<<"$PATH_MAPPINGS"

  for mapping in "${mappings[@]}"; do
    [[ "$mapping" == *=* ]] || continue
    from="${mapping%%=*}"
    to="${mapping#*=}"
    # Tolerate trailing slashes ("/downloads/=/mnt/downloads/").
    while [[ "$from" == */ && "$from" != "/" ]]; do from="${from%/}"; done
    while [[ "$to" == */ && "$to" != "/" ]]; do to="${to%/}"; done

    [[ -n "$from" && -n "$to" ]] || continue

    if [[ "$path" == "$from" ]]; then
      printf '%s' "$to"
      return
    fi

    if [[ "$path" == "$from/"* ]]; then
      suffix="${path#"$from"}"
      printf '%s%s' "$to" "$suffix"
      return
    fi
  done

  printf '%s' "$path"
}

queue_endpoint() {
  local page="$1"
  local unknown="false"
  bool_true "$INCLUDE_UNKNOWN_ITEMS" && unknown="true"
  if [[ "$app_name" == "sonarr" ]]; then
    printf '%s' "queue?page=$page&pageSize=200&includeUnknownSeriesItems=$unknown"
  else
    printf '%s' "queue?page=$page&pageSize=200&includeUnknownMovieItems=$unknown"
  fi
}

reject_queue_item() {
  local item="$1"
  local reason="$2"
  local queue_id title remove blocklist skip_redownload query

  queue_id="$(jq -r '.id // empty' <<<"$item")"
  title="$(jq -r '.title // "Unknown"' <<<"$item")"

  if [[ -z "$queue_id" ]]; then
    log "ERROR | Cannot reject '$title': queue ID missing."
    return
  fi

  remove="false"
  blocklist="false"
  skip_redownload="true"
  bool_true "$REMOVE_FROM_CLIENT" && remove="true"
  bool_true "$BLOCKLIST" && blocklist="true"
  bool_true "$SEARCH_AGAIN" && skip_redownload="false"

  log "REJECT | $reason | $title | queue=$queue_id"

  if [[ "$blocklist" != "true" && "$skip_redownload" == "false" ]]; then
    log "INFO | SEARCH_AGAIN needs BLOCKLIST=true; no replacement search will run."
  fi

  if is_dry_run; then
    log "DRYRUN | Would remove=$remove blocklist=$blocklist search_again=$([[ $skip_redownload == false ]] && echo true || echo false)"
    return
  fi

  query="queue/$queue_id?removeFromClient=$remove&blocklist=$blocklist&skipRedownload=$skip_redownload&changeCategory=false"

  if api_delete "$query" >/dev/null 2>&1; then
    log "ACTION | Removed=$remove blocklisted=$blocklist queue item $queue_id"
  else
    log "ERROR | Failed to remove/blocklist queue item $queue_id"
  fi
}

declare -A seen_downloads=()
records_file=""

inspect_item() {
  local item="$1"
  local title state output_path download_id media_id video_info video_bytes video_path video_mib reason min_mib min_bytes

  title="$(jq -r '.title // "Unknown"' <<<"$item")"
  state="$(jq -r '.trackedDownloadState // ""' <<<"$item")"
  download_id="$(jq -r '.downloadId // ""' <<<"$item")"
  output_path="$(jq -r '.outputPath // ""' <<<"$item")"
  if [[ "$app_name" == "sonarr" ]]; then
    media_id="$(jq -r '.seriesId // empty' <<<"$item")"
  else
    media_id="$(jq -r '.movieId // empty' <<<"$item")"
  fi

  # Only downloads that finished and are waiting on / blocked from import.
  # Never touch downloading, importing, imported or failed items.
  case "$state" in
    importPending|importBlocked) ;;
    *) return 0 ;;
  esac

  if [[ -z "$media_id" ]] && ! bool_true "$INCLUDE_UNKNOWN_ITEMS"; then
    return 0
  fi

  # Season packs appear once per episode; inspect each download only once.
  if [[ -n "$download_id" ]]; then
    if [[ -n "${seen_downloads[$download_id]:-}" ]]; then
      return 0
    fi
    seen_downloads[$download_id]=1
  fi

  if [[ -z "$output_path" || "$output_path" == "null" ]]; then
    return 0
  fi
  output_path="$(map_output_path "$output_path")"

  if [[ ! -e "$output_path" ]]; then
    log "WARNING | PATH_MISSING | $title | $output_path"
    if bool_true "$REJECT_MISSING_PATH"; then
      reject_queue_item "$item" "PATH_MISSING"
    fi
    return 0
  fi

  if recently_modified "$output_path"; then
    log "WAIT | Files changed in the last $MIN_AGE_MINUTES min (import/extract in progress?) | $title"
    return 0
  fi

  local archives="false"
  if bool_true "$CHECK_ARCHIVES" && has_archive_files "$output_path"; then
    archives="true"
  fi

  video_info="$(find_largest_video "$output_path" || true)"
  reason=""
  video_mib="0"

  if [[ -z "$video_info" ]]; then
    if [[ "$archives" == "true" ]]; then
      reason="ARCHIVE_NO_VIDEO"
    elif bool_true "$REJECT_NO_VIDEO"; then
      reason="NO_VIDEO"
    else
      log "INFO | No usable video found but REJECT_NO_VIDEO is disabled | $title"
      return 0
    fi
  else
    video_bytes="${video_info%%|*}"
    video_path="${video_info#*|}"
    video_mib="$((video_bytes / 1024 / 1024))"
    min_mib="$(min_size_mib)"
    min_bytes="$((min_mib * 1024 * 1024))"

    if bool_true "$CHECK_SAMPLE" && is_sample_file "$output_path" "$video_path"; then
      reason="SAMPLE_ONLY"
    elif (( video_bytes < min_bytes )); then
      reason="SMALL_VIDEO"
    elif ! video_readable "$video_path"; then
      reason="UNREADABLE_VIDEO"
    fi
  fi

  # Archives next to a missing/small video: test + extract, or wait.
  if [[ "$archives" == "true" && ( "$reason" == "ARCHIVE_NO_VIDEO" || "$reason" == "SMALL_VIDEO" ) && "${ARCHIVE_ACTION,,}" == "extract" ]]; then
    handle_archives "$item" "$output_path" "$title"
    return 0
  fi

  # Archives next to a missing/small video usually mean extraction is not
  # finished yet (Unpackerr, client post-processing). Leave it alone.
  if [[ "$archives" == "true" && ( "$reason" == "ARCHIVE_NO_VIDEO" || "$reason" == "SMALL_VIDEO" ) && "${ARCHIVE_ACTION,,}" != "reject" ]]; then
    log "WAIT | $reason with archives present; extraction may be pending (ARCHIVE_ACTION=skip) | $title"
    return 0
  fi

  if [[ -z "$reason" ]]; then
    log "GOOD | $title | ${video_mib} MiB"
    return 0
  fi

  log "BAD | $reason | $title | ${video_mib} MiB | $output_path"
  reject_queue_item "$item" "$reason"
}

main() {
  detect_app

  if [[ -z "$api_key" ]]; then
    log "ERROR | API key is empty for $app_name."
    exit 1
  fi

  local status_json
  status_json="$(api_get "system/status" 2>/dev/null || true)"
  if [[ -z "$status_json" ]]; then
    log "ERROR | Cannot reach $app_name at $api_url"
    exit 1
  fi

  local mode="live"
  is_dry_run && mode="dry-run"
  log "START | ArrGuard v$VERSION | app=$app_name | mode=$mode | event=${event_type:-manual}"

  local page=1 queue total
  records_file="$(mktemp)"
  trap '[[ -n "$records_file" ]] && rm -f "$records_file"' EXIT

  while :; do
    queue="$(api_get "$(queue_endpoint "$page")" 2>/dev/null || true)"
    if [[ -z "$queue" ]] || ! jq -e '.records' >/dev/null 2>&1 <<<"$queue"; then
      log "ERROR | Could not read $app_name queue (page $page)."
      exit 1
    fi
    jq -c '.records[]?' <<<"$queue" >>"$records_file"
    total="$(jq -r '.totalRecords // 0' <<<"$queue")"
    if [[ ! "$total" =~ ^[0-9]+$ ]] || (( page * 200 >= total )) || (( page >= 50 )); then
      break
    fi
    page=$((page + 1))
  done

  while IFS= read -r item; do
    inspect_item "$item"
  done <"$records_file"

  log "DONE | Queue scan complete."
}

main "$@"
