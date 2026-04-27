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
| `.claude/skills/test-guardrails/SKILL.md` | Claude Code skill that runs the guardrail verification suite (`/test-guardrails`) |

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

Only deny and redact events are logged — allowed operations produce no log entry. Each log line includes the working directory at the time of the call, so entries from different projects can be attributed without ambiguity. The `output-redact` log records the pattern name and the first six characters of the matched value — never the full secret.

### What to review

Review hook logs periodically to identify:

- **Repeated blocks on the same command** — may indicate a legitimate use case that the allowlist should cover, or a user attempting to work around a control
- **Unexpected `output-redact` hits** — secrets appearing in file reads or command output may indicate a project is storing credentials in a way that needs fixing
- **WebFetch blocks** — repeated attempts to reach unapproved domains may indicate a dependency on a service not yet allowlisted

### Fleet-wide log collection

Hook logs are local by default. To aggregate them centrally, configure your endpoint management tooling (e.g. Jamf, osquery, a log forwarder) to ship `~/.claude/debug/bash-policy.log`, `~/.claude/debug/webfetch-policy.log`, and `~/.claude/debug/output-redact.log` to your SIEM or log platform of choice. The files are append-only and safe to tail or rotate.

Until centralised collection is in place, logs must be reviewed on a per-machine basis — for example, as part of a periodic compliance check or in response to a reported incident.

### Log rotation

Hook logs grow indefinitely. To rotate them manually on a managed machine:

```bash
# Truncate all three logs (macOS — no logrotate by default)
: > ~/.claude/debug/bash-policy.log
: > ~/.claude/debug/webfetch-policy.log
: > ~/.claude/debug/output-redact.log
```

For automated rotation, add a `newsyslog` config to `/etc/newsyslog.d/`. Because the logs are per-user, the config must be installed with the real home path expanded. Example for a user `alice`:

```
# /etc/newsyslog.d/claude-hooks-alice.conf
/Users/alice/.claude/debug/bash-policy.log     alice:staff  640  7  -1  $D0  ZN
/Users/alice/.claude/debug/webfetch-policy.log alice:staff  640  7  -1  $D0  ZN
/Users/alice/.claude/debug/output-redact.log   alice:staff  640  7  -1  $D0  ZN
```

This rotates daily (`$D0`), keeps 7 compressed archives, and sends no signal (no daemon to notify). Adjust `count` and `when` to taste. See `man 5 newsyslog.conf` for the full format.

### Incident response

If you suspect a guardrail bypass:

1. Review the local hook logs on the affected machine for anomalous patterns.
2. Check the deployed version: `cat /Library/Application\ Support/ClaudeCode/VERSION` and confirm it matches the expected commit in `main`.
3. Verify installed hooks match the repository at that SHA: `shasum -a 256 /opt/claude/hooks/*.sh` and compare against `shasum -a 256 ClaudeCode/opt/claude/hooks/*.sh` in the repo.
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

After deploying, confirm the installed version and that files match the repo:

```bash
# Check which policy version is deployed on this machine
cat /Library/Application\ Support/ClaudeCode/VERSION

# Verify installed files match the repo at that SHA
shasum -a 256 /opt/claude/hooks/*.sh
shasum -a 256 /Library/Application\ Support/ClaudeCode/managed-settings.json
```

Then run `/test-guardrails` in Claude Code to confirm all controls are active. This skill (defined in `.claude/skills/test-guardrails/SKILL.md`) is available when Claude Code is opened in this repository's working directory.

### After merging a security-sensitive change

For hook script updates or permission rule changes, don't wait for the cron:

1. Merge the PR.
2. Run `update_ai_governance` on affected machines.
3. Open Claude Code in this repository's working directory and run `/test-guardrails` to confirm the change is live and no regressions were introduced.

## Troubleshooting

### Hook errors

If Claude Code surfaces an error like `hook exited with non-zero status` or `hook script not found` when running a Bash command, WebFetch, or file read, the most likely cause is that the hook scripts were not deployed to `/opt/claude/hooks/` on this machine.

**Fix:** run `update_ai_governance` in your terminal (no sudo required). This pulls the latest policy files from the repo and deploys them. Then retry the operation.

If the error persists after deploying:

