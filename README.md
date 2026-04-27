# Claude Code — AI Agent Governance Control Pack

This control pack provides a layered configuration system for Claude Code, designed to make it safer and smoother to use at the same time. The objective is not to prompt more often. The objective is to prompt less often, but only after the environment has already removed the riskiest options.

## File manifest

| File | Purpose |
|------|---------|
| `ClaudeCode/managed-settings.json` | Org-wide immutable guardrails (Layer 1) |
| `ClaudeCode/CLAUDE.md` | Behavioural guidance for Claude Code agents |
| `ClaudeCode/control_mappings.csv` | Mapping of controls to ISO 42001 / NIST AI RMF |
| `ClaudeCode/opt/claude/hooks/bash-policy-check.sh` | Pre-execution policy hook for bash commands |
| `ClaudeCode/opt/claude/hooks/webfetch-policy-check.sh` | Pre-execution policy hook for WebFetch calls |
| `ClaudeCode/opt/claude/hooks/output-redact.sh` | Post-execution output redaction hook for Bash, Read, and WebFetch |
| `ClaudeCode/pull_claude_governance.sh` | Script deployed to `/usr/local/bin/` — clones the repo and copies policy files; self-updates on each run |
| `ClaudeCode/InstallClaudeGovernance.sh` | One-time installation script for macOS (bootstraps `pull_claude_governance.sh`) |
| `docs/staff-brief.md` | Non-technical overview for staff receiving Claude Code |
| `docs/exception-process.md` | How to request policy changes or exceptions |

## Installation

Run `InstallClaudeGovernance.sh` once as root on each managed machine. It:

1. Creates `/usr/local/bin/pull_claude_governance.sh`, which pulls the latest policies from this repository.
2. Runs that script immediately to apply current policies.
3. Installs `/usr/local/bin/update_ai_governance`, a setuid binary allowing any local user to trigger a policy update without root access.
4. Schedules a daily cron job (12:00) to keep policies up to date.

On each run, `pull_claude_governance.sh` deploys:
- `managed-settings.json` → `/Library/Application Support/ClaudeCode/`
- `CLAUDE.md` → `/Library/Application Support/ClaudeCode/`
- Hook scripts → `/opt/claude/hooks/`

## Settings hierarchy

