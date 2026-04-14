#!/usr/bin/env bash
set -euo pipefail

payload="$(cat)"
path="$(printf '%s' "$payload" | jq -r '.tool_input.file_path // empty')"

case "$path" in
  ./.env|./.env.*|*/.env|*/.env.*|./secrets/*)
    mkdir -p ./.claude/tmp
    redacted="./.claude/tmp/$(basename "$path").redacted"

    awk -F= '
      /^[[:space:]]*#/ { print; next }
      NF >= 2 { print $1"=<REDACTED>"; next }
      { print }
    ' "$path" > "$redacted"

    printf '{"decision":"deny","reason":"Direct secret read denied. Use redacted copy: %s"}\n' "$redacted"
    exit 0
    ;;
esac

printf '{"decision":"allow"}\n'
