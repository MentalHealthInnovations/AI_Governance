#!/usr/bin/env bash
# PreToolUse hook for WebFetch. Enforces a domain allowlist: blocks all fetches
# except those to explicitly permitted domains. Outputs Claude Code hookSpecificOutput JSON.
set -u

logtofile() {
  echo "[$(date)] [webfetch-policy] [$(pwd)] $1" >> "$HOME/.claude/debug/webfetch-policy.log"
}

payload="$(cat)"
url="$(printf '%s' "$payload" | jq -r '.tool_input.url // empty')"

if [[ -z "$url" ]]; then
  exit 0
fi

# Extract hostname from URL (strip scheme, userinfo, path, port, query).
# The regex uses two capture groups: group 1 optionally matches and discards a
# "userinfo@" prefix (e.g. "user:pass@"), group 2 captures the actual host.
# This prevents a bypass where an allowlisted domain is placed in the userinfo
# position (https://allowed.com@attacker.com/path) — RFC 3986 §3.2.1 defines
# userinfo as the component before @, so "allowed.com" would be the username and
# "attacker.com" the real host. The old two-expression sed ran the @-strip on the
# already-shortened string (which had no @ left), so the strip was a no-op.
hostname="$(printf '%s' "$url" | sed -E 's|^[^:]+://([^/:?#@]*@)?([^/:?#]*).*|\2|')"

logtofile "hostname extracted: $hostname"

# Allowlist is the bare-hostname list from managed-settings.json, read at runtime
# so the OS sandbox layer (network.allowedDomains) and this hook stay in lockstep
# without a manual sync step. No wildcard subdomain matching — subdomains must
# be listed explicitly. No path scoping — if a host is listed, any path on that
# host is allowed.
#
# Depends on `jq` (also required by bash-policy-check.sh and output-redact.sh).
managed_settings="/Library/Application Support/ClaudeCode/managed-settings.json"

if [[ ! -r "$managed_settings" ]]; then
  logtofile "DENY managed-settings.json missing or unreadable: $url"
  echo '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"WebFetch allowlist unavailable — managed-settings.json missing or unreadable"}}'
  exit 0
fi

# jq emits one host per line; grep -Fx matches the extracted hostname against
# any line exactly. Fails closed: if jq errors or no domains are configured,
# nothing matches and the deny below fires.
if printf '%s\n' "$hostname" | grep -Fxq -f <(jq -r '.sandbox.network.allowedDomains[]? // empty' "$managed_settings" 2>/dev/null); then
  echo '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"allow"}}'
  exit 0
fi

logtofile "DENY domain not in allowlist: $hostname"
echo '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"Domain not in WebFetch allowlist"}}'
exit 0
