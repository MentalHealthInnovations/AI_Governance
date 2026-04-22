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

echo "Starting to pull Claude governance files."

# Create a script to pull the latest governance files, to be run by crontab and when this script is run
sudo tee "$script_dest" > /dev/null << 'EOF'
#!/usr/bin/env bash

set -e

claude_config_dir="/Library/Application Support/ClaudeCode/"
claude_hooks_dir="/opt/claude/hooks/"
ai_governance_repo_dir="/tmp/AI_Governance"

echo "Creating directories..."
mkdir -p "$claude_config_dir" "$claude_hooks_dir"

echo "Cloning AI_Governance repository..."
rm -rf "$ai_governance_repo_dir"
git clone --quiet https://github.com/MentalHealthInnovations/AI_Governance "$ai_governance_repo_dir"

echo "Copying managed-settings.json..."
cp "$ai_governance_repo_dir/ClaudeCode/managed-settings.json" "$claude_config_dir"

echo "Copying CLAUDE.md..."
cp "$ai_governance_repo_dir/ClaudeCode/CLAUDE.md" "$claude_config_dir"

echo "Copying hooks..."
cp "$ai_governance_repo_dir"/ClaudeCode/opt/claude/hooks/* "$claude_hooks_dir"

echo "Cleaning up..."
rm -rf "$ai_governance_repo_dir"

echo "Governance files updated successfully."
EOF

echo "Created script to pull governance files."

# Run the created script
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
    setuid(0);
    setgid(0);
    return execl("/usr/local/bin/pull_claude_governance.sh", "pull_claude_governance.sh", NULL);
}
EOF
sudo chown root "$wrapper_dest"
sudo chmod 4755 "$wrapper_dest"
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