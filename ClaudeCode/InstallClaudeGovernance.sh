#!/usr/bin/env bash
#
# InstallClaudeGovernance.sh - Install MHI Claude Code governance policies on this machine.
#
# Run this script once as root (or with sudo) to:
#   1. Install /usr/local/bin/pull_claude_governance.sh, which pulls the latest policies
#      from the MentalHealthInnovations/AI_Governance GitHub repo.
#   2. Run that script immediately to apply the current policies.
#   3. Install /usr/local/bin/update_ai_governance, a setuid binary that allows any local
#      user to trigger a policy update without root access by running: update_ai_governance
#   4. Schedule a daily cron job (root crontab, 12:00) to keep policies up to date.
#
# Usage:
#   sudo ./InstallClaudeGovernance.sh              # bootstrap from main (production default)
#   sudo ./InstallClaudeGovernance.sh feat/branch  # bootstrap from a branch/tag/SHA for local testing
#
# The ref argument only affects the one-shot bootstrap deploy below. The installed
# pull_claude_governance.sh and the daily cron always pull main, and the setuid wrapper
# update_ai_governance accepts no arguments — so non-root users on this machine cannot
# switch the active policy branch after install.

set -e

ref="${1:-main}"

if ! xcode-select -p &> /dev/null ; then
  echo "Command Line Tools for Xcode not found. Installing from softwareupdate…"
  # This temporary file prompts the 'softwareupdate' utility to list the Command Line Tools
  SENTINEL=/tmp/.com.apple.dt.CommandLineTools.installondemand.in-progress
  touch "$SENTINEL"
  trap 'rm -f "$SENTINEL"' EXIT
  PROD=$(softwareupdate -l 2>/dev/null \
    | awk -F'*' '/^ *\*.*Command Line/ {print $2}' \
    | sed -E 's/^ *(Label: )?//' \
    | sort -V \
    | tail -n 1)
  if [[ -z "$PROD" ]]; then
    echo "Could not determine CLT package name" >&2
    exit 1
  fi
  sudo softwareupdate -i "$PROD" --verbose
else
  echo "Command Line Tools for Xcode are already installed."
fi

script_dest="/usr/local/bin/pull_claude_governance.sh"
ai_governance_repo_dir="/tmp/AI_Governance"

echo "Starting to pull Claude governance files."

# Bootstrap: clone the repo, copy pull_claude_governance.sh to /usr/local/bin/, then execute it.
# After this first install, pull_claude_governance.sh self-updates on every subsequent run —
# changes to it deploy automatically via the daily cron without requiring this script to be re-run.
echo "Cloning AI_Governance repository at ref '$ref'..."
rm -rf "$ai_governance_repo_dir"
# Verify the ref exists on the remote before cloning so a typo aborts here
# rather than after we have already started touching policy files.
remote_url="https://github.com/MentalHealthInnovations/AI_Governance"
if ! git ls-remote --exit-code "$remote_url" "$ref" >/dev/null 2>&1 \
  && ! git ls-remote --exit-code "$remote_url" "refs/heads/$ref" >/dev/null 2>&1 \
  && ! git ls-remote --exit-code "$remote_url" "refs/tags/$ref" >/dev/null 2>&1; then
  echo "Error: ref '$ref' not found on $remote_url" >&2
  echo "No changes made to /Library/Application Support/ClaudeCode/." >&2
  exit 1
fi
# --depth 1 with --branch works for both branches and tags. Falls back to a
# full clone + checkout for raw commit SHAs, which --branch does not accept.
if ! git clone --quiet --depth 1 --branch "$ref" "$remote_url" "$ai_governance_repo_dir" 2>/dev/null; then
  git clone --quiet "$remote_url" "$ai_governance_repo_dir"
  git -C "$ai_governance_repo_dir" checkout --quiet "$ref"
fi

echo "Installing pull script..."
sudo cp "$ai_governance_repo_dir/ClaudeCode/pull_claude_governance.sh" "$script_dest"
sudo chmod +x "$script_dest"

# Deploy policy files directly from the cloned ref. We do NOT invoke
# pull_claude_governance.sh here because that script unconditionally clones main,
# which would overwrite the just-deployed ref. The pull script is still installed
# above so the daily cron and update_ai_governance wrapper work as designed —
# both will pull main on their next run, which is the intended kill-switch when
# a test branch is bad.
claude_config_dir="/Library/Application Support/ClaudeCode/"
claude_hooks_dir="/opt/claude/hooks/"
echo "Deploying policy files from ref '$ref'..."
sudo mkdir -p "$claude_config_dir" "$claude_hooks_dir"
sudo cp "$ai_governance_repo_dir/ClaudeCode/managed-settings.json" "$claude_config_dir"
sudo cp "$ai_governance_repo_dir/ClaudeCode/managed-mcp.json" "$claude_config_dir"
sudo cp "$ai_governance_repo_dir/ClaudeCode/CLAUDE.md" "$claude_config_dir"
sudo cp "$ai_governance_repo_dir"/ClaudeCode/opt/claude/hooks/* "$claude_hooks_dir"
deployed_sha="$(git -C "$ai_governance_repo_dir" rev-parse HEAD)"
echo "$deployed_sha" | sudo tee "$claude_config_dir/VERSION" >/dev/null
rm -rf "$ai_governance_repo_dir"

echo "Installed governance files. Deployed version: $deployed_sha"

# Install a setuid wrapper binary so local users can trigger a governance update without root access.
# The wrapper executes pull_claude_governance.sh as root via the setuid bit, without granting users
# any ability to edit the script or the policy files it manages.
wrapper_dest="/usr/local/bin/update_ai_governance"
if command -v gcc &>/dev/null; then
    compiler="gcc"
else
    compiler="cc"
fi
sudo "$compiler" -x c -o "$wrapper_dest" - << 'EOF'
#include <unistd.h>
int main() {
    // Set real UID/GID to root so bash doesn't drop setuid privileges on exec
    if (setuid(0) != 0 || setgid(0) != 0) return 1;
    return execl("/usr/local/bin/pull_claude_governance.sh", "pull_claude_governance.sh", NULL);
}
EOF
sudo chown root:staff "$wrapper_dest"
# 4750 (setuid, rwx for owner, rx for group, none for others) restricts execution
# to members of the "staff" group rather than every local user (4755 = world-executable).
# This reduces the privilege-escalation surface: only users already in the group
# can trigger a root-level policy update on demand.
sudo chmod 4750 "$wrapper_dest"
echo "Installed update_ai_governance wrapper."

# cron_marker used to detect if the crontab already exists, and only add it if it doesn't
cron_marker="# Added by MHI Claude governance script - see MHI_Device_Builds repository."
new_crontab="0 12 * * * $script_dest $cron_marker"
# don't raise an error if the crontab is empty, which is the case if the user has no crontab yet
existing_crontab=$(sudo crontab -l 2>/dev/null || true)

updated_crontab=$(echo "$existing_crontab" | grep -vF "$cron_marker")
echo "Adding crontab to update governance files daily."
(echo "$updated_crontab" ; echo "$new_crontab") | sudo crontab -

echo "Script completed successfully."