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

set -e

script_dest="/usr/local/bin/pull_claude_governance.sh"
ai_governance_repo_dir="/tmp/AI_Governance"

echo "Starting to pull Claude governance files."

# Bootstrap: clone the repo, copy pull_claude_governance.sh to /usr/local/bin/, then execute it.
# After this first install, pull_claude_governance.sh self-updates on every subsequent run —
# changes to it deploy automatically via the daily cron without requiring this script to be re-run.
echo "Cloning AI_Governance repository..."
rm -rf "$ai_governance_repo_dir"
git clone --quiet --depth 1 https://github.com/MentalHealthInnovations/AI_Governance "$ai_governance_repo_dir"

echo "Installing pull script..."
sudo cp "$ai_governance_repo_dir/ClaudeCode/pull_claude_governance.sh" "$script_dest"
sudo chmod +x "$script_dest"
rm -rf "$ai_governance_repo_dir"

echo "Created script to pull governance files."

# Run the installed script to deploy all policy files
sudo "$script_dest"

echo "Installed governance files."

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
sudo chown root "$wrapper_dest"
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