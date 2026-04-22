#!/usr/bin/env bash
set -euo pipefail

logtofile() {
  echo "[$(date)] $1" >> /tmp/hook-debug.log
}

logtofile "hook fired"

payload="$(cat)"
cmd="$(printf '%s' "$payload" | jq -r '.tool_input.command // empty')"

logtofile "cmd extracted: $cmd"

if [[ -z "$cmd" ]]; then
  logtofile "no command found, exiting"
  exit 0
fi

separators=$(printf '%s' "$cmd" | grep -oE '(\&\&|;|\|\|)' | wc -l | tr -d ' ')
if [[ "${separators:-0}" -gt 5 ]]; then
  logtofile "DENY excessive chaining ($separators separators): $cmd"
  echo '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"Command chaining exceeds policy threshold"}}'
  exit 0
fi

if printf '%s' "$cmd" | grep -Eqi '(curl|wget|nc|netcat|ncat|socat)'; then
  logtofile "DENY network tool: $cmd"
  echo '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"Network tool usage blocked by policy"}}'
  exit 0
fi

if printf '%s' "$cmd" | grep -Eqi '(bash|sh|zsh|fish)'; then
  logtofile "DENY shell: $cmd"
  echo '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"Pipe to shell blocked by policy"}}'
  exit 0
fi

if printf '%s' "$cmd" | grep -Eqi 'base64\s+(-d|--decode)'; then
  logtofile "DENY base64 decode: $cmd"
  echo '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"Decode-and-execute pattern blocked"}}'
  exit 0
fi

# Array of allowed command patterns (regex format)
# Safe git commands: read-only, safe modifications, but blocks dangerous operations
allowed_patterns=(
  # basic commands
  "ls"
  "echo"
  "cat"
  "tr"
  "sed"
  "awk"

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
  
  # GitHub CLI
  "^gh\s+(issue|pr|repo|gist|secret|label|run|release)"
  
  # npm/pnpm/yarn - safe operations
  "^npm\s+(install|ci|run|test|lint|audit|list|search|view|info|outdated)"
  "^pnpm\s+(install|run|test|lint|audit|list|search|view|outdated)"
  "^yarn\s+(install|add|run|test|lint|audit|list|info)"
  
  # Python package managers
  "^pip\s+(install|list|show|search|check)"
  "^pip3\s+(install|list|show|search|check)"
  "^poetry\s+(install|add|run|show|search|lock|lock.*--no-update|update)"
  
  # Python testing and linting
  "^pytest"
  "^ruff\s+(check|format|format.*--check|lint)"
  "^mypy"
  
  # Docker - safe operations
  "^docker\s+(build|run|ps|logs|exec|pull|push|images|inspect)"
)

# Check if command matches any allowed regex pattern
for pattern in "${allowed_patterns[@]}"; do
  if printf '%s' "$cmd" | grep -Eqi "$pattern"; then
    logtofile "ALLOW pattern '$pattern' matched: $cmd"
    echo '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"allow"}}'
    exit 0
  fi
done

logtofile "DENY not in allowlist: $cmd"
echo '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"Command not in policy allowlist"}}'
