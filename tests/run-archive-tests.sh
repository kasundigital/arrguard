#!/usr/bin/env bash
# Archive test + extract (ARCHIVE_ACTION="extract") integration tests.
# Needs 7z (7zip / p7zip-full) for real 7z/zip archives. RAR files cannot be
# created without the non-free `rar` tool, so RAR handling is exercised with a
# small `unrar` stub that mimics the real exit codes (0 ok, 11 password, 3 corrupt).
#
# Usage: bash tests/run-archive-tests.sh
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/../arrguard.sh"
PORT=18990
fails=0
PID=""

if ! command -v 7z >/dev/null 2>&1; then
  echo "SKIP | 7z not installed"
  exit 0
fi

T="$(mktemp -d)"
D="$T/dl"
cleanup() { [[ -n "$PID" ]] && kill "$PID" 2>/dev/null; rm -rf -- "$T"; }
trap cleanup EXIT

z() { 7z a -bso0 -bsp0 "$@" >/dev/null; }

# ---- fixtures -------------------------------------------------------------
mkdir -p "$T/src" "$D"
truncate -s 45M "$T/src/Show.S01E01.mkv"
truncate -s 1M  "$T/src/setup.exe"

mkdir -p "$D/ok7z" "$D/psw7z" "$D/hpsw7z" "$D/exe7z" "$D/okzip" "$D/rarok" "$D/rarpsw" "$D/rarparts" "$D/dryrun"
z "$D/ok7z/x9Fq2.7z" "$T/src/Show.S01E01.mkv"
z -psecret "$D/psw7z/a.7z" "$T/src/Show.S01E01.mkv"
z -psecret -mhe=on "$D/hpsw7z/a.7z" "$T/src/Show.S01E01.mkv"
z "$D/exe7z/a.7z" "$T/src/setup.exe"
z "$D/okzip/a.zip" "$T/src/Show.S01E01.mkv"
truncate -s 10M "$D/rarok/abc.part1.rar" "$D/rarok/abc.part2.rar"
truncate -s 10M "$D/rarpsw/psw.part1.rar" "$D/rarpsw/psw.part2.rar"
truncate -s 10M "$D/rarparts/abc.part01.rar" "$D/rarparts/abc.part02.rar" "$D/rarparts/abc.part03.rar"
z "$D/dryrun/a.7z" "$T/src/Show.S01E01.mkv"
find "$D" -exec touch -d '2 hours ago' {} +

# unrar stub: lists one mkv, fails test for names containing "psw",
# "extracts" a 45 MiB mkv. Logs every call.
mkdir -p "$T/bin"
cat >"$T/bin/unrar" <<'EOF'
#!/usr/bin/env bash
echo "unrar $*" >>"${UNRAR_LOG:?}"
cmd="$1"; shift
file=""; dest=""
for a in "$@"; do case "$a" in -*) ;; *) if [[ -z "$file" ]]; then file="$a"; else dest="$a"; fi ;; esac; done
case "$cmd" in
  lb) echo "Show.S01E01.mkv" ;;
  l)  printf '%s\n' "----" "   47185920   1" ;;
  t)  [[ "$file" == *psw* ]] && exit 11; exit 0 ;;
  x)  truncate -s 45M "${dest%/}/Show.S01E01.mkv" ;;
esac
EOF
chmod +x "$T/bin/unrar"

q() { printf '{"id":%s,"title":"item%s","status":"completed","trackedDownloadState":"importPending","outputPath":"%s","downloadId":"dl%s","seriesId":1,"episodeId":%s}' "$1" "$1" "$2" "$1" "$1"; }
{
  echo '['
  q 1 "$D/ok7z"; echo ,
  q 2 "$D/psw7z"; echo ,
  q 3 "$D/hpsw7z"; echo ,
  q 4 "$D/exe7z"; echo ,
  q 5 "$D/okzip"; echo ,
  q 6 "$D/rarok"; echo ,
  q 7 "$D/rarpsw"; echo ,
  q 8 "$D/rarparts"
  echo ']'
} >"$T/queue.json"
echo "[$(q 9 "$D/dryrun")]" >"$T/queue-dry.json"

