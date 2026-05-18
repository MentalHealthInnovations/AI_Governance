# Claude Code — AI Agent Governance Control Pack

A layered configuration system that makes Claude Code safer to use at scale. The goal is fewer prompts, not more — by removing the riskiest options from the environment up front.

## File manifest

| File | Purpose |
|------|---------|
| `ClaudeCode/managed-settings.json` | Org-wide immutable guardrails (permissions, sandbox, hooks, MCP allowlist) |
| `ClaudeCode/managed-mcp.json` | Server definitions for approved MCP servers (exclusive control mode) |
| `ClaudeCode/CLAUDE.md` | Behavioural guidance for Claude Code agents |
| `ClaudeCode/control_mappings.csv` | Control mapping to ISO 42001 / NIST AI RMF |
| `ClaudeCode/opt/claude/hooks/bash-policy-check.sh` | Pre-execution policy hook for Bash |
| `ClaudeCode/opt/claude/hooks/webfetch-policy-check.sh` | Pre-execution policy hook for WebFetch |
| `ClaudeCode/opt/claude/hooks/output-redact.sh` | Post-execution secret redaction for Bash/Read/WebFetch |
| `ClaudeCode/pull_claude_governance.sh` | Pulls and deploys policy files; self-updates each run |
| `ClaudeCode/InstallClaudeGovernance.sh` | One-time macOS bootstrap for `pull_claude_governance.sh` |
| `.claude/skills/test-guardrails/SKILL.md` | `/test-guardrails` verification suite |
| `.claude/skills/add-mcp-server/SKILL.md` | `/add-mcp-server` skill for proposing a new MCP server |

## Installation

Run `InstallClaudeGovernance.sh` once as root on each managed machine. It:

1. Installs `/usr/local/bin/pull_claude_governance.sh` and runs it immediately.
2. Installs `/usr/local/bin/update_ai_governance`, a setuid wrapper so any local user can trigger a refresh without sudo.
3. Schedules a daily cron (12:00) to keep policies current.

Each run of `pull_claude_governance.sh` deploys `managed-settings.json`, `managed-mcp.json`, and `CLAUDE.md` to `/Library/Application Support/ClaudeCode/`, and hook scripts to `/opt/claude/hooks/`.

## Settings hierarchy

