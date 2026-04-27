# Claude Code at MHI — What's changing and what to expect

## What is Claude Code?

Claude Code is an AI assistant that works directly inside your code editor or terminal. You can ask it to explain code, write tests, review a pull request, or help you debug a problem. It works by reading files on your machine and running commands on your behalf — which is why we need guardrails around it.

## What are the guardrails?

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

## Will I notice any difference?

For most tasks, no. The controls are designed to allow common, safe operations (reading code, running tests, making commits, opening pull requests) without interruption.

You may occasionally see Claude decline a request and explain why. When that happens, it will tell you which policy blocked it and suggest alternatives. If it declines something you think it should be able to do, see [What to do if Claude refuses something](#what-to-do-if-claude-refuses-something) below.

## What does Claude Code know about me?

Claude Code has access to the files and terminal on your machine, within the sandbox boundaries set by the governance controls. It does not have persistent memory between sessions by default. Your conversations with Claude Code are subject to Anthropic's data handling policies — the same as other Claude products used at MHI.

## What to do if Claude refuses something

If Claude refuses a request that you think it should be able to do:

1. **Check the reason** — Claude will tell you which rule blocked it. Common causes are commands that look like privilege escalation, accessing a restricted file path, or reaching a domain outside the approved list.
2. **Try a different approach** — Often the same outcome can be reached a different way. Claude will usually suggest an alternative.
3. **Request an exception** — If you have a legitimate use case that the current policy doesn't cover, you can request a policy change. See the [exception process](exception-process.md).

## Who owns the governance controls?

The security and platform team at MHI owns the managed settings. Changes to the controls go through a formal review process. Individual engineers can add personal preferences (formatting, shortcuts) within the boundaries the managed layer sets, but they cannot remove or weaken the core controls.

**Contacts:**
- Policy questions or exception requests: max.levine@mhiuk.org or edward@mhiuk.org
- Technical issues with Claude Code (crashes, install problems): raise a ticket through the usual IT helpdesk

## Where can I learn more?

- [MHI AI Policy](https://www.mentalhealthinnovations.org) — the organisational policy this control pack implements
- [AI Governance GitHub repository](https://github.com/MentalHealthInnovations/AI_Governance) — the technical controls (for engineers and security team)
- Anthropic's [Claude Code documentation](https://docs.anthropic.com/en/docs/claude-code) — official product documentation
