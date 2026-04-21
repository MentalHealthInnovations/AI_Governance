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

# Array of allowed command patterns (regex format)
# Safe git commands: read-only, safe modifications, but blocks dangerous operations
allowed_patterns=(
  # Git read-only commands
  "^git status"
  "^git diff"
  "^git log"
  "^git show"
  "^git blame"
  "^git grep"
  "^git remote"
  
  # Git safe modifications
  "^git add"
  "^git commit(?!.*--no-verify)"
  "^git tag"
  "^git stash"
  "^git config"
  
  # Git fetch/pull/checkout
  "^git fetch"
  "^git pull(?!.*--force)(?!.*\s-f\b)"
  "^git checkout"
  
  # Git branch/merge (safe operations)
  "^git branch(?!.*-D)(?!.*--force-delete)"
  "^git merge(?!.*--no-verify)(?!.*\s--no-ff)"
  "^git rebase(?!.*--force)(?!.*\s-f\b)"
  
  # Git push (without --force)
  "^git push(?!.*--force)(?!.*\s-f\b)"
  
  # Git file operations
  "^git rm"
  "^git mv"
  "^git reset(?!.*--hard)"
  "^git clean(?!.*-f)(?!.*-d)(?!.*-x)"
  
  # Other safe commands
  "^git clone"
  "^git help"
  
  # Non-git tools
  "^gh\s"
  "^npm\s"
  "^pnpm\s"
  "^yarn\s"
  "^pip\s"
  "^pip3\s"
  "^poetry\s"
  "^pytest\s"
  "^ruff\s"
  "^mypy\s"
  "^go\s"
  "^cargo\s"
  "^docker\s"
)

# Check if command matches any allowed regex pattern
for pattern in "${allowed_patterns[@]}"; do
  if printf '%s' "$cmd" | grep -Eqi "$pattern"; then
    printf '{"decision":"allow"}\n'
    exit 0
  fi
done

printf '{"decision":"deny","reason":"Command not in policy allowlist"}\n'
