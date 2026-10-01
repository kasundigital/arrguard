#!/usr/bin/env bash
set -Eeuo pipefail

VERSION="0.1.1"
CONFIG_FILE="${ARRGUARD_CONFIG:-/etc/arrguard.conf}"

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
# Optional Docker/container-to-host path mappings, separated by semicolons.
# Example: /downloads=/mnt/downloads;/media=/mnt/media
PATH_MAPPINGS=""
LOG_FILE="/var/log/arrguard.log"
LOCK_FILE="/run/lock/arrguard.lock"

if [[ -r "$CONFIG_FILE" ]]; then
  # shellcheck disable=SC1090
  source "$CONFIG_FILE"
fi

mkdir -p "$(dirname "$LOG_FILE")" "$(dirname "$LOCK_FILE")"
touch "$LOG_FILE"

log() {
  printf '%s | %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" | tee -a "$LOG_FILE"
}

bool_true() {
  [[ "${1,,}" == "true" || "$1" == "1" || "${1,,}" == "yes" ]]
}

command_exists() {
  command -v "$1" >/dev/null 2>&1
}

for cmd in curl jq find stat sort head grep awk flock; do
  if ! command_exists "$cmd"; then
    log "ERROR | Missing dependency: $cmd"
    exit 1
  fi
done

exec 9>"$LOCK_FILE"
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

detect_app() {
  if [[ "$APP" == "sonarr" ]]; then
    app_name="sonarr"
    api_url="$SONARR_URL"
    api_key="$SONARR_API_KEY"
    return
  fi

  if [[ "$APP" == "radarr" ]]; then
    app_name="radarr"
    api_url="$RADARR_URL"
    api_key="$RADARR_API_KEY"
    return
  fi

  if [[ -n "$SONARR_API_KEY" ]] && api_get_raw "$SONARR_URL" "$SONARR_API_KEY" "system/status" >/dev/null 2>&1; then
    app_name="sonarr"
    api_url="$SONARR_URL"
    api_key="$SONARR_API_KEY"
    return
  fi

  if [[ -n "$RADARR_API_KEY" ]] && api_get_raw "$RADARR_URL" "$RADARR_API_KEY" "system/status" >/dev/null 2>&1; then
    app_name="radarr"
    api_url="$RADARR_URL"
    api_key="$RADARR_API_KEY"
    return
  fi

  log "ERROR | Could not detect Sonarr or Radarr. Check APP, URL and API key."
  exit 1
}

api_get() {
  api_get_raw "$api_url" "$api_key" "$1"
}

api_post() {
  local endpoint="$1"
  local body="${2:-{}}"
  curl -fsS --max-time 30 -X POST \
    -H "X-Api-Key: $api_key" \
    -H "Content-Type: application/json" \
    -d "$body" \
    "$api_url/api/v3/$endpoint"
}

api_delete() {
  curl -fsS --max-time 30 -X DELETE \
    -H "X-Api-Key: $api_key" \
    "$api_url/api/v3/$1"
}

is_video_file() {
  local file="${1,,}"
  case "$file" in
    *.mkv|*.mk3d|*.mp4|*.m4v|*.mov|*.qt|*.avi|*.divx|*.xvid|*.wmv|*.asf|*.webm|*.flv|*.f4v|*.ts|*.m2ts|*.mts|*.m2t|*.mpg|*.mpeg|*.mpeg1|*.mpeg2|*.mpe|*.mpv|*.vob|*.ogv|*.ogm|*.3gp|*.3g2|*.rm|*.rmvb|*.mxf|*.nut|*.dv|*.vro|*.dat)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

