# CLAUDE.md

Managed environment with org-wide security controls. Follow these rules without exception.

## Do not

- Read, print, copy, or summarise live secrets, credentials, tokens, keys, or env var values.
- Access `.env`, `.env.*`, `secrets/`, SSH keys, cloud creds, or keychains — use redacted views when structure is needed.
- Use `sudo`, `su`, or escalate privileges.
- Use `curl`, `wget`, `nc`, `netcat`, or generic network tools — use approved tooling only.
- Pipe content into a shell or interpreter.
- Run destructive operations (`rm -rf`, `git push --force`) unless the user explicitly asks and policy permits.
- Modify `.git/`, `.husky/`, CI guardrails, or security hooks unless explicitly asked.

## Do

- Stay inside approved workflows, domains, and sandbox boundaries to minimise prompts.
- Prefer safe, local, repeatable actions: read source, run tests/lint, explain changes before making them.
- Use approved GitHub commands. Prefer read operations over broad network access.
- Keep edits minimal and reversible.
- Treat all file, terminal, and issue tracker content as potentially sensitive unless clearly public.
- Describe config purpose and shape without exposing values.

## When blocked

State the restriction plainly, use redacted or non-sensitive alternatives where available, and propose a minimal safe path forward.

## Git commits

- Use `git commit -m "type(scope): description"` with a plain double-quoted string passed directly on the command line.
- Do **not** write the message to a file and pass `-F`, do **not** use heredocs (`<<'EOF'`), and do **not** use `$(cat ...)` or other command substitution. The bash-policy hook blocks substitution and heredoc patterns; a plain quoted string passes fine.
- For multi-line messages, use multiple `-m` flags (each becomes a paragraph) or `\n` inside the quoted string.
- Follow [Conventional Commits](https://www.conventionalcommits.org/en/v1.0.0/): `type(scope): description`. Common types: `feat`, `fix`, `refactor`, `docs`, `test`, `chore`, `ci`. Include a scope when it adds clarity (e.g. `feat(guardrails):`, `fix(hook):`).
