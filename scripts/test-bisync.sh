#!/usr/bin/env bash
set -euo pipefail

if ! command -v rclone >/dev/null 2>&1; then
  printf 'SKIP: rclone is not installed; bisync adapter is optional.\n'
  exit 0
fi

printf 'PhotoArchiveKit rclone-engine synthetic tests (not app-service Live Photo tests).\n'

help=$(rclone bisync --help 2>&1)
for flag in --backup-dir1 --backup-dir2 --check-access --conflict-resolve --recover --resync-mode --workdir; do
  if ! grep -Fq -- "$flag" <<<"$help"; then
    printf 'FAIL: installed rclone bisync does not support %s\n' "$flag" >&2
    exit 1
  fi
done

base=$(mktemp -d "${TMPDIR:-/tmp}/photoarchive-bisync-test.XXXXXX")
server_pid=""
cleanup() {
  if [[ -n "$server_pid" ]]; then
    kill "$server_pid" 2>/dev/null || true
    wait "$server_pid" 2>/dev/null || true
  fi
  rm -rf "$base"
}
trap cleanup EXIT

export RCLONE_CONFIG="$base/empty-rclone.conf"
: > "$RCLONE_CONFIG"

setup_case() {
  case_dir="$base/$1"
  path1="$case_dir/path1"
  path2="$case_dir/path2"
  work="$case_dir/work"
  backup1="$case_dir/backup1"
  backup2="$case_dir/backup2"
  filters="$case_dir/filters.txt"
  mkdir -p "$path1" "$path2" "$work" "$backup1" "$backup2"
  printf 'access\n' > "$path1/.photoarchive-bisync-access"
  cp -p "$path1/.photoarchive-bisync-access" "$path2/.photoarchive-bisync-access"
  printf '%s\n' \
    '- /.photoarchive-root' \
    '- /.photoarchive/**' \
    '- /.DS_Store' \
    '- /._*' > "$filters"
}

run_local() {
  rclone bisync "$path1" "$path2" \
    --workdir "$work" \
    --filters-file "$filters" \
    --check-access \
    --check-filename .photoarchive-bisync-access \
    --compare size,modtime,checksum \
    --slow-hash-sync-only \
    --conflict-resolve none \
    --conflict-loser num \
    --max-delete 50 \
    --recover \
    --backup-dir1 "$backup1" \
    --backup-dir2 "$backup2" \
    "$@"
}

seed_files() {
  for n in 1 2 3 4 5; do
    printf 'base-%s\n' "$n" > "$path1/base$n.txt"
  done
}

setup_case initial
printf 'left\n' > "$path1/left.txt"
printf 'right\n' > "$path2/right.txt"
run_local --resync-mode path1 >/dev/null
[[ -f "$path2/left.txt" && -f "$path1/right.txt" ]]
printf 'PASS: initial distinct content is merged.\n'

setup_case one-side
seed_files
run_local --resync-mode path1 >/dev/null
printf 'added\n' > "$path1/added.txt"
printf 'modified-longer\n' > "$path1/base1.txt"
rm "$path1/base2.txt"
run_local >/dev/null
[[ -f "$path2/added.txt" ]]
grep -q modified "$path2/base1.txt"
[[ ! -e "$path2/base2.txt" ]]
find "$backup2" -type f -name 'base2*' -print -quit | grep -q .
printf 'PASS: one-side add, modify and delete propagate with backup.\n'

setup_case rename
seed_files
printf 'move-me\n' > "$path1/old.txt"
run_local --resync-mode path1 >/dev/null
mkdir -p "$path1/album"
mv "$path1/old.txt" "$path1/album/new.txt"
run_local >/dev/null
[[ ! -e "$path2/old.txt" && -f "$path2/album/new.txt" ]]
printf 'PASS: rename and subfolder move propagate.\n'

setup_case conflict
seed_files
printf 'same\n' > "$path1/conflict.txt"
run_local --resync-mode path1 >/dev/null
printf 'LEFT-CHANGED-LONG\n' > "$path1/conflict.txt"
printf 'RIGHT-CHANGED-EVEN-LONGER\n' > "$path2/conflict.txt"
run_local >/dev/null
[[ $(find "$path1" -maxdepth 1 -type f -name 'conflict*' | wc -l | tr -d ' ') -ge 2 ]]
[[ $(find "$path2" -maxdepth 1 -type f -name 'conflict*' | wc -l | tr -d ' ') -ge 2 ]]
printf 'PASS: simultaneous modifications preserve both conflict versions.\n'

setup_case delete-modify
seed_files
printf 'original\n' > "$path1/target.txt"
run_local --resync-mode path1 >/dev/null
rm "$path1/target.txt"
printf 'remote-modified-longer\n' > "$path2/target.txt"
run_local >/dev/null
grep -R -q 'remote-modified' "$path1" "$path2" "$backup1" "$backup2"
printf 'PASS: delete-vs-modify preserves modified content.\n'

setup_case divergent-rename
seed_files
printf 'rename\n' > "$path1/original.txt"
run_local --resync-mode path1 >/dev/null
mv "$path1/original.txt" "$path1/left-name.txt"
mv "$path2/original.txt" "$path2/right-name.txt"
run_local >/dev/null
[[ -f "$path1/left-name.txt" && -f "$path1/right-name.txt" ]]
[[ -f "$path2/left-name.txt" && -f "$path2/right-name.txt" ]]
printf 'PASS: divergent renames preserve both names.\n'