is_sample_file() {
  local file="${1,,}"
  case "$file" in
    */sample/*|*/samples/*|*sample.mkv|*sample.mp4|*sample.avi|*-sample.*|*_sample.*|*.sample.*)
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
  done < <(find "$root" -type f -print0 2>/dev/null) |
    sort -t'|' -k1,1nr |
    head -n1
}

has_archive_files() {
  local root="$1"
  find "$root" -type f \( \
    -iname "*.rar" -o -iname "*.r00" -o -iname "*.r01" -o -iname "*.001" -o \
    -iname "*.002" -o -iname "*.7z" -o -iname "*.7z.001" -o -iname "*.zip" -o \
    -iname "*.tar" -o -iname "*.gz" -o -iname "*.bz2" -o -iname "*.xz" \
  \) -print -quit 2>/dev/null | grep -q .
}

video_readable() {
  local file="$1"

  if ! bool_true "$CHECK_VIDEO_STREAM"; then
    return 0
  fi

  if ! command_exists ffprobe; then
    log "WARNING | ffprobe not installed; skipping stream validation."
    return 0
  fi

  ffprobe -v error -select_streams v:0 \
    -show_entries stream=codec_type \
    -of default=noprint_wrappers=1:nokey=1 \
    "$file" 2>/dev/null | grep -q '^video$'
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
  if [[ "$app_name" == "sonarr" ]]; then
    printf '%s' "queue?page=1&pageSize=200&includeUnknownSeriesItems=true"
  else
    printf '%s' "queue?page=1&pageSize=200&includeUnknownMovieItems=true"
  fi
}

search_replacement() {
  local item="$1"

  if ! bool_true "$SEARCH_AGAIN"; then
    log "INFO | SEARCH_AGAIN disabled."
    return
  fi

  if [[ "$app_name" == "sonarr" ]]; then
    local ids
    ids="$(jq -c '.episodeIds // []' <<<"$item")"
    if [[ "$(jq 'length' <<<"$ids")" -lt 1 ]]; then
      log "WARNING | No Sonarr episode IDs available for replacement search."
      return
    fi

    local body
    body="$(jq -cn --argjson ids "$ids" '{name:"EpisodeSearch",episodeIds:$ids}')"

    if bool_true "$DRY_RUN"; then
      log "DRYRUN | Would start EpisodeSearch for $ids"
    elif api_post "command" "$body" >/dev/null 2>&1; then
      log "SEARCH | Sonarr EpisodeSearch started for $ids"
    else
      log "ERROR | Sonarr EpisodeSearch failed for $ids"
    fi
  else
    local movie_id
    movie_id="$(jq -r '.movieId // empty' <<<"$item")"
    if [[ -z "$movie_id" ]]; then
      log "WARNING | No Radarr movie ID available for replacement search."
      return
    fi

    local body
    body="$(jq -cn --argjson id "$movie_id" '{name:"MoviesSearch",movieIds:[$id]}')"

    if bool_true "$DRY_RUN"; then
      log "DRYRUN | Would start MoviesSearch for movie ID $movie_id"
    elif api_post "command" "$body" >/dev/null 2>&1; then
      log "SEARCH | Radarr MoviesSearch started for movie ID $movie_id"
    else
      log "ERROR | Radarr MoviesSearch failed for movie ID $movie_id"
    fi
  fi
}

reject_queue_item() {
  local item="$1"
  local reason="$2"
  local queue_id title remove blocklist query

  queue_id="$(jq -r '.id // empty' <<<"$item")"
  title="$(jq -r '.title // "Unknown"' <<<"$item")"

  if [[ -z "$queue_id" ]]; then
    log "ERROR | Cannot reject '$title': queue ID missing."
    return
  fi

  remove="false"
  blocklist="false"
  bool_true "$REMOVE_FROM_CLIENT" && remove="true"
  bool_true "$BLOCKLIST" && blocklist="true"

  log "REJECT | $reason | $title | queue=$queue_id"

  if bool_true "$DRY_RUN"; then
    log "DRYRUN | Would remove=$remove blocklist=$blocklist and search replacement."
    search_replacement "$item"
    return
  fi

  query="queue/$queue_id?removeFromClient=$remove&blocklist=$blocklist&skipRedownload=true&changeCategory=false"

  if api_delete "$query" >/dev/null 2>&1; then
    log "ACTION | Removed/blocklisted queue item $queue_id"
    search_replacement "$item"
  else
    log "ERROR | Failed to remove/blocklist queue item $queue_id"
  fi
}

inspect_item() {
  local item="$1"
  local title status state output_path video_info video_bytes video_path video_mib reason min_bytes

  title="$(jq -r '.title // "Unknown"' <<<"$item")"
  status="$(jq -r '.status // ""' <<<"$item")"
  state="$(jq -r '.trackedDownloadState // ""' <<<"$item")"
  output_path="$(jq -r '.outputPath // ""' <<<"$item")"
  output_path="$(map_output_path "$output_path")"

  case "$state" in
    importPending|importBlocked|importFailed) ;;
    *)
      [[ "$status" == "completed" ]] || return 0
      ;;
  esac

  if [[ -z "$output_path" || "$output_path" == "null" ]]; then
    return 0
  fi

  if [[ ! -e "$output_path" ]]; then
    log "WARNING | PATH_MISSING | $title | $output_path"
    if bool_true "$REJECT_MISSING_PATH"; then
      reject_queue_item "$item" "PATH_MISSING"
    fi
    return 0
  fi

  video_info="$(find_largest_video "$output_path" || true)"
  reason=""
  video_mib="0"

  if [[ -z "$video_info" ]]; then
    if bool_true "$CHECK_ARCHIVES" && has_archive_files "$output_path"; then
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
    min_bytes="$((MIN_VIDEO_SIZE_MIB * 1024 * 1024))"

    if bool_true "$CHECK_SAMPLE" && is_sample_file "$video_path"; then
      reason="SAMPLE_ONLY"
    elif (( video_bytes < min_bytes )); then
      reason="SMALL_VIDEO"
    elif ! video_readable "$video_path"; then
      reason="UNREADABLE_VIDEO"
    fi
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

  log "START | ArrGuard v$VERSION | app=$app_name | dry_run=$DRY_RUN"

  local queue
  queue="$(api_get "$(queue_endpoint)" 2>/dev/null || true)"
  if [[ -z "$queue" ]]; then
    log "ERROR | Could not read $app_name queue."
    exit 1
  fi

  while IFS= read -r item; do
    inspect_item "$item"
  done < <(jq -c '.records[]?' <<<"$queue")

  log "DONE | Queue scan complete."
}

main "$@"
