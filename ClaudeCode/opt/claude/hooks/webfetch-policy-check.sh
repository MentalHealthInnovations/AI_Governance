#!/usr/bin/env bash
# PreToolUse hook for WebFetch. Enforces a domain allowlist: blocks all fetches
# except those to explicitly permitted domains. Outputs Claude Code hookSpecificOutput JSON.
set -u

logtofile() {
  echo "[$(date)] $1" >> /tmp/hook-debug.log
}

logtofile "webfetch hook fired"

payload="$(cat)"
url="$(printf '%s' "$payload" | jq -r '.tool_input.url // empty')"

logtofile "url extracted: $url"

if [[ -z "$url" ]]; then
  logtofile "no url found, exiting"
  exit 0
fi

# Extract hostname from URL (strip scheme, path, port, query)
hostname="$(printf '%s' "$url" | sed -E 's|^[^:]+://([^/:?#]*).*|\1|')"

logtofile "hostname extracted: $hostname"

allowed_domains=(
  "github.com"
  "api.github.com"
  "objects.githubusercontent.com"
  "raw.githubusercontent.com"
  "registry.npmjs.org"
  "pypi.org"
  "files.pythonhosted.org"
  "proxy.golang.org"
  "crates.io"
  "index.crates.io"
  "registry-1.docker.io"
  "auth.docker.io"
  "production.cloudflare.docker.com"
  "mentalhealthinnovations.org"
  "themix.org.uk"
  "giveusashout.org"
)

for domain in "${allowed_domains[@]}"; do
  if [[ "$hostname" == "$domain" || "$hostname" == *."$domain" ]]; then
    logtofile "ALLOW domain '$domain' matched: $url"
    echo '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"allow"}}'
    exit 0
  fi
done

logtofile "DENY domain not in allowlist: $url"
echo '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"Domain not in WebFetch allowlist"}}'
