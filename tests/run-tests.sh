#!/usr/bin/env bash
# Integration tests: runs arrguard.sh against a mock Sonarr/Radarr API with
# fixture download folders (sparse files, no real disk use) and asserts which
# queue items get removed.
#
# Usage: bash tests/run-tests.sh
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/../arrguard.sh"
T="$(mktemp -d)"
D="$T/dl"
PORT=18989
fails=0
PID=""

cleanup() { [[ -n "$PID" ]] && kill "$PID" 2>/dev/null; rm -rf -- "$T"; }
trap cleanup EXIT
[[ -n "${KEEP:-}" ]] && trap - EXIT

old() { touch -d '2 hours ago' "$@"; }
mkfile() { mkdir -p "$(dirname "$2")"; truncate -s "$1" "$2"; old "$2"; }

# ---- fixtures -------------------------------------------------------------
mkfile 900M "$D/good/Movie.2024.1080p.mkv"
mkfile 60M  "$D/cartoon/Show.S01E01.11min.480p.mkv"
mkfile 10M  "$D/tiny/Show.S01E02.mkv"
mkfile 700M "$D/rars/release.rar"; mkfile 50M "$D/rars/release.r00"
mkfile 20M  "$D/extracting/release.mkv"; mkfile 700M "$D/extracting/release.rar"
mkfile 2M   "$D/importing/release.nfo"
mkfile 5M   "$D/unknown/Some.Ebook.epub"
mkfile 400M "$D/pack/S01E01.mkv"; mkfile 400M "$D/pack/S01E02.mkv"
mkfile 1M   "$D/packbad/readme.txt"
mkfile 30M  "$D/sample/Sample/x-sample.mkv"
mkfile 2M   "$D/nfo-only/release.nfo"
mkfile 900M "/$T/host/mapped/Movie.mkv"
mkfile 900M "$D/Sample.Show.Collection/Movie.2024.mkv"      # 'sample' only in parent dir
old "$D"/* "$D"/*/* "$T/host" "$T/host/mapped"
mkdir -p "$D/fresh"; truncate -s 1M "$D/fresh/release.nfo"   # modified just now

q() { # id state outputPath [extra-json]
  printf '{"id":%s,"title":"item%s","status":"completed","trackedDownloadState":"%s","outputPath":"%s","downloadId":"dl%s","seriesId":1,"movieId":1,"episodeId":%s%s}\n' \
    "$1" "$1" "$2" "$3" "${5:-$1}" "$1" "${4:-}"
}

{
  echo '['
  q 1  importBlocked "$D/good";            echo ,
  q 2  importPending "$D/cartoon";         echo ,
  q 3  importPending "$D/tiny";            echo ,
  q 4  importPending "$D/rars";            echo ,
  q 5  importPending "$D/extracting";      echo ,
  q 6  importing     "$D/importing";       echo ,
  q 7  importBlocked "$D/unknown" ',"seriesId":null,"movieId":null'; echo ,
  q 8  importPending "$D/packbad" "" pack; echo ,
  q 9  importPending "$D/packbad" "" pack; echo ,
  q 10 importPending "$D/sample";          echo ,
  q 11 importPending "$D/nfo-only";        echo ,
  q 12 importPending "$D/fresh";           echo ,
  q 13 imported      "$D/nfo-only";        echo ,
  q 14 downloading   "$D/nfo-only";        echo ,
  q 15 importPending "/container/mapped";  echo ,
  q 16 importPending "$D/Sample.Show.Collection"
  echo ']'
} >"$T/queue.json"

: >"$T/api.log"
python3 "$HERE/mock_arr.py" "$T/queue.json" "$T/api.log" "$PORT" &
PID=$!
sleep 1

run() { # app dry_run [env...]
  local app="$1" dry="$2"; shift 2
  cat >"$T/test.conf" <<EOF
APP="$app"
SONARR_URL="http://127.0.0.1:$PORT"
SONARR_API_KEY="x"
RADARR_URL="http://127.0.0.1:$PORT"
RADARR_API_KEY="x"
DRY_RUN="$dry"
SONARR_MIN_VIDEO_SIZE_MIB="40"
CHECK_VIDEO_STREAM="false"
PATH_MAPPINGS="/container/=$T/host/"
LOG_FILE="$T/arrguard.log"
LOCK_FILE="$T/arrguard.lock"
EOF
  : >"$T/api.log"; : >"$T/arrguard.log"
  env "$@" ARRGUARD_CONFIG="$T/test.conf" bash "$SCRIPT" >/dev/null 2>&1
  echo $?
}

deleted() { grep -oE 'queue/[0-9]+' "$T/api.log" | cut -d/ -f2 | sort -n | tr '\n' ' ' | sed 's/ $//'; }

check() { # name expected actual
  if [[ "$2" == "$3" ]]; then echo "PASS | $1"; else echo "FAIL | $1 | expected [$2] got [$3]"; fails=$((fails + 1)); fi
}

# ---- tests ----------------------------------------------------------------
rc="$(run sonarr false)"
check "live run exits 0" 0 "$rc"
# 3=tiny 8=bad pack (once) 10=sample 11=no video
check "only genuinely bad items removed" "3 8 10 11" "$(deleted)"
check "search again uses Sonarr redownload" 1 "$(grep -c 'queue/3?removeFromClient=true&blocklist=true&skipRedownload=false' "$T/api.log")"
check "no POSTs (no hand-rolled search)" 0 "$(grep -c '^POST' "$T/api.log")"
check "fresh download waits" 1 "$(grep -c 'WAIT | Files changed' "$T/arrguard.log")"
check "archives with no/small video wait" 2 "$(grep -c 'WAIT | .*archives present' "$T/arrguard.log")"
check "path mapping with trailing slash" 1 "$(grep -c 'GOOD | item15' "$T/arrguard.log")"
check "parent dir named Sample is not a sample" 1 "$(grep -c 'GOOD | item16' "$T/arrguard.log")"

run sonarr true >/dev/null
check "dry run deletes nothing" "" "$(deleted)"

run sonarr ture >/dev/null
check "typo in DRY_RUN stays dry" "" "$(deleted)"

run sonarr false sonarr_eventtype=Test >/dev/null
check "Connect Test event does nothing" "" "$(deleted)"

cat >>"$T/test.conf" <<'EOF'
ARCHIVE_ACTION="reject"
EOF
: >"$T/api.log"
ARRGUARD_CONFIG="$T/test.conf" bash "$SCRIPT" >/dev/null 2>&1
check "ARCHIVE_ACTION=reject rejects archive-only" "3 4 5 8 10 11" "$(deleted)"

run radarr false >/dev/null
# Radarr uses the global 100 MiB minimum, so the 60 MiB 'cartoon' is rejected too.
check "radarr uses its own minimum" "2 3 8 10 11" "$(deleted)"

echo
if (( fails )); then echo "$fails test(s) failed"; exit 1; fi
echo "All tests passed"