Claude Code uses a four-layer configuration system. Higher layers take precedence over lower ones; deny rules are cumulative and cannot be undone by a lower layer. See the [Claude Code documentation](https://code.claude.com/docs/en/settings#configuration-scopes) for a full description of each scope.

The managed layer (`managed-settings.json`) is the security boundary. It defines rules that no individual developer or project can weaken: network egress controls, credential-path deny rules, approved MCP servers, sandbox policy, and hooks that must always run. Developers cannot edit this file.

### CLAUDE.md

`CLAUDE.md` is not part of the permissions hierarchy. It shapes Claude Code's behaviour — coding conventions, tone, review expectations, and task constraints — rather than what it is allowed to execute. Think of the settings layers as the guardrails and `CLAUDE.md` as the driving instructions. It is deployed alongside `managed-settings.json` so it applies org-wide.

## Control surfaces

### Bash

Known-bad commands are denied outright. Medium-risk commands require approval. Common low-risk commands are allowed where appropriate.

### Network

Arbitrary egress is restricted. Approved domains are allowlisted in sandbox settings. Generic download and exfiltration tools are blocked.

### Filesystem

Safe working directories are allowed. Sensitive paths (`.env`, `secrets/`, SSH keys, cloud credentials) and system locations are blocked.

### GitHub

GitHub is allowed through constrained workflows, not as a blanket trust assumption. Read-oriented operations are usually allowlisted. Higher-impact actions such as creating or merging pull requests require approval. Dangerous history modification is blocked.

### MCP servers

MCP servers are locked to a managed allowlist. Only servers defined in `managed-settings.json` can be used. To request a new MCP server, submit a change to the managed settings through the security/platform team — the process is the same as requesting a new approved domain.

### Skills

`disableSkillShellExecution: true` prevents skill scripts from executing shell commands directly. Skills can still invoke tools through the normal Claude Code tool-use pathway, where hooks and sandbox rules apply. This setting closes a bypass route where a skill's embedded shell script could run without going through the `bash-policy-check.sh` hook.

## Hooks

Hooks run as pre-execution checks at the managed level.

**`bash-policy-check.sh`** runs before every bash command. It enforces policy rules that go beyond pattern matching in the deny list — for example, catching obfuscated commands or compound expressions that would bypass simple glob rules. If it exits non-zero, the command is blocked and the developer sees the rejection reason.

**`webfetch-policy-check.sh`** runs before every WebFetch call. It enforces an allowlist of approved domains, blocking requests to any domain not explicitly permitted in `managed-settings.json`.

**`output-redact.sh`** runs after every Bash, Read, and WebFetch call (`PostToolUse`). It scans tool output for API keys, credentials, and other sensitive values. If a match is found the result is blocked — the output never enters Claude's context window — and the tool call surfaces as a blocked result. The UI transcript may still display the raw output, but Claude cannot read or act on it. Each detection is logged (pattern name and first six characters of the match) for audit purposes — the full value is never written to the log. Patterns covered include: PEM blocks, AWS access key IDs and secret keys, GitHub PATs (classic and fine-grained), OpenAI/Anthropic `sk-` keys, Slack tokens, JWTs, Bearer headers, generic `key=value` / `password=value` env assignments, connection strings, and Stripe/Twilio/SendGrid vendor keys.

Hooks are deployed to `/opt/claude/hooks/` by the install script and must be present before Claude Code is used. If a hook is missing or fails, the operation is blocked (`failIfUnavailable: true` in sandbox settings).

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

Only deny and redact events are logged — allowed operations produce no log entry. The `output-redact` log records the pattern name and the first six characters of the matched value — never the full secret.

### What to review

Review hook logs periodically to identify:

- **Repeated blocks on the same command** — may indicate a legitimate use case that the allowlist should cover, or a user attempting to work around a control
- **Unexpected `output-redact` hits** — secrets appearing in file reads or command output may indicate a project is storing credentials in a way that needs fixing
- **WebFetch blocks** — repeated attempts to reach unapproved domains may indicate a dependency on a service not yet allowlisted

### Fleet-wide log collection

Hook logs are local by default. To aggregate them centrally, configure your endpoint management tooling (e.g. Jamf, osquery, a log forwarder) to ship `~/.claude/debug/bash-policy.log`, `~/.claude/debug/webfetch-policy.log`, and `~/.claude/debug/output-redact.log` to your SIEM or log platform of choice. The files are append-only and safe to tail or rotate.

Until centralised collection is in place, logs must be reviewed on a per-machine basis — for example, as part of a periodic compliance check or in response to a reported incident.

### Incident response

If you suspect a guardrail bypass:

1. Review the local hook logs on the affected machine for anomalous patterns.
2. Check git history for any recent changes to the managed settings or hook scripts — these require two-person approval and should match what is in `main`.
3. Verify installed hooks match the repository: `shasum -a 256 /opt/claude/hooks/*.sh` and compare against `shasum -a 256 ClaudeCode/opt/claude/hooks/*.sh` in the repo.
4. If there is evidence of tampering, treat it as a security incident and follow MHI's standard incident response procedure.

## Deployment

Merging to `main` does **not** automatically deploy to managed machines — the daily cron job pulls on its own schedule. See [Installation](#installation) for what `pull_claude_governance.sh` deploys and where.

### Deploying a change immediately

To push a change to a specific machine without waiting for the daily cron:

```bash
# As any local user (no sudo required — uses the setuid binary installed by InstallClaudeGovernance.sh)
update_ai_governance

# Or directly as root
/usr/local/bin/pull_claude_governance.sh
```

### Verifying deployment

After deploying, confirm the installed files match the repo:

```bash
# Check hook script versions match what was deployed
shasum -a 256 /opt/claude/hooks/*.sh
shasum -a 256 /Library/Application\ Support/ClaudeCode/managed-settings.json
```

Then run `/test-guardrails` in Claude Code to confirm all controls are active.

### After merging a security-sensitive change

For hook script updates or permission rule changes, don't wait for the cron:

1. Merge the PR.
2. Run `update_ai_governance` on affected machines.
3. Run `/test-guardrails` to confirm the change is live and no regressions were introduced.

## Troubleshooting

### Hook errors

If Claude Code surfaces an error like `hook exited with non-zero status` or `hook script not found` when running a Bash command, WebFetch, or file read, the most likely cause is that the hook scripts were not deployed to `/opt/claude/hooks/` on this machine.

**Fix:** run `update_ai_governance` in your terminal (no sudo required). This pulls the latest policy files from the repo and deploys them. Then retry the operation.

If the error persists after deploying:

1. Confirm the hook files exist: `ls /opt/claude/hooks/`
2. Confirm they are executable: `ls -l /opt/claude/hooks/*.sh`
3. Check the hook log for the specific failure: `~/.claude/debug/bash-policy.log`, `~/.claude/debug/webfetch-policy.log`, or `~/.claude/debug/output-redact.log`
4. Run `/test-guardrails` in Claude Code to identify which hook is failing and whether it is a policy block or an unexpected error

If a command you expect to be allowed is being blocked, check the hook log for the block reason. If it looks like a false positive, raise a PR or contact the IT and security team rather than trying to work around it.

## Change control

### IT and security team

Own: `managed-settings.json`, `CLAUDE.md`, managed hooks, sandbox policy, approved domains and MCP servers.

### Repository maintainers

Own: `.claude/settings.json`, repo-local safe task automation, repo-specific low-risk allowlists.

### Individual engineers

Own: `~/.claude/settings.json`, `.claude/settings.local.json`.

Engineers may improve convenience inside the rails, but they do not control the rails.

### What needs a PR to this repo?

**Important:** the settings layers (`~/.claude/settings.json`, `.claude/settings.json`) control whether Claude asks for permission before acting. They do not control what the hooks allow. The hooks run regardless of settings layer configuration and enforce their own allowlists independently. This means adding an allow rule to your personal or project settings will not unblock something the hooks reject — that requires a change to the hook script or `managed-settings.json` in this repo.

Use this table to route your request:

| What you want | Goes through this repo? | Who to ask |
|---|---|---|
| Allow a new domain for WebFetch | Yes | Raise a PR to `managed-settings.json` and `webfetch-policy-check.sh` — contact the IT and security team if you need help |
| Allow a Bash command the hook currently blocks | Yes | Raise a PR to `bash-policy-check.sh` — contact the IT and security team if you need help |
| Add or update a secret-detection pattern | Yes | Raise a PR to `output-redact.sh` — contact the IT and security team if you need help |
| Request a new MCP server | Yes | Raise a PR to `managed-settings.json` — contact the IT and security team if you need help |
| Update behavioural guidance (coding conventions, tone) | Yes | Raise a PR to `CLAUDE.md` — contact the IT and security team if you need help |
| Add a team-wide allow rule for a repo (non-hook) | Yes | Repo maintainer — PR to `.claude/settings.json` in that repo |
| Personal formatting or verbosity preferences | No | Edit `~/.claude/settings.json` locally |
| Temporary plan-mode or debug config for one project | No | Edit `.claude/settings.local.json` locally (git-ignored) |

If in doubt, raise an issue in this repo describing what you need and why, or contact the IT and security team directly.

## Governance alignment

`control_mappings.csv` maps all controls to ISO 42001 AI management system requirements and NIST AI RMF, as well as OWASP LLM risks (LLM01 Prompt Injection, LLM02 Insecure Output, LLM06 Sensitive Info Disclosure, LLM08 Excessive Agency).
