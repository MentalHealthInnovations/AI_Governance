#!/usr/bin/env bash
# PostToolUse hook for Bash, Read, and WebFetch.
# Scans tool output for API keys and sensitive values, redacts them before Claude sees the content.
# Logs each redaction (pattern name + first 6 chars of match) for audit. Never logs the full value.
set -u

logtofile() {
  echo "[$(date)] $1" >> "$HOME/.claude/debug/hook.log"
}

logtofile "output-redact hook fired"

payload="$(cat)"

tool_name="$(printf '%s' "$payload" | jq -r '.tool_name // empty')"
logtofile "tool: $tool_name"

# Pull raw output text. Bash uses .tool_response.output; Read and WebFetch use
# .tool_response.content which may be a plain string or an array of {type,text} objects.
raw_output="$(printf '%s' "$payload" | jq -r '
  if .tool_response.output? and (.tool_response.output | type) == "string" then
    .tool_response.output
  elif .tool_response.content? and (.tool_response.content | type) == "array" then
    [.tool_response.content[] | select(.type == "text") | .text] | join("\n")
  elif .tool_response.content? and (.tool_response.content | type) == "string" then
    .tool_response.content
  else
    ""
  end
')"

if [[ -z "$raw_output" ]]; then
  logtofile "no output to scan, exiting"
  exit 0
fi

redacted="$raw_output"
found=0

# redact_pattern NAME REGEX
# Replaces all matches of REGEX with [REDACTED]. Logs pattern name and the first
# 6 chars of the first match (audit trail without exposing the secret).
redact_pattern() {
  local name="$1" regex="$2"
  local before="$redacted"
  redacted="$(printf '%s' "$redacted" | perl -pe "s/$regex/[REDACTED]/g")"
  if [[ "$redacted" != "$before" ]]; then
    found=1
    local sample
    sample="$(printf '%s' "$before" | perl -ne "/$regex/ && do { my \$m = \$&; \$m = substr(\$m,0,6); print \$m; exit }")"
    logtofile "REDACT $name sample='${sample}...'"
  fi
}

# PEM / private key blocks
redact_pattern "PEM_BLOCK" \
  '-----BEGIN [A-Z ]+-----[A-Za-z0-9+\/=\r\n]+-----END [A-Z ]+-----'

# AWS access key IDs (AKIA… / ASIA…)
redact_pattern "AWS_KEY_ID" \
  '(AKIA|ASIA)[A-Z0-9]{16}'

# AWS secret access key assignments
redact_pattern "AWS_SECRET" \
  '(?i)(aws_secret_access_key|secret_access_key)\s*[=:]\s*[A-Za-z0-9\/+]{40}'

# GitHub classic tokens (ghp_, gho_, ghu_, ghs_, ghr_)
redact_pattern "GITHUB_PAT" \
  'gh[pousr]_[A-Za-z0-9]{36}'

# GitHub fine-grained PATs
redact_pattern "GITHUB_FINE_PAT" \
  'github_pat_[A-Za-z0-9_]{82}'

# OpenAI / Anthropic / generic sk- keys
redact_pattern "SK_API_KEY" \
  'sk-[A-Za-z0-9\-_]{20,}'

# Slack tokens
redact_pattern "SLACK_PAT" \
  'xox[baprs]-[A-Za-z0-9\-]{10,}'

# JWTs (three base64url segments separated by dots)
redact_pattern "JWT" \
  'eyJ[A-Za-z0-9_\-]+\.[A-Za-z0-9_\-]+\.[A-Za-z0-9_\-]+'

# Bearer token in HTTP headers
redact_pattern "BEARER" \
  '(?i)bearer\s+[A-Za-z0-9\-._~+\/]{20,}'

# Generic key/password/secret assignments in env, JSON, or YAML.
# Requires >=16-char value to avoid matching short innocuous strings.
redact_pattern "KEY_ASSIGNMENT" \
  '(?i)(api[_-]?key|api[_-]?secret|auth[_-]?token|access[_-]?token|client[_-]?secret|private[_-]?key|refresh[_-]?token|session[_-]?token|encryption[_-]?key|signing[_-]?key|password|passwd|secret)\s*[=:]\s*["\x27]?[A-Za-z0-9+\/\-_!@#$%^&*]{16,}["\x27]?'

# Stripe keys
redact_pattern "STRIPE_KEY" \
  '(sk|pk|rk)_(live|test)_[A-Za-z0-9]{24,}'

# Twilio API keys
redact_pattern "TWILIO_KEY" \
  'SK[a-f0-9]{32}'

# SendGrid API keys
redact_pattern "SENDGRID_KEY" \
  'SG\.[A-Za-z0-9\-_]{22}\.[A-Za-z0-9\-_]{43}'

# SSH public key base64 material appearing outside a PEM block
redact_pattern "SSH_KEY_MATERIAL" \
  'AAAA[A-Za-z0-9+\/]{40,}={0,2}'

if [[ "$found" -eq 0 ]]; then
  logtofile "no sensitive values detected"
  exit 0
fi

logtofile "values redacted, returning sanitised output"

# Bash output lives in .output; Read and WebFetch use .content.
if [[ "$tool_name" == "Bash" ]]; then
  output_field="output"
else
  output_field="content"
fi

# suppressOutput hides the raw tool result; the replacement value is shown instead.
printf '%s' "$redacted" | jq -Rs \
  --arg field "$output_field" \
  '{
    hookSpecificOutput: {
      hookEventName: "PostToolUse",
      suppressOutput: true,
      ($field): .
    }
  }'
