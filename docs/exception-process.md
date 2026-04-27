# Exception and escalation process

This document describes how to request a change to the Claude Code governance controls — either a permanent policy change or a time-limited exception.

## When to use this process

Use this process if:

- Claude Code refuses a command you need for legitimate work and no alternative approach exists
- Your team needs access to a domain or tool not currently on the approved list
- A project requires Claude to read a file type that the current controls restrict
- You believe a control is misconfigured and producing false positives

Do not use this process to work around controls you simply find inconvenient. The controls exist to protect MHI and its clients.

## Types of change

| Type | Description | Typical timeline |
|---|---|---|
| **Policy change** | Permanent update to managed settings, applied org-wide | 1–2 weeks (requires security review and testing) |
| **Allowlist addition** | Adding a domain, command, or file path to an approved list | 3–5 days |
| **Time-limited exception** | Temporary relaxation of a specific control for a defined project or date range | Case by case |

## How to request

### Step 1 — Check whether an alternative exists

Before raising a request, verify there is no alternative approach. Claude Code will usually suggest one when it refuses a command. Many refusals can be resolved by:

- Rephrasing the request to use an approved command
- Using a different tool that is already on the approved list
- Asking Claude to generate the command for you to run manually

### Step 2 — Raise a pull request

All policy changes are made through the [AI Governance repository](https://github.com/MentalHealthInnovations/AI_Governance) on GitHub. To submit a request:

1. Open a pull request against the `main` branch of the AI Governance repository
2. Use the PR template — it will prompt you for the required information, including a security risk assessment
3. Describe what you need, why you need it, and which users or machines it would apply to

If you're not comfortable raising a PR yourself, contact max.levine@mhiuk.org or edward@mhiuk.org and they can raise it on your behalf.

### Step 3 — Review

The security team will assess the PR against:

- Whether the use case is covered by existing controls in a different way
- The risk of widening the control (could this be exploited by a prompt injection attack?)
- Whether an org-wide change is appropriate or whether a project-level setting is better

All changes to the repository require approval from both CODEOWNERS (@edwardmhi and @maxlevine-mhi) before they can be merged. You'll receive a response within **5 working days**. For urgent cases, flag this in the PR description.

### Step 4 — Testing and deployment

Approved PRs are:

1. Tested with `/test-guardrails` before merge — this is a Claude Code skill defined in `.claude/skills/test-guardrails/SKILL.md`. Open Claude Code in the AI Governance repository working directory and type `/test-guardrails` at the prompt to run the full verification suite.
2. Merged to `main` by the security team
3. Deployed to managed machines via the next daily cron run (or immediately via `update_ai_governance` on affected machines)

You'll be notified once the change is live.

## Escalation

If your request is declined and you believe the decision is wrong, escalate to your line manager. They can raise it formally with the head of IT or security as appropriate.

## Frequently refused requests

| Request | Reason refused | Suggested alternative |
|---|---|---|
| Allow `curl` / `wget` | High-risk exfiltration vector | Use the `WebFetch` tool, which is subject to domain allowlisting |
| Allow `sudo` | Privilege escalation risk | Perform privileged operations outside of Claude Code |
| Allow access to `.env` files | High-risk credential exposure | Pass values as environment variables; don't put credentials in files Claude reads |
| Allow arbitrary domains | Network egress control | Submit a domain addition request — most legitimate domains can be added in a few days |
| Allow `--force` git flags | Destructive operation risk | Use non-destructive git workflows; Claude can help you achieve the same outcome safely |