setup_case missing
seed_files
run_local --resync-mode path1 >/dev/null
mv "$path1" "$case_dir/path1-offline"
set +e
run_local >/dev/null 2>"$case_dir/missing.err"
missing_rc=$?
set -e
[[ $missing_rc -ne 0 && -f "$path2/base1.txt" ]]
printf 'PASS: missing local root aborts instead of becoming deletion evidence.\n'

setup_case lock
seed_files
run_local --resync-mode path1 >/dev/null
mkdir -p "$path1/bulk"
for n in $(seq 1 12000); do
  printf 'x%05d\n' "$n" > "$path1/bulk/f$n.txt"
done
run_local --transfers 1 --checkers 1 >/dev/null 2>"$case_dir/first.err" &
first_pid=$!
lock_file=""
for _ in $(seq 1 100); do
  lock_file=$(find "$work" -type f -name '*.lck' -print -quit 2>/dev/null || true)
  [[ -n "$lock_file" ]] && break
  sleep 0.05
done
[[ -n "$lock_file" ]]
set +e
run_local --transfers 1 --checkers 1 >/dev/null 2>"$case_dir/second.err"
second_rc=$?
set -e
[[ $second_rc -ne 0 ]]
grep -q 'prior lock file found' "$case_dir/second.err"
wait "$first_pid"
printf 'PASS: overlapping bisync is rejected by its lock.\n'

setup_case backup
seed_files
printf 'recover-me\n' > "$path1/recover.txt"
run_local --resync-mode path1 >/dev/null
rm "$path1/recover.txt"
run_local >/dev/null
[[ ! -e "$path2/recover.txt" ]]
backup_file=$(find "$backup2" -type f -name 'recover*' -print -quit)
[[ -n "$backup_file" ]]
grep -q recover-me "$backup_file"
printf 'PASS: propagated deletion remains recoverable from backup-dir.\n'

setup_case live-photo-file-level
seed_files
printf 'still-v1\n' > "$path1/IMG_0001.HEIC"
printf 'motion-v1\n' > "$path1/IMG_0001.MOV"
run_local --resync-mode path1 >/dev/null
printf 'still-v2-longer\n' > "$path1/IMG_0001.HEIC"
run_local --dry-run --use-json-log --log-level NOTICE >/dev/null 2>"$case_dir/live.jsonl"
grep -q '"object":"IMG_0001.HEIC"' "$case_dir/live.jsonl"
run_local >/dev/null
grep -q still-v2 "$path2/IMG_0001.HEIC"
grep -q motion-v1 "$path2/IMG_0001.MOV"
printf 'PASS: rclone is file-level; fake .HEIC/.MOV names show one-file mutation only (this does NOT test app Live Photo metadata blocking).\n'

# A hard transfer cutoff is intentionally not auto-resynced. It must surface as
# recovery-required so the product never uses --resync as a generic retry.
webdav_dir="$base/hard-interrupt"
local_dir="$webdav_dir/local"
serve_dir="$webdav_dir/serve"
remote_dir="$serve_dir/camera"
webdav_work="$webdav_dir/work"
webdav_backup="$webdav_dir/backup-local"
mkdir -p "$local_dir" "$remote_dir" "$webdav_work" "$webdav_backup"
port=$(python3 - <<'PY'
import socket
s = socket.socket()
s.bind(("127.0.0.1", 0))
print(s.getsockname()[1])
s.close()
PY
)
cat > "$webdav_dir/rclone.conf" <<EOF
[synthetic-webdav]
type = webdav
url = http://127.0.0.1:$port/
vendor = other
EOF
export RCLONE_CONFIG="$webdav_dir/rclone.conf"
rclone serve webdav "$serve_dir" --addr "127.0.0.1:$port" >"$webdav_dir/server.out" 2>"$webdav_dir/server.err" &
server_pid=$!
ready=0
for _ in $(seq 1 100); do
  if rclone lsd synthetic-webdav: >/dev/null 2>&1; then
    ready=1
    break
  fi
  sleep 0.05
done
[[ $ready -eq 1 ]]
printf access > "$local_dir/.photoarchive-bisync-access"
cp -p "$local_dir/.photoarchive-bisync-access" "$remote_dir/.photoarchive-bisync-access"
for n in 1 2 3 4; do printf 'base-%s\n' "$n" > "$local_dir/base$n.txt"; done
run_webdav() {
  rclone bisync "$local_dir" synthetic-webdav:camera \
    --workdir "$webdav_work" \
    --check-access \
    --check-filename .photoarchive-bisync-access \
    --compare size,modtime \
    --conflict-resolve none \
    --max-delete 50 \
    --recover \
    --backup-dir1 "$webdav_backup" \
    --backup-dir2 synthetic-webdav:backup \
    "$@"
}
run_webdav --resync-mode path1 >/dev/null
dd if=/dev/urandom of="$local_dir/partial.bin" bs=1048576 count=1 status=none
set +e
run_webdav --bwlimit 64k --max-duration 1s --cutoff-mode hard >/dev/null 2>"$webdav_dir/limited.err"
limited_rc=$?
run_webdav >/dev/null 2>"$webdav_dir/recover.err"
recover_rc=$?
set -e
[[ $limited_rc -ne 0 && $recover_rc -ne 0 ]]
grep -q 'resync to recover' "$webdav_dir/recover.err"
printf 'PASS: hard interruption becomes recovery-required; it is not auto-resynced.\n'

printf 'PhotoArchiveKit rclone bisync synthetic tests passed.\n'
