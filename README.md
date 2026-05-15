# Claude Code — AI Agent Governance Control Pack

A layered configuration system that makes Claude Code safer to use at scale. The goal is fewer prompts, not more — by removing the riskiest options from the environment up front.

## File manifest

| File | Purpose |
|------|---------|
| `ClaudeCode/managed-settings.json` | Org-wide immutable guardrails |
| `ClaudeCode/CLAUDE.md` | Behavioural guidance for Claude Code agents |
| `ClaudeCode/control_mappings.csv` | Control mapping to ISO 42001 / NIST AI RMF |
| `ClaudeCode/opt/claude/hooks/bash-policy-check.sh` | Pre-execution policy hook for Bash |
| `ClaudeCode/opt/claude/hooks/webfetch-policy-check.sh` | Pre-execution policy hook for WebFetch |
| `ClaudeCode/opt/claude/hooks/output-redact.sh` | Post-execution secret redaction for Bash/Read/WebFetch |
| `ClaudeCode/pull_claude_governance.sh` | Pulls and deploys policy files; self-updates each run |
| `ClaudeCode/InstallClaudeGovernance.sh` | One-time macOS bootstrap for `pull_claude_governance.sh` |
| `.claude/skills/test-guardrails/SKILL.md` | `/test-guardrails` verification suite |

## Installation

Run `InstallClaudeGovernance.sh` once as root on each managed machine. It:

1. Installs `/usr/local/bin/pull_claude_governance.sh` and runs it immediately.
2. Installs `/usr/local/bin/update_ai_governance`, a setuid wrapper so any local user can trigger a refresh without sudo.
3. Schedules a daily cron (12:00) to keep policies current.

Each run of `pull_claude_governance.sh` deploys `managed-settings.json` and `CLAUDE.md` to `/Library/Application Support/ClaudeCode/`, and hook scripts to `/opt/claude/hooks/`.

## Settings hierarchy

