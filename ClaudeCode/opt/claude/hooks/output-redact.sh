#!/usr/bin/env bash
# PostToolUse hook — blocks tool output containing secrets before it reaches Claude.
#
# Registered for Bash, Read, and WebFetch. Scans tool_response for secret patterns.
# On detection: emits {"decision":"block",...} to stdout and exits 2.
#
# To add a new pattern:
#   Add one check_pattern call in the "Patterns" section with:
#     - NAME  : a short label logged for audit (e.g. "STRIPE_KEY")
#     - REGEX : a grep -E (POSIX ERE) expression matching the secret
#
# Limitations:
#   - grep -E is line-based: multi-line secrets (e.g. PEM blocks) only match if
#     they appear on a single line.
#   - No PCRE: \d, lookaheads, and (?i) inline flags are not available. Use
#     explicit character classes ([0-9]) and manual case alternation instead.

set -u

LOG="$HOME/.claude/debug/output-redact-hook.log"
log() { echo "[$(date)] $1" >> "$LOG"; }

log "hook fired (PostToolUse)"

payload="$(cat)"

# tool_response shape varies by tool:
#   Bash:     { stdout, stderr, exit_code }
#   Read:     nested object with content
#   WebFetch: { content, ... }
# `.. | strings` recurses into all nested objects and collects every string value.
scan_text="$(printf '%s' "$payload" | jq -r '
  .tool_response
  | if type == "string" then .
    elif type == "object" then (.. | strings)
    elif type == "array"  then (.[] | .. | strings)
    else ""
    end
' 2>/dev/null)"

if [[ -z "$scan_text" ]]; then
  log "nothing to scan, exiting"
  exit 0
fi

# ── Pattern engine ────────────────────────────────────────────────────────────

found=0
found_name=""

# check_pattern NAME REGEX
#
# Tests whether REGEX matches anywhere in $scan_text.
# Short-circuits after first hit; logs a 6-char sample for audit.
check_pattern() {
  local name="$1"
  local regex="$2"

  if [[ "$found" -eq 1 ]]; then return; fi

  if printf '%s' "$scan_text" | grep -qE "$regex"; then
    found=1
    found_name="$name"
    local sample
    sample="$(printf '%s' "$scan_text" | grep -oE "$regex" | head -1 | cut -c1-6)"
    log "DETECT $name sample='${sample}...'"
  fi
}

# ── Patterns ──────────────────────────────────────────────────────────────────
# More-specific patterns come first to avoid ambiguity in log messages.

# AWS access key IDs — 20-char strings starting with AKIA or ASIA
check_pattern "AWS_KEY_ID" \
  '(AKIA|ASIA)[A-Z0-9]{16}'

# AWS secret access key assignments (40-char value after the variable name)
check_pattern "AWS_SECRET" \
  '(aws_secret_access_key|secret_access_key)[ 	]*[=:][ 	]*[A-Za-z0-9/+]{40}'

# GitHub classic personal access tokens (ghp_, gho_, ghu_, ghs_, ghr_)
check_pattern "GITHUB_PAT" \
  'gh[pousr]_[A-Za-z0-9]{34,}'

# GitHub fine-grained PATs
check_pattern "GITHUB_FINE_PAT" \
  'github_pat_[A-Za-z0-9_]{82}'

# OpenAI / Anthropic / generic sk- API keys
check_pattern "SK_API_KEY" \
  'sk-[A-Za-z0-9_-]{20,}'

# Stripe live and test keys (sk_, pk_, rk_ prefixes)
check_pattern "STRIPE_KEY" \
  '(sk|pk|rk)_(live|test)_[A-Za-z0-9]{24,}'

# Slack bot / app / user tokens
check_pattern "SLACK_TOKEN" \
  'xox[baprs]-[A-Za-z0-9-]{10,}'

# JWTs — three base64url segments joined by dots
check_pattern "JWT" \
  'eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+'

# Authorization: Bearer / Token / Basic headers
check_pattern "AUTH_HEADER" \
  '[Aa]uthorization:[ 	]*(Bearer|Token|Basic)[ 	]+[A-Za-z0-9_.~+/=-]{8,}'

# Twilio API keys
check_pattern "TWILIO_KEY" \
  'SK[a-f0-9]{32}'

# SendGrid API keys
check_pattern "SENDGRID_KEY" \
  'SG\.[A-Za-z0-9_-]{22}\.[A-Za-z0-9_-]{43}'

# Database / broker connection strings with embedded credentials
check_pattern "CONNECTION_STRING" \
  '(mongodb(\+srv)?|postgres(ql)?|mysql|redis|amqp)://[^:@[:space:]]+:[^@[:space:]"'"'"']+@'

# Generic secret assignments in config files and env vars.
# Matches: PASSWORD=value, api_key: value, secret = "value", etc.
# Requires >=8-char value to avoid matching short innocuous strings.
check_pattern "KEY_ASSIGNMENT" \
  '([Pp][Aa][Ss][Ss][Ww][Oo][Rr][Dd]|[Pp][Aa][Ss][Ss][Ww][Dd]|[Aa][Pp][Ii][_-]?[Kk][Ee][Yy]|[Aa][Pp][Ii][_-]?[Ss][Ee][Cc][Rr][Ee][Tt]|[Aa][Uu][Tt][Hh][_-]?[Tt][Oo][Kk][Ee][Nn]|[Aa][Cc][Cc][Ee][Ss][Ss][_-]?[Tt][Oo][Kk][Ee][Nn]|[Cc][Ll][Ii][Ee][Nn][Tt][_-]?[Ss][Ee][Cc][Rr][Ee][Tt]|[Ss][Ee][Cc][Rr][Ee][Tt])[ 	]*[=:]["'"'"']?[A-Za-z0-9+/=_!@#$%^&*-]{8,}["'"'"']?'

# SSH public key base64 material (outside a PEM block)
check_pattern "SSH_KEY_MATERIAL" \
  'AAAA[A-Za-z0-9+/]{40,}={0,2}'

# PEM private key blocks (single-line only — grep is line-based)
check_pattern "PEM_BLOCK" \
  '-----BEGIN [A-Z ]+-----[A-Za-z0-9+/=]+-----END [A-Z ]+'

# ── Emit result ───────────────────────────────────────────────────────────────

if [[ "$found" -eq 0 ]]; then
  log "no sensitive values detected"
  exit 0
fi

log "secret detected in tool output (${found_name}), blocking"
printf '%s' '{"decision":"block","reason":"Tool output contains a potential secret or credential and has been suppressed."}'
exit 2
