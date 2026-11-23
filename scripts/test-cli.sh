#!/usr/bin/env bash
set -euo pipefail

cli="$(swift build --show-bin-path)/photoarchive"
fixture="$(mktemp -d)"
trap 'rm -rf "$fixture"' EXIT
root="$fixture/synthetic-private-folder"
catalog="$fixture/catalog.sqlite"
mkdir "$root" "$root/existing-review"

require_field() {
  local key="$1" expected="$2" actual
  actual=$(plutil -extract "$key" raw -o - -)
  if [[ "$actual" != "$expected" ]]; then
    printf 'Expected %s=%s, got %s\n' "$key" "$expected" "$actual" >&2
    exit 1
  fi
}

require_no_private_path() {
  if grep -Fq 'synthetic-private-folder' "$@"; then
    printf 'Agent output exposed the synthetic private path\n' >&2
    exit 1
  fi
}

require_failure() {
  local exit_code=0
  "$cli" "$@" > "$fixture/stdout" 2> "$fixture/stderr" || exit_code=$?
  if [[ "$exit_code" != 1 || -s "$fixture/stdout" || ! -s "$fixture/stderr" ]]; then
    printf 'Expected a CLI error on stderr with exit status 1\n' >&2
    exit 1
  fi
}

"$cli" --help > "$fixture/help"
grep -F 'photoarchive root --help' "$fixture/help" >/dev/null
"$cli" root --help > "$fixture/root-help"
for action in list add role enable disable remove inspect init; do
  "$cli" root "$action" --help | cmp -s "$fixture/root-help" -
done

"$cli" root inspect --json "$root" | require_field status absent
"$cli" root init --agent-json "$root" | require_field status wouldCreate
test ! -e "$root/.photoarchive-root"
"$cli" root init --apply --agent-json "$root" | require_field status created
"$cli" root init --apply --json "$root" | require_field status present
"$cli" root inspect --agent-json "$root" | require_field schemaVersion 1

"$cli" root add --agent-json --catalog "$catalog" "$root" > "$fixture/add.json"
require_no_private_path "$fixture/add.json"
root_id=$(plutil -extract rootID raw -o - "$fixture/add.json")
"$cli" root list --agent-json --catalog "$catalog" | require_field 0.rootID "$root_id"
"$cli" root disable --agent-json --catalog "$catalog" "$root_id" | require_field state inactive
"$cli" root enable --json --catalog "$catalog" "$root_id" | require_field state active
"$cli" root role --agent-json --catalog "$catalog" "$root_id" archive | require_field usageRole archive

require_failure duplicate-review --refresh --no-progress --catalog "$catalog" \
  --archive "$root" --output "$root/existing-review" --agent-json
grep -Fxq 'error: Duplicate review output already exists.' "$fixture/stderr"
require_no_private_path "$fixture/stdout" "$fixture/stderr"
require_failure duplicate-review --refresh --no-progress --catalog "$catalog" \
  --archive "$root" --output "$root/existing-review" --json
grep -Fq 'synthetic-private-folder' "$fixture/stderr"

require_failure root list --invalid="$root" --agent-json
require_no_private_path "$fixture/stdout" "$fixture/stderr"
require_failure root add --catalog "$catalog" "$root/missing" --agent-json
require_no_private_path "$fixture/stdout" "$fixture/stderr"
mkdir "$root/malformed-marker"
printf '%s\n' 'invalid marker' > "$root/malformed-marker/.photoarchive-root"
require_failure root inspect "$root/malformed-marker" --agent-json
require_no_private_path "$fixture/stdout" "$fixture/stderr"
require_failure root disable --json --agent-json --catalog "$catalog" "$root_id"
"$cli" root list --agent-json --catalog "$catalog" | require_field 0.state active
"$cli" root remove --agent-json --catalog "$catalog" "$root_id" | require_field mediaFilesModified false

printf 'CLI privacy and root command checks passed.\n'