Claude Code uses a four-layer configuration system; higher layers take precedence and deny rules are cumulative. See [the Claude Code docs](https://code.claude.com/docs/en/settings#configuration-scopes) for full detail.

`managed-settings.json` is the security boundary — network egress, credential deny rules, sandbox policy, approved MCP servers, and mandatory hooks. Developers cannot edit it.

`CLAUDE.md` sits outside the permissions hierarchy. It shapes Claude's behaviour (conventions, tone, review expectations); the settings layers define what it is *allowed* to do.

## Control surfaces

- **Bash** — known-bad commands denied outright; medium-risk requires approval; common low-risk allowed.
- **Network** — egress restricted to an allowlist; generic download/exfiltration tools blocked.
- **Filesystem** — safe working dirs allowed; `.env`, `secrets/`, SSH keys, cloud creds, and system paths blocked.
- **GitHub** — read operations mostly allowlisted; PR creation/merge requires approval; history-rewriting flags blocked.
- **MCP servers** — locked to the managed allowlist. New servers go through the same PR process as new domains.
    - Atlassian server: SSE (`https://mcp.atlassian.com/v1/sse`), per-user OAuth, read and update Jira issues and Confluence pages on behalf of the signed-in engineer
- **Skills** — `disableSkillShellExecution: true` prevents skill scripts from shelling out directly, forcing them through the hook-policed tool pathway.

## Hooks

Hooks are deployed to `/opt/claude/hooks/` and must be present before Claude Code runs — if a hook is missing or fails, the operation is blocked.

- **`bash-policy-check.sh`** (PreToolUse, Bash) — enforces policy beyond glob matching; catches obfuscation and compound expressions that would bypass simple deny patterns.
- **`webfetch-policy-check.sh`** (PreToolUse, WebFetch) — enforces the domain allowlist.
- **`output-redact.sh`** (PostToolUse, Bash/Read/WebFetch) — scans tool output for secrets. On match, the result is blocked before entering Claude's context. The UI transcript may still show the raw output, but Claude cannot read or act on it. Each detection logs the pattern name and the first six characters of the match — never the full value. Patterns: PEM blocks, AWS keys, GitHub PATs (classic and fine-grained), `sk-` keys, Slack tokens, JWTs, Bearer headers, generic `key=value` / `password=value` assignments, connection strings, and Stripe/Twilio/SendGrid keys.

### Audit logs

Each hook writes to `~/.claude/debug/` on block or redact (allowed operations produce no entry). Each line includes the working directory at the time of the call.

## MCP servers — operational notes

This section covers how engineers actually use the MCP servers listed in [Control surfaces → MCP servers](#mcp-servers). The control pack defines *which* servers are permitted; this section explains how each one is authenticated and used.

### Atlassian Remote MCP server

**What it does.** Lets Claude Code read and update Jira issues and Confluence pages — fetch a ticket, post a comment, transition a status, summarise a Confluence page. Useful for ticket triage, drafting comments from local code context, and pulling acceptance criteria into a working session.

**Endpoint.** `https://mcp.atlassian.com/v1/sse` (SSE transport). Hosted by Atlassian — no local install, no API token, no env var required on the engineer's machine.

**Authentication model — per user, not global.** The Atlassian Remote MCP uses OAuth 2.1 and authenticates each engineer individually:

- On first use, Claude Code opens a browser. The engineer signs in with their MHI Atlassian account and grants scopes.
- Atlassian issues a per-user token bound to that engineer's identity and stored locally by Claude Code.
- Every action runs **as that engineer**, so existing Atlassian permissions, project access, and audit logs apply unchanged.

There is intentionally no shared admin token that could be configured once for the whole org. A shared token would break the audit trail (every action would appear as a service account) and would grant every Claude Code user the union of all permissions. Atlassian does not support that mode.

> **One-time org admin step (verify before broad rollout):** an Atlassian org admin may need to confirm the Remote MCP / Rovo feature is enabled at the org level in the Atlassian admin console before individual users can connect. On some Atlassian plans this is on by default; on plans with stricter defaults an admin must allow it. This needs to be confirmed against the current Atlassian admin documentation before this PR is marked ready for review. Contact max.levine@mhiuk.org or edward@mhiuk.org — they hold the Atlassian admin role.

### First-use setup (per engineer)

1. Open Claude Code in any working directory.
2. At the prompt, type `/mcp`. The `atlassian` server should be listed with status `disconnected`.
3. Select `atlassian` and choose `Connect`. Claude Code opens your browser to Atlassian.
4. Sign in with your MHI Atlassian account.
5. Review the requested scopes carefully. Grant only the scopes you need for your work — you can re-grant later if more are needed.
6. Return to Claude Code. `/mcp` should now show `atlassian` as `connected`.

You only need to do this once per machine. The token is stored locally by Claude Code and refreshed automatically by Atlassian.

### Scope guidance

When the OAuth consent screen asks for scopes:

- **Grant:** read access to Jira issues and Confluence pages — required for the common case (ticket lookup, page summarisation).
- **Grant only if you need it:** write access (creating issues, posting comments, transitioning status, editing pages). If your work is read-only, do not grant write scopes.
- **Do not grant:** admin scopes (user management, project administration) — Claude Code does not need these and they significantly increase blast radius if a prompt injection drives Claude into unintended actions.

### Revocation

To revoke Claude Code's access to your Atlassian account:

1. Sign in to <https://id.atlassian.com>.
2. Go to **Account settings → Connected apps** (or **Authorized apps**, depending on UI version).
3. Find the Claude Code / Anthropic entry and click **Revoke access**.

The next `/mcp` connection attempt will require re-consent.

### Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| `/mcp` shows `atlassian` as `disconnected` and `Connect` does nothing | Browser handler not registered, or the Atlassian login page is blocked by a corporate proxy | Try again from a network that can reach `id.atlassian.com` and `mcp.atlassian.com`; if your browser does not auto-open, copy the URL from the Claude Code log |
| `Connect` opens the browser but the page is blank or shows an Atlassian error | Org-level Remote MCP / Rovo not enabled, or your Atlassian account does not have access to the requested product | Contact an Atlassian admin (max.levine@mhiuk.org / edward@mhiuk.org) to confirm the feature is enabled and your account is provisioned |
| `mcp__atlassian__*` tool calls fail with `403` or `401` after a successful connect | OAuth scope mismatch — the action requires a scope you did not grant | Disconnect via `/mcp`, reconnect, and grant the missing scope on the consent screen |
| `mcp.atlassian.com` requests blocked at the network layer | Hook or sandbox not yet updated on this machine | Run `update_ai_governance` and retry; confirm `mcp.atlassian.com` is in the deployed `managed-settings.json` `network.allowedDomains` |

### Audit and visibility

All Jira and Confluence actions made through this MCP appear in Atlassian's standard audit log, attributed to the signed-in engineer. There is no separate Claude Code audit log on the Atlassian side. On the Claude Code side, MCP tool calls appear in the conversation transcript as `mcp__atlassian__<toolname>` entries.

## Operating model

Start with a small set of strong deny rules and a useful set of low-risk allow rules.

Use approval and denial telemetry to tune the middle layer over time:
- Promote repetitive safe asks into allow.
- Keep hard deny rules small, stable, and explicit.
- Avoid creating so many prompts that users stop reading them carefully.

## Monitoring and alerting

### Hook audit logs

Each hook writes to a local log file when it blocks or allows an operation:

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
| `managed-settings.json`, `CLAUDE.md`, hooks, sandbox, approved domains/MCP | IT and security |
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
| New MCP server | `managed-settings.json` |
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