1. Confirm the hook files exist: `ls /opt/claude/hooks/`
2. Confirm they are executable: `ls -l /opt/claude/hooks/*.sh`
3. Check the hook log for the specific failure: `~/.claude/debug/bash-policy.log`, `~/.claude/debug/webfetch-policy.log`, or `~/.claude/debug/output-redact.log`
4. Run `/test-guardrails` in Claude Code (opened in this repository's working directory) to identify which hook is failing and whether it is a policy block or an unexpected error

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

---

## Staff communication — Claude Code at MHI

*The following is intended to be sent to or shared with all staff receiving Claude Code. It provides a non-technical overview of what is changing and what to expect.*

### What is Claude Code?

Claude Code is an AI assistant that works directly inside your code editor or terminal. You can ask it to explain code, write tests, review a pull request, or help you debug a problem. It works by reading files on your machine and running commands on your behalf — which is why we need guardrails around it.

### What are the guardrails?

We've deployed a governance control pack that limits what Claude Code can do on managed machines. These controls run automatically in the background — you don't need to configure anything.

**What the controls do:**

- Block Claude from reading secret files (passwords, API keys, SSH keys, cloud credentials)
- Prevent Claude from running dangerous shell commands (e.g. force-pushing to git, deleting files with `rm -rf`, using network tools like `curl`)
- Restrict which websites Claude can visit to a known-safe list
- Redact any secrets that might appear in file contents before Claude can read them

**What the controls don't do:**

- They don't stop Claude from helping you with normal coding work
- They don't record your conversations or send them anywhere new
- They don't restrict what you type — only what Claude is allowed to execute on your behalf

### Will I notice any difference?

For most tasks, no. The controls are designed to allow common, safe operations (reading code, running tests, making commits, opening pull requests) without interruption.

You may occasionally see Claude decline a request and explain why. When that happens, it will tell you which policy blocked it and suggest alternatives. If it declines something you think it should be able to do, see [What to do if Claude refuses something](#what-to-do-if-claude-refuses-something) below.

### What does Claude Code know about me?

Claude Code has access to the files and terminal on your machine, within the sandbox boundaries set by the governance controls. It does not have persistent memory between sessions by default. Your conversations with Claude Code are subject to Anthropic's data handling policies — the same as other Claude products used at MHI.

### What to do if Claude refuses something

If Claude refuses a request that you think it should be able to do:

1. **Check the reason** — Claude will tell you which rule blocked it. Common causes are commands that look like privilege escalation, accessing a restricted file path, or reaching a domain outside the approved list.
2. **Try a different approach** — Often the same outcome can be reached a different way. Claude will usually suggest an alternative.
3. **Request an exception** — If you have a legitimate use case that the current policy doesn't cover, you can request a policy change. See [Exception and escalation process](#exception-and-escalation-process) in this document.

### Who owns the governance controls?

The security and platform team at MHI owns the managed settings. Changes to the controls go through a formal review process. Individual engineers can add personal preferences (formatting, shortcuts) within the boundaries the managed layer sets, but they cannot remove or weaken the core controls.

**Contacts:**
- Policy questions or exception requests: max.levine@mhiuk.org or edward@mhiuk.org
- Technical issues with Claude Code (crashes, install problems): raise a ticket through the usual IT helpdesk

### Where can I learn more?

- [MHI AI Policy](https://www.mentalhealthinnovations.org) — the organisational policy this control pack implements
- [AI Governance GitHub repository](https://github.com/MentalHealthInnovations/AI_Governance) — the technical controls (for engineers and security team)
- Anthropic's [Claude Code documentation](https://docs.anthropic.com/en/docs/claude-code) — official product documentation

---

## Exception and escalation process

This section describes how to request a change to the Claude Code governance controls — either a permanent policy change or a time-limited exception.

### When to use this process

Use this process if:

- Claude Code refuses a command you need for legitimate work and no alternative approach exists
- Your team needs access to a domain or tool not currently on the approved list
- A project requires Claude to read a file type that the current controls restrict
- You believe a control is misconfigured and producing false positives

Do not use this process to work around controls you simply find inconvenient. The controls exist to protect MHI and its clients.

### Types of change

| Type | Description | Typical timeline |
|---|---|---|
| **Policy change** | Permanent update to managed settings, applied org-wide | 1–2 weeks (requires security review and testing) |
| **Allowlist addition** | Adding a domain, command, or file path to an approved list | 3–5 days |
| **Time-limited exception** | Temporary relaxation of a specific control for a defined project or date range | Case by case |

### How to request

#### Step 1 — Check whether an alternative exists

Before raising a request, verify there is no alternative approach. Claude Code will usually suggest one when it refuses a command. Many refusals can be resolved by:

- Rephrasing the request to use an approved command
- Using a different tool that is already on the approved list
- Asking Claude to generate the command for you to run manually

#### Step 2 — Raise a pull request

All policy changes are made through the [AI Governance repository](https://github.com/MentalHealthInnovations/AI_Governance) on GitHub. To submit a request:

1. Open a pull request against the `main` branch of the AI Governance repository
2. Use the PR template — it will prompt you for the required information, including a security risk assessment
3. Describe what you need, why you need it, and which users or machines it would apply to

If you're not comfortable raising a PR yourself, contact max.levine@mhiuk.org or edward@mhiuk.org and they can raise it on your behalf.

#### Step 3 — Review

The security team will assess the PR against:

- Whether the use case is covered by existing controls in a different way
- The risk of widening the control (could this be exploited by a prompt injection attack?)
- Whether an org-wide change is appropriate or whether a project-level setting is better

All changes to the repository require approval from both CODEOWNERS (@edwardmhi and @maxlevine-mhi) before they can be merged. You'll receive a response within **5 working days**. For urgent cases, flag this in the PR description.

#### Step 4 — Testing and deployment

Approved PRs are:

1. Tested with `/test-guardrails` before merge — this is a Claude Code skill defined in `.claude/skills/test-guardrails/SKILL.md`. Open Claude Code in the AI Governance repository working directory and type `/test-guardrails` at the prompt to run the full verification suite.
2. Merged to `main` by the security team
3. Deployed to managed machines via the next daily cron run (or immediately via `update_ai_governance` on affected machines)

You'll be notified once the change is live.

### Escalation

If your request is declined and you believe the decision is wrong, escalate to your line manager. They can raise it formally with the head of IT or security as appropriate.

### Frequently refused requests

| Request | Reason refused | Suggested alternative |
|---|---|---|
| Allow `curl` / `wget` | High-risk exfiltration vector | Use the `WebFetch` tool, which is subject to domain allowlisting |
| Allow `sudo` | Privilege escalation risk | Perform privileged operations outside of Claude Code |
| Allow access to `.env` files | High-risk credential exposure | Pass values as environment variables; don't put credentials in files Claude reads |
| Allow arbitrary domains | Network egress control | Submit a domain addition request — most legitimate domains can be added in a few days |
| Allow `--force` git flags | Destructive operation risk | Use non-destructive git workflows; Claude can help you achieve the same outcome safely |