run() { # queue dry_run
  [[ -n "$PID" ]] && kill "$PID" 2>/dev/null && wait "$PID" 2>/dev/null
  python3 "$HERE/mock_arr.py" "$1" "$T/api.log" "$PORT" &
  PID=$!
  sleep 1
  cat >"$T/test.conf" <<EOF
APP="sonarr"
SONARR_URL="http://127.0.0.1:$PORT"
SONARR_API_KEY="x"
DRY_RUN="$2"
SONARR_MIN_VIDEO_SIZE_MIB="40"
CHECK_VIDEO_STREAM="false"
ARCHIVE_ACTION="extract"
EXTRACT_MIN_FREE_MIB="0"
LOG_FILE="$T/arrguard.log"
LOCK_FILE="$T/arrguard.lock"
EOF
  : >"$T/api.log"; : >"$T/arrguard.log"; : >"$T/unrar.log"
  PATH="$T/bin:$PATH" UNRAR_LOG="$T/unrar.log" ARRGUARD_CONFIG="$T/test.conf" bash "$SCRIPT" >/dev/null 2>&1
}

deleted() { grep -oE 'queue/[0-9]+' "$T/api.log" | cut -d/ -f2 | sort -n | tr '\n' ' ' | sed 's/ $//'; }
reason() { grep -E "REJECT \| [A-Z_]+ \| item$1 " "$T/arrguard.log" | awk -F' \\| ' '{print $3}'; }
check() { if [[ "$2" == "$3" ]]; then echo "PASS | $1"; else echo "FAIL | $1 | expected [$2] got [$3]"; fails=$((fails + 1)); fi; }

# ---- tests ----------------------------------------------------------------
run "$T/queue.json" false
check "only broken/junk archives removed" "2 3 4 7" "$(deleted)"
check "7z intact -> extracted" 1 "$(grep -c 'EXTRACTED | .* | item1$' "$T/arrguard.log")"
check "7z extracted file in place" 47185920 "$(stat -c %s "$D/ok7z/Show.S01E01.mkv" 2>/dev/null)"
check "zip intact -> extracted" 1 "$(grep -c 'EXTRACTED | .* | item5$' "$T/arrguard.log")"
check "no temp folder left" 0 "$(find "$D" -name .arrguard-extract | wc -l)"
check "7z password -> rejected" ARCHIVE_PASSWORD_OR_CORRUPT "$(reason 2)"
check "7z encrypted headers -> rejected" ARCHIVE_PASSWORD_OR_CORRUPT "$(reason 3)"
check "archive with .exe only -> rejected" ARCHIVE_NO_VIDEO_INSIDE "$(reason 4)"
check "rar intact -> extracted" 47185920 "$(stat -c %s "$D/rarok/Show.S01E01.mkv" 2>/dev/null)"
check "rar password -> ARCHIVE_PASSWORD" ARCHIVE_PASSWORD "$(reason 7)"
check "multi-part rar: only part01 opened" 0 "$(grep -cE 'part0[23]\.rar' "$T/unrar.log")"
check "extract into hidden temp dir" 2 "$(grep -c '^unrar x .*/\.arrguard-extract/$' "$T/unrar.log")"

# Second live run: extracted files are fresh -> WAIT, nothing removed.
run "$T/queue.json" false
check "freshly extracted downloads wait" "" "$(deleted | tr ' ' '\n' | grep -vxE '2|3|4|7' | tr '\n' ' ' | sed 's/ $//')"

run "$T/queue-dry.json" true
check "dry run tests but does not extract" 1 "$(grep -c 'DRYRUN | Archive OK; would extract' "$T/arrguard.log")"
check "dry run left archive untouched" 0 "$(find "$D/dryrun" -name '*.mkv' | wc -l)"

sed -i 's/^EXTRACT_MIN_FREE_MIB=.*/EXTRACT_MIN_FREE_MIB="999999999"/' "$T/test.conf"
: >"$T/arrguard.log"
ARRGUARD_CONFIG="$T/test.conf" bash "$SCRIPT" >/dev/null 2>&1
check "not enough disk space -> wait" 1 "$(grep -c 'WAIT | Not enough free space' "$T/arrguard.log")"

echo
if (( fails )); then echo "$fails test(s) failed"; exit 1; fi
echo "All archive tests passed"
