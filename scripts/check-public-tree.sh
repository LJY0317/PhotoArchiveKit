#!/usr/bin/env bash
set -euo pipefail

failure=0
script_path="scripts/check-public-tree.sh"
file_list="$(mktemp)"
trap 'rm -f "$file_list"' EXIT

git ls-files --cached --others --exclude-standard > "$file_list"

report_failure() {
  printf '%s\n' "$1" >&2
  failure=1
}

while IFS= read -r path; do
  [ -n "$path" ] || continue
  lower=$(printf '%s' "$path" | tr '[:upper:]' '[:lower:]')
  base=$(basename "$lower")

  case "$lower" in
    *.heic|*.heif|*.jpg|*.jpeg|*.png|*.gif|*.tif|*.tiff|*.dng|*.arw|*.cr2|*.cr3|*.nef|*.raf|*.mov|*.mp4|*.m4v|*.3gp|*.3g2|*.aae|*.xmp)
      report_failure "forbidden tracked or public-candidate media/sidecar: $path"
      ;;
    *.sqlite|*.sqlite3|*.sqlite-shm|*.sqlite-wal|*.sqlite3-shm|*.sqlite3-wal|*.db|*.db-shm|*.db-wal|*.photoslibrary)
      report_failure "forbidden tracked or public-candidate runtime data: $path"
      ;;
    *.zip|*.tar|*.tgz|*.tar.gz|*.7z)
      report_failure "forbidden tracked or public-candidate export/archive file: $path"
      ;;
    *.pem|*.key|*.p12|*.pfx)
      report_failure "forbidden tracked or public-candidate credential file: $path"
      ;;
    *'photo inbox/'*|*'photo archive/'*|*'google takeout/'*|takeout/*|*'/takeout/'*|secrets/*|credentials/*|tokens/*|private-fixtures/*|fixtures/private/*)
      report_failure "forbidden tracked or public-candidate private path: $path"
      ;;
  esac

  case "$base" in
    *client_secret*|*credentials*.json|*oauth*.json|*tokens*.json|*access_token*|*refresh_token*)
      report_failure "forbidden tracked or public-candidate credential filename: $path"
      ;;
  esac
done < "$file_list"

while IFS= read -r path; do
  [ -f "$path" ] || continue
  [ "$path" = "$script_path" ] && continue
  grep -Iq . "$path" 2>/dev/null || continue

  if grep -nE '(/Users/|LJY LAN Drop|leejaeyup)' "$path" >/dev/null 2>&1; then
    report_failure "personal local path or name found in: $path"
  fi

  if grep -nE '(AIza[0-9A-Za-z_-]{20,}|gh[pousr]_[0-9A-Za-z]{20,}|BEGIN [A-Z ]*PRIVATE KEY|ya29\.[0-9A-Za-z_-]+|1//[0-9A-Za-z_-]{20,})' "$path" >/dev/null 2>&1; then
    report_failure "possible credential material found in: $path"
  fi
done < "$file_list"

if [ "$failure" -ne 0 ]; then
  exit 1
fi

printf 'Public tree check passed.\n'
