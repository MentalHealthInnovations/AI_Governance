#!/usr/bin/env bash
# PreToolUse hook for Bash commands. Enforces an allowlist policy: blocks network tools,
# pipe-to-shell patterns, base64 decode-and-execute, excessive command chaining, and
# any command not explicitly permitted. Outputs Claude Code hookSpecificOutput JSON.
set -u

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

separators=$(printf '%s' "$cmd" | grep -oE '(\&\&|;|\|\||\|)' | wc -l | tr -d ' ')
if [[ "${separators:-0}" -gt 2 ]]; then
  logtofile "DENY excessive chaining ($separators separators): $cmd"
  echo '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"Command chaining exceeds policy threshold"}}'
  exit 0
fi

# stripped_cmd removes content inside single- and double-quoted strings so that
# words like "sudo" or "exec" in a -m commit message don't trigger false positives.
# The full $cmd is still used where quoted values must be inspected (e.g. --exec="curl ...").
stripped_cmd="$(printf '%s' "$cmd" | sed "s/\"[^\"]*\"//g; s/'[^']*'//g")"

if printf '%s' "$stripped_cmd" | grep -Eqi '(^|\s)(sudo|su)(\s|$)'; then
  logtofile "DENY sudo/su: $cmd"
  echo '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"Privilege escalation (sudo/su) blocked by policy"}}'
  exit 0
fi

if printf '%s' "$cmd" | grep -Eqi '\b(curl|wget|nc|netcat|ncat|socat)\b'; then
  logtofile "DENY network tool: $cmd"
  echo '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"Network tool usage blocked by policy"}}'
  exit 0
fi

# Match shell/interpreter invocation as a command token, not as a substring.
# Anchors: start of string, after pipe (|), after semicolon, after &&/||, or after backtick.
# Catches: sh, bash, zsh, fish, dash, ksh, csh, tcsh, python, python3, perl, ruby, node,
#          nodejs, php, lua, exec. The \b word-boundary prevents matching branch names like
#          "fish-fix" or arguments that contain these strings.
if printf '%s' "$stripped_cmd" | grep -Eqi '(^|[|;&`$( ])(sh|bash|zsh|fish|dash|ksh|csh|tcsh|python3?|perl|ruby|node(js)?|php|lua|exec)\b'; then
  logtofile "DENY shell invocation: $cmd"
  echo '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"Shell or interpreter invocation blocked by policy"}}'
  exit 0
fi

if printf '%s' "$cmd" | grep -Eqi 'base64\s+(-d|--decode)'; then
  logtofile "DENY base64 decode: $cmd"
  echo '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"Decode-and-execute pattern blocked"}}'
  exit 0
fi

if printf '%s' "$cmd" | grep -Eqi '(^|\s)(--force|-D|--force-delete|--no-verify)\b'; then
  logtofile "DENY dangerous flag: $cmd"
  echo '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"Dangerous flag blocked by policy"}}'
  exit 0
fi

if printf '%s' "$cmd" | grep -Eqi '^git\s+.*\s(-f|--hard)\b'; then
  logtofile "DENY git -f flag: $cmd"
  echo '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"Dangerous flag blocked by policy"}}'
  exit 0
fi

# Array of allowed command patterns (regex format)
# Safe git commands: read-only, safe modifications, but blocks dangerous operations
allowed_patterns=(
  # basic commands - read-only/safe anywhere in pipeline
  "\bls\b"
  "\becho\b"
  "\bcat\b"
  "\btr\b"
  "\bsed\b"
  "\bawk\b"
  "\bgrep\b"
  "\bhead\b"
  "\btail\b"
  "\bwc\b"
  "\bsort\b"
  "\buniq\b"
  "\bcut\b"
  "\bpaste\b"
  "\bdiff\b"
  "\bdate\b"
  "\bpwd\b"
  "\bwhoami\b"
  "\buname\b"
  "\bwhich\b"
  "\btype\b"
  "\bjq\b"
  "\btee\b"
  "\bprintf\b"

  # basic commands - anchored as these modify filesystem/env
  "^find"
  "^mkdir"
  "^cp"
  "^mv"
  "^touch"
  "^env"
  "^export"

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
  "^git commit"
  "^git tag"
  "^git stash"
  "^git fetch"
  "^git pull"
  "^git checkout"
  "^git branch"
  "^git merge"
  "^git rebase"
  "^git push"
  "^git rm"
  "^git mv"
  "^git reset"
  "^git clone"
  "^git help"
  
  # GitHub CLI
  "^gh\s+(issue|pr|repo|gist|label|release)"
  
  # npm/pnpm/yarn - safe operations
  "^npm\s+(ci|test|lint|list|search|view|info|outdated)"
  "^pnpm\s+(test|lint|list|search|view|outdated)"
  "^yarn\s+(test|lint|audit|list|info)"
  
  # Python package managers
  "^pip\s+(list|show|search|check)"
  "^pip3\s+(list|show|search|check)"
  "^poetry\s+(show|search|lock|lock.*--no-update|update)"
  
  # Python testing and linting
  "^pytest"
  "^ruff\s+(check|format|format.*--check|lint)"
  "^mypy"
  
  # Docker - safe operations
  "^docker\s+(build|ps|logs|pull|images|inspect)"
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
