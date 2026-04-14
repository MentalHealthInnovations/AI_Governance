#!/usr/bin/env bash
set -euo pipefail

payload="$(cat)"
cmd="$(printf '%s' "$payload" | jq -r '.tool_input.command // empty')"

if [[ -z "$cmd" ]]; then
  exit 0
fi

separators=$(printf '%s' "$cmd" | grep -oE '(\&\&|;|\|\|)' | wc -l | tr -d ' ')
if [[ "${separators:-0}" -gt 20 ]]; then
  printf '{"decision":"deny","reason":"Command chaining exceeds policy threshold"}\n'
  exit 0
fi

if printf '%s' "$cmd" | grep -Eqi '(\||;|&&).*(curl|wget|nc|netcat|ncat|socat)'; then
  printf '{"decision":"deny","reason":"Network tool usage blocked by policy"}\n'
  exit 0
fi

if printf '%s' "$cmd" | grep -Eqi '\|\s*(bash|sh|zsh|fish)\b'; then
  printf '{"decision":"deny","reason":"Pipe to shell blocked by policy"}\n'
  exit 0
fi

if printf '%s' "$cmd" | grep -Eqi 'base64\s+(-d|--decode).*(\||;|&&).*(bash|sh|zsh|fish)'; then
  printf '{"decision":"deny","reason":"Decode-and-execute pattern blocked"}\n'
  exit 0
fi

printf '{"decision":"allow"}\n'
