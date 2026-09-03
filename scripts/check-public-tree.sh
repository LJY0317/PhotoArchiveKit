#!/usr/bin/env bash
set -euo pipefail

failure=0

while IFS= read -r path; do
  lower=$(printf '%s' "$path" | tr '[:upper:]' '[:lower:]')
  case "$lower" in
    *.heic|*.heif|*.jpg|*.jpeg|*.png|*.gif|*.tif|*.tiff|*.dng|*.mov|*.mp4|*.m4v|*.aae|*.xmp)
      printf 'forbidden tracked media or sidecar: %s\n' "$path" >&2
      failure=1
      ;;
    *.sqlite|*.sqlite3|*.sqlite-shm|*.sqlite-wal|*.sqlite3-shm|*.sqlite3-wal|*.db|*.db-shm|*.db-wal|*.photoslibrary)
      printf 'forbidden tracked runtime data: %s\n' "$path" >&2
      failure=1
      ;;
    *'photo inbox/'*|*'photo archive/'*|*'google takeout/'*|takeout/*|*'/takeout/'*|secrets/*|credentials/*|tokens/*)
      printf 'forbidden tracked private path: %s\n' "$path" >&2
      failure=1
      ;;
  esac
done < <(git ls-files)

if git grep -n -I -E '(/Users/|LJY LAN Drop|leejaeyup)' -- . ':(exclude)scripts/check-public-tree.sh'; then
  printf 'personal local path or name found in tracked content\n' >&2
  failure=1
fi

if git grep -n -I -E '(AIza[0-9A-Za-z_-]{20,}|gh[pousr]_[0-9A-Za-z]{20,}|BEGIN [A-Z ]*PRIVATE KEY)' -- . ':(exclude)scripts/check-public-tree.sh'; then
  printf 'possible credential material found in tracked content\n' >&2
  failure=1
fi

if [ "$failure" -ne 0 ]; then
  exit 1
fi

printf 'Public tree check passed.\n'
