#!/usr/bin/env bash
# PostToolUse hook — redacts secrets from tool output before they reach Claude.
#
# Registered for Bash, Read, and WebFetch. Scans tool_response for secret patterns
# and replaces each match with [REDACTED] in-place, then returns the sanitised
# content via decision:block so Claude never sees the raw value.
#
# decision:block is the correct mechanism: it prevents the tool output from
# entering Claude's context window. The reason field carries the sanitised text
# that Claude sees instead. suppressOutput additionally hides raw values from
# the debug log.
#
# To add a new pattern:
#   Add one redact_pattern call in the "Patterns" section with:
#     - NAME  : a short label logged for audit (e.g. "STRIPE_KEY")
#     - REGEX : a Perl regex (PCRE) — (?i) flags, \s, lookaheads all available

set -u

LOG="$HOME/.claude/debug/output-redact.log"
log() { echo "[$(date)] [output-redact] $1" >> "$LOG"; }

payload="$(cat)"

# Pull raw output text. Field names differ by tool:
#   Bash:     .tool_response.stdout (primary output)
#   Read:     .tool_response.content (string or [{type,text}] array)
#   WebFetch: .tool_response.content (string)
raw_output="$(printf '%s' "$payload" | jq -r '
  if .tool_response.stdout? and (.tool_response.stdout | type) == "string" then
    .tool_response.stdout
  elif .tool_response.content? and (.tool_response.content | type) == "array" then
    [.tool_response.content[] | select(.type == "text") | .text] | join("\n")
  elif .tool_response.content? and (.tool_response.content | type) == "string" then
    .tool_response.content
  else
    ""
  end
')"

if [[ -z "$raw_output" ]]; then
  exit 0
fi

redacted="$raw_output"
found=0

# redact_pattern NAME REGEX
# Replaces all matches of REGEX with [REDACTED] using Perl (PCRE, multiline).
# Logs the pattern name and first 6 chars of the first match for audit.
# Never writes the full matched value to the log.
redact_pattern() {
  local name="$1" regex="$2"
  local before="$redacted"
  redacted="$(printf '%s' "$redacted" | perl -pe "s/$regex/[REDACTED]/g")"
  if [[ "$redacted" != "$before" ]]; then
    found=1
    local sample
    sample="$(printf '%s' "$before" | perl -ne "/$regex/ && do { my \$m = \$&; \$m = substr(\$m,0,6); print \$m; exit }")"
    log "REDACT $name sample='${sample}...'"
  fi
}

# ── Patterns ──────────────────────────────────────────────────────────────────
# More-specific patterns come first to avoid ambiguity in log messages.

# PEM private key blocks (multiline — Perl handles \r\n)
redact_pattern "PEM_BLOCK" \
  '-----BEGIN [A-Z ]+-----[A-Za-z0-9+\/=\r\n]+-----END [A-Z ]+-----'

# AWS access key IDs — 20-char strings starting with AKIA or ASIA
redact_pattern "AWS_KEY_ID" \
  '(AKIA|ASIA)[A-Z0-9]{16}'

# AWS secret access key assignments
redact_pattern "AWS_SECRET" \
  '(?i)(aws_secret_access_key|secret_access_key)\s*[=:]\s*[A-Za-z0-9\/+]{40}'

# GitHub classic personal access tokens (ghp_, gho_, ghu_, ghs_, ghr_)
redact_pattern "GITHUB_PAT" \
  'gh[pousr]_[A-Za-z0-9]{34,}'

# GitHub fine-grained PATs
redact_pattern "GITHUB_FINE_PAT" \
  'github_pat_[A-Za-z0-9_]{82}'

# OpenAI / Anthropic / generic sk- API keys
redact_pattern "SK_API_KEY" \
  'sk-[A-Za-z0-9_\-]{20,}'

# Stripe live and test keys
redact_pattern "STRIPE_KEY" \
  '(sk|pk|rk)_(live|test)_[A-Za-z0-9]{24,}'

# Slack bot / app / user tokens
redact_pattern "SLACK_TOKEN" \
  'xox[baprs]-[A-Za-z0-9\-]{10,}'

# JWTs — three base64url segments joined by dots
redact_pattern "JWT" \
  'eyJ[A-Za-z0-9_\-]+\.[A-Za-z0-9_\-]+\.[A-Za-z0-9_\-]+'

# Authorization: Bearer / Token / Basic headers
redact_pattern "AUTH_HEADER" \
  '(?i)(bearer|token|basic)\s+[A-Za-z0-9_.~+\/=-]{8,}'

# Twilio API keys
redact_pattern "TWILIO_KEY" \
  'SK[a-f0-9]{32}'

# SendGrid API keys
redact_pattern "SENDGRID_KEY" \
  'SG\.[A-Za-z0-9_\-]{22}\.[A-Za-z0-9_\-]{43}'

# Database / broker connection strings with embedded credentials
redact_pattern "CONNECTION_STRING" \
  '(mongodb(\+srv)?|postgres(ql)?|mysql|redis|amqp):\/\/[^:@\s]+:[^@\s"'"'"']+@'

# Generic secret assignments in config files and env vars.
# Requires >=24-char value to reduce false positives on short config values.
# `secret` alone is excluded — must appear as a compound key (client_secret etc.)
# to avoid firing on innocuous uses of the word. Placeholder values (example,
# placeholder, your-, xxx, changeme, dummy, fake, test, sample) are excluded.
redact_pattern "KEY_ASSIGNMENT" \
  '(?i)(api[_-]?key|api[_-]?secret|auth[_-]?token|access[_-]?token|client[_-]?secret|private[_-]?key|refresh[_-]?token|session[_-]?token|encryption[_-]?key|signing[_-]?key|password|passwd)\s*[=:]\s*["\x27]?(?!.*(?:example|placeholder|your[-_]|xxx|changeme|dummy|fake|test|sample))[A-Za-z0-9+\/\-_!@#$%^&*]{24,}["\x27]?'

# SSH public key base64 material (outside a PEM block)
redact_pattern "SSH_KEY_MATERIAL" \
  'AAAA[A-Za-z0-9+\/]{40,}={0,2}'

# ── Emit result ───────────────────────────────────────────────────────────────

if [[ "$found" -eq 0 ]]; then
  exit 0
fi

# Block the tool output from entering Claude's context.
# decision:block prevents Claude from seeing the raw output; reason tells Claude
# what happened. suppressOutput additionally hides the raw value from debug logs.
printf '%s' "$redacted" | jq -Rs \
  '{
    decision: "block",
    reason: ("Tool output contained one or more secret patterns and was redacted by output-redact.sh. Sanitised output:\n\n" + .),
    suppressOutput: true
  }'
