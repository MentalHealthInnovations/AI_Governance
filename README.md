# Claude Code — AI Agent Governance Control Pack

This control pack provides a layered configuration system for Claude Code, designed to make it safer and smoother to use at the same time. The objective is not to prompt more often. The objective is to prompt less often, but only after the environment has already removed the riskiest options.

## File manifest

| File | Purpose |
|------|---------|
| `ClaudeCode/managed-settings.json` | Org-wide immutable guardrails (Layer 1) |
| `ClaudeCode/CLAUDE.md` | Behavioural guidance for Claude Code agents |
| `ClaudeCode/__user__settings.json` | Example developer-level preferences (Layer 2) |
| `ClaudeCode/__repo__settings.json` | Example team-wide project defaults (Layer 3) |
| `ClaudeCode/settings.local.json` | Example personal project overrides (Layer 4) |
| `ClaudeCode/control_mappings.csv` | Mapping of controls to ISO 42001 / NIST AI RMF |
| `ClaudeCode/opt/claude/hooks/bash-policy-check.sh` | Pre-execution policy hook for bash commands |
| `ClaudeCode/opt/claude/hooks/webfetch-policy-check.sh` | Pre-execution policy hook for WebFetch calls |
| `ClaudeCode/opt/claude/hooks/output-redact.sh` | Post-execution output redaction hook for Bash, Read, and WebFetch |
| `ClaudeCode/InstallClaudeGovernance.sh` | Installation script for macOS |

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

Claude Code uses a four-layer configuration system. Higher layers take precedence over lower ones. Settings are merged top-down, so a rule defined at the managed level cannot be overridden by any layer below it.

```mermaid
flowchart LR
L1["**Managed settings**
<code>managed-settings.json</code><br>
Immutable, org-wide guardrails, deployed via MDM.<br>
**Owns**: sandbox policy, approved MCP servers, credential deny rules, hooks"]
L2["**User settings**
<code>~/.claude/settings.json</code><br>
 Persistent across all projects on this machine.<br>
 **Owns**: formatting prefs, personal global allowlists"]
 L3["**Shared project settings**
<code>.claude/settings.json</code> (verion-controlled)<br>
 Team-wide defaults that travel with the repo.<br>
 **Owns**: project task automation, shared prompt templates
 "]
 L4["**Local project settings **
 <code>.claude/settings.local.json</code> (git-ignored)<br>
 Personal overrides for a single project.<br>
 **Owns**: plan-mode testing, debug verbosity "]
L1-->| overrides |L2
L2-->| overrides |L3
L3-->| overrides |L4

```

Deny rules are cumulative — a deny at any layer cannot be undone by an allow at a lower layer.

### Layer 1 — Managed Settings (Organisation)

This is the security boundary. It defines rules that no individual developer or project can weaken: network egress controls, credential-path deny rules, approved MCP servers, sandbox policy, and hooks that must always run. Developers cannot edit this file.

### Layer 2 — User Settings (Developer)

**File:** `~/.claude/settings.json`

Persistent preferences that follow a developer across every project on their machine. Use for personal formatting preferences, editor integration settings, or additional allow rules within the boundaries set by the managed layer. Never committed to any repository.

### Layer 3 — Shared Project Settings (Team)

**File:** `.claude/settings.json` — committed to the repository.

Team-wide defaults that travel with the codebase: project-specific task automation, shared prompt templates, or additional permission rules the team has agreed on. Changes go through normal code review.

### Layer 4 — Local Project Settings (Individual)

**File:** `.claude/settings.local.json` — git-ignored.

Personal overrides scoped to a single project. Use for plan-mode testing, verbose output during debugging, or temporary configuration that shouldn't affect the team.

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

**`output-redact.sh`** runs after every Bash, Read, and WebFetch call. It scans the tool output for API keys, credentials, and other sensitive values, replacing matches with `[REDACTED]` before the content reaches Claude's context window. Each redaction is logged (pattern name and first six characters of the match) for audit purposes — the full value is never written to the log. Patterns covered include: PEM blocks, AWS access key IDs and secret keys, GitHub PATs (classic and fine-grained), OpenAI/Anthropic `sk-` keys, Slack tokens, JWTs, Bearer headers, generic `key=value` / `password=value` env assignments, and Stripe/Twilio/SendGrid vendor keys.

Hooks are deployed to `/opt/claude/hooks/` by the install script and must be present before Claude Code is used. If a hook is missing or fails, the operation is blocked (`failIfUnavailable: true` in sandbox settings).

## Operating model

Start with a small set of strong deny rules and a useful set of low-risk allow rules.

Use approval and denial telemetry to tune the middle layer over time:
- Promote repetitive safe asks into allow.
- Keep hard deny rules small, stable, and explicit.
- Avoid creating so many prompts that users stop reading them carefully.

## Change control

### Security / platform team

Own: `managed-settings.json`, `CLAUDE.md`, managed hooks, sandbox policy, approved domains and MCP servers.

### Repository maintainers

Own: `.claude/settings.json`, repo-local safe task automation, repo-specific low-risk allowlists.

### Individual engineers

Own: `~/.claude/settings.json`, `.claude/settings.local.json`.

Engineers may improve convenience inside the rails, but they do not control the rails.

## Governance alignment

`control_mappings.csv` maps all controls to ISO 42001 AI management system requirements and NIST AI RMF, as well as OWASP LLM risks (LLM01 Prompt Injection, LLM02 Insecure Output, LLM06 Sensitive Info Disclosure, LLM08 Excessive Agency).
