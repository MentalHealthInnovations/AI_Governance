#!/usr/bin/env bash
# PreToolUse hook for WebFetch. Enforces a domain allowlist: blocks all fetches
# except those to explicitly permitted domains. Outputs Claude Code hookSpecificOutput JSON.
set -u

logtofile() {
  echo "[$(date)] $1" >> "$HOME/.claude/debug/hook.log"
}

logtofile "webfetch hook fired"

payload="$(cat)"
url="$(printf '%s' "$payload" | jq -r '.tool_input.url // empty')"

logtofile "url extracted: $url"

if [[ -z "$url" ]]; then
  logtofile "no url found, exiting"
  exit 0
fi

# Extract hostname from URL (strip scheme, path, port, query).
# Assumes well-formed absolute URLs with a scheme (e.g. https://host/path).
# Schemeless URLs (//host/path) or credential-embedded URLs (user:pass@host)
# won't parse correctly, but the WebFetch tool always provides absolute https URLs.
hostname="$(printf '%s' "$url" | sed -E 's|^[^:]+://([^/:?#@]*).*|\1|; s|^[^@]*@||')"

logtofile "hostname extracted: $hostname"

# This list must be kept in sync with network.allowedDomains in managed-settings.json.
# When adding a domain here, add it there too (and vice versa).
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
