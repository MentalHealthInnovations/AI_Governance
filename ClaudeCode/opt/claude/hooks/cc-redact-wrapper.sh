#!/usr/bin/env bash
set -euo pipefail

payload="$(cat)"

# Pass the hook payload to cc-redact.
# Adjust the executable name and arguments to match your internal packaging standard.
# Keep the wrapper org-owned even if the underlying tool is third-party.
printf '%s' "$payload" | /usr/local/bin/cc-redact