Claude Code uses a four-layer configuration system; higher layers take precedence and deny rules are cumulative. See [the Claude Code docs](https://code.claude.com/docs/en/settings#configuration-scopes) for full detail.

`managed-settings.json` is the security boundary — network egress, credential deny rules, sandbox policy, approved MCP servers, and mandatory hooks. Developers cannot edit it.

`CLAUDE.md` sits outside the permissions hierarchy. It shapes Claude's behaviour (conventions, tone, review expectations); the settings layers define what it is *allowed* to do.

## Control surfaces

- **Bash** — known-bad commands denied outright; medium-risk requires approval; common low-risk allowed.
- **Network** — egress restricted to an allowlist; generic download/exfiltration tools blocked.
- **Filesystem** — safe working dirs allowed; `.env`, `secrets/`, SSH keys, cloud creds, and system paths blocked.
- **GitHub** — read operations mostly allowlisted; PR creation/merge requires approval; history-rewriting flags blocked.
- **MCP servers** — locked to the managed allowlist. New servers go through the same PR process as new domains. To propose one, run `/add-mcp-server`.
- **Skills** — `disableSkillShellExecution: true` prevents skill scripts from shelling out directly, forcing them through the hook-policed tool pathway.

### Approved MCP servers

| Server | Runtime | Auth | Docs |
|---|---|---|---|
| `github` | Remote HTTP (`https://api.githubcopilot.com/mcp/`) | OAuth (per-user, browser flow at first connect) | https://github.com/github/github-mcp-server |

Server definitions live in **`managed-mcp.json`** (deployed to `/Library/Application Support/ClaudeCode/managed-mcp.json`). This is Claude Code's "exclusive control" mode — when the file is present, it is the entire set of MCP servers users can run; nothing else is permitted. `managed-settings.json` carries only the *policy* layer (`allowedMcpServers` allowlist, `allowManagedMcpServersOnly: true`).

GitHub's OAuth server does not support [Dynamic Client Registration](https://code.claude.com/docs/en/mcp#use-pre-configured-oauth-credentials), so the `github` entry pins a **pre-configured OAuth Client ID** registered against an MHI-owned GitHub OAuth App. The client ID is public and committed to source control; the client secret is **per-engineer** — Claude Code prompts for it once on first authenticate and stores it in the macOS keychain.

> **Status:** the currently-committed `clientId` is a temporary probe app registered under a personal GitHub account. Once verified working end-to-end, it will be replaced with an MHI-org-owned OAuth App and the secret distributed via 1Password.

**Per-engineer setup (once):**

1. Run `update_ai_governance` so `managed-mcp.json` is deployed locally.
2. Open Claude Code in any repo, run `/mcp`, select `github`, choose **Authenticate**.
3. When prompted for the client secret, paste the value from the shared 1Password entry (`MHI Claude Code GitHub OAuth App`).
4. Browser flow opens, sign in with your MHI GitHub account, approve the requested scopes.
5. Subsequent sessions don't re-prompt — Claude Code refreshes tokens automatically. Revoke at https://github.com/settings/applications.

If `claude mcp list` does not show `github` at all, run `update_ai_governance` and retry. If `github` is listed but `/mcp` says "Failed — Incompatible auth server", the deployed `managed-mcp.json` is missing the `oauth.clientId` block — re-bootstrap.

**Alternative: per-user PAT override.** If you specifically need PAT auth (e.g. to scope tightly to specific repos), add a *user-scoped* override locally — it does not affect anyone else and never enters source control:

```bash
claude mcp add-json --scope user github "{\"type\":\"http\",\"url\":\"https://api.githubcopilot.com/mcp/\",\"headers\":{\"Authorization\":\"Bearer ${GITHUB_PAT}\"}}"
```

Set `GITHUB_PAT` in the shell session where you launch Claude Code (do not persist it in `~/.zshrc`). Generate fine-grained tokens at https://github.com/settings/personal-access-tokens. See https://github.com/github/github-mcp-server/blob/main/docs/installation-guides/install-claude.md for full upstream guidance.

## Hooks

Hooks are deployed to `/opt/claude/hooks/` and must be present before Claude Code runs — if a hook is missing or fails, the operation is blocked.

- **`bash-policy-check.sh`** (PreToolUse, Bash) — enforces policy beyond glob matching; catches obfuscation and compound expressions that would bypass simple deny patterns.
- **`webfetch-policy-check.sh`** (PreToolUse, WebFetch) — enforces the domain allowlist.
- **`output-redact.sh`** (PostToolUse, Bash/Read/WebFetch) — scans tool output for secrets. On match, the result is blocked before entering Claude's context. The UI transcript may still show the raw output, but Claude cannot read or act on it. Each detection logs the pattern name and the first six characters of the match — never the full value. Patterns: PEM blocks, AWS keys, GitHub PATs (classic and fine-grained), `sk-` keys, Slack tokens, JWTs, Bearer headers, generic `key=value` / `password=value` assignments, connection strings, and Stripe/Twilio/SendGrid keys.

### Audit logs

Each hook writes to `~/.claude/debug/` on block or redact (allowed operations produce no entry). Each line includes the working directory at the time of the call.

| Hook | Log path |
|---|---|
| `bash-policy-check.sh` | `~/.claude/debug/bash-policy.log` |
| `webfetch-policy-check.sh` | `~/.claude/debug/webfetch-policy.log` |
| `output-redact.sh` | `~/.claude/debug/output-redact.log` |

Review logs for repeated blocks on the same command (legitimate use case to allow, or a workaround attempt), unexpected redact hits (project storing secrets badly), or repeated WebFetch blocks on the same domain (dependency on an unapproved service).

Logs are local by default. To aggregate, ship the three log paths to your SIEM via Jamf/osquery/log forwarder. They are append-only and safe to tail or rotate.

### Log rotation

Manually:

```bash
: > ~/.claude/debug/bash-policy.log
: > ~/.claude/debug/webfetch-policy.log
: > ~/.claude/debug/output-redact.log
```

For automated rotation, drop a `newsyslog` config into `/etc/newsyslog.d/`. Because logs are per-user, the config must use an expanded home path:

```
# /etc/newsyslog.d/claude-hooks-alice.conf
/Users/alice/.claude/debug/bash-policy.log     alice:staff  640  7  -1  $D0  ZN
/Users/alice/.claude/debug/webfetch-policy.log alice:staff  640  7  -1  $D0  ZN
/Users/alice/.claude/debug/output-redact.log   alice:staff  640  7  -1  $D0  ZN
```

Daily rotation, 7 compressed archives, no daemon signal. See `man 5 newsyslog.conf`.

## Deployment

Merging to `main` does **not** auto-deploy — the daily cron picks it up. To push immediately:

```bash
update_ai_governance                            # any local user, no sudo
/usr/local/bin/pull_claude_governance.sh        # or directly as root
```

Verify after deploying:

```bash
cat /Library/Application\ Support/ClaudeCode/VERSION
shasum -a 256 /opt/claude/hooks/*.sh
shasum -a 256 /Library/Application\ Support/ClaudeCode/managed-settings.json
shasum -a 256 /Library/Application\ Support/ClaudeCode/managed-mcp.json
```

Then open Claude Code in this repo and run `/test-guardrails` to confirm all controls are live. For hook or permission changes, do this on affected machines immediately after merge rather than waiting for cron.

### Incident response

On suspected bypass:

1. Review `~/.claude/debug/*.log` on the affected machine.
2. Confirm deployed version matches `main`: `cat /Library/Application\ Support/ClaudeCode/VERSION`.
3. Verify installed hooks match the repo at that SHA via `shasum`.
4. If tampering is evident, follow MHI's standard incident response.

## Troubleshooting

Most hook errors (`hook exited with non-zero status`, `hook script not found`) mean hooks aren't deployed. Run `update_ai_governance` and retry.

If it persists: confirm hooks exist and are executable in `/opt/claude/hooks/`, check the relevant log in `~/.claude/debug/`, and run `/test-guardrails`. If a command you expect to work is blocked and the log shows a false positive, raise a PR — don't work around it.

## Change control

Ownership:

| Layer | Owned by |
|---|---|
| `managed-settings.json`, `managed-mcp.json`, `CLAUDE.md`, hooks, sandbox, approved domains/MCP | IT and security |
| `.claude/settings.json` (repo-local automation, low-risk allowlists) | Repo maintainers |
| `~/.claude/settings.json`, `.claude/settings.local.json` (personal/convenience) | Individual engineers |

Engineers may improve convenience inside the rails; they do not control the rails.

> **Important:** settings layers control whether Claude *asks* before acting. They do not control what the *hooks* allow. Adding an allow rule locally will not unblock something a hook rejects — that requires a PR to the hook or to `managed-settings.json`.

### What needs a PR here

| Request | Target file |
|---|---|
| New WebFetch domain | `managed-settings.json` + `webfetch-policy-check.sh` |
| Allow a currently-blocked Bash command | `bash-policy-check.sh` |
| New/updated secret-detection pattern | `output-redact.sh` |
| New MCP server | `managed-mcp.json` (server definition) + `managed-settings.json` (allowlist) |
| Behavioural guidance change | `CLAUDE.md` |
| Team-wide repo allow rule | `.claude/settings.json` in that repo (not here) |
| Personal preference | `~/.claude/settings.json` locally (not here) |

If unsure, raise an issue or contact IT and security.

### Exception process

Before requesting an exception, check whether Claude can reach the same outcome a different way (a different tool, a rephrased command, or generating the command for you to run manually).

If not, open a PR against `main` using the PR template — it prompts for the security risk assessment. If you'd rather not raise the PR yourself, contact max.levine@mhiuk.org or edward@mhiuk.org.

The security team reviews against: whether existing controls already cover the use case, prompt-injection exploit risk if widened, and whether a project-level setting would be more appropriate than an org-wide change. Both CODEOWNERS (@edwardmhi, @maxlevine-mhi) must approve. Response within 5 working days; flag urgency in the PR.

Approved PRs are tested with `/test-guardrails`, merged, and deployed via the next cron (or `update_ai_governance` for immediate rollout).

If declined and you disagree, escalate via your line manager to head of IT or security.

#### Commonly refused requests

| Request | Reason | Alternative |
|---|---|---|
| `curl` / `wget` | Exfiltration vector | Use `WebFetch` (domain-allowlisted) |
| `sudo` | Privilege escalation | Run privileged operations outside Claude Code |
| Read `.env` | Credential exposure | Pass values via env vars, not files |
| Arbitrary domains | Egress control | Submit a domain addition |
| `git --force` | Destructive | Use non-destructive git workflows |

## Governance alignment

`control_mappings.csv` maps each control to ISO 42001, NIST AI RMF, and OWASP LLM Top 10 (LLM01 Prompt Injection, LLM02 Insecure Output, LLM06 Sensitive Info Disclosure, LLM08 Excessive Agency).
