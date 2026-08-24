#!/bin/bash
# Configure a sandbox with SSH access to a jumpbox and clone skill repos.
# Run AFTER setup-sandbox.sh has created the sandbox.
#
# Usage:
#   bash setup-jumpbox-ssh.sh [sandbox-name]
#
# Required env vars:
#   JUMPBOX_HOST       - Jumpbox hostname or IP (e.g., ec2-1-2-3-4.compute.amazonaws.com)
#   JUMPBOX_USER       - SSH username (e.g., ec2-user)
#   JUMPBOX_KEY_PATH   - Path to SSH private key on your local machine
#
# Optional:
#   SKILLS_REPO        - Git URL for skills repo (default: https://github.com/mpmprock3/ai-platform-skills.git)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
source "$REPO_ROOT/common/functions.sh"

SANDBOX_NAME="${1:-opencode-demo}"
SKILLS_REPO="${SKILLS_REPO:-https://github.com/mpmprock3/ai-platform-skills.git}"

if [ -z "${JUMPBOX_HOST:-}" ]; then
    error "JUMPBOX_HOST not set. Export it before running this script."
    exit 1
fi
if [ -z "${JUMPBOX_USER:-}" ]; then
    error "JUMPBOX_USER not set. Export it before running this script."
    exit 1
fi
if [ -z "${JUMPBOX_KEY_PATH:-}" ]; then
    error "JUMPBOX_KEY_PATH not set. Point it to your SSH private key file."
    exit 1
fi
if [ ! -f "$JUMPBOX_KEY_PATH" ]; then
    error "SSH key file not found: $JUMPBOX_KEY_PATH"
    exit 1
fi

step "Upload SSH private key to sandbox"
openshell sandbox exec --name "$SANDBOX_NAME" -- mkdir -p /sandbox/.ssh
openshell sandbox upload "$SANDBOX_NAME" "$JUMPBOX_KEY_PATH" /sandbox/.ssh/jumpbox_key
openshell sandbox exec --name "$SANDBOX_NAME" -- chmod 600 /sandbox/.ssh/jumpbox_key

step "Set jumpbox environment variables"
openshell sandbox exec --name "$SANDBOX_NAME" -- sh -c "
    grep -q JUMPBOX_HOST /sandbox/.profile 2>/dev/null || cat >> /sandbox/.profile <<'VARS'

# Jumpbox SSH config
export JUMPBOX_HOST=\"$JUMPBOX_HOST\"
export JUMPBOX_USER=\"$JUMPBOX_USER\"
VARS
"

step "Test SSH connectivity to jumpbox"
RESULT=$(openshell sandbox exec --name "$SANDBOX_NAME" -- \
    ssh -i /sandbox/.ssh/jumpbox_key -o StrictHostKeyChecking=no -o ConnectTimeout=10 \
    "${JUMPBOX_USER}@${JUMPBOX_HOST}" 'echo "OK: $(hostname)"' 2>&1 | grep -v "Using sandbox" | tail -1)

if echo "$RESULT" | grep -q "^OK:"; then
    info "SSH connectivity verified: $RESULT"
else
    warn "SSH test failed: $RESULT"
    warn "Check that the jumpbox is reachable and the network policy allows SSH (port 22)"
fi

step "Clone skills repository into sandbox"
openshell sandbox exec --name "$SANDBOX_NAME" -- \
    git clone "$SKILLS_REPO" /workspace/skills 2>&1 | tail -3

step "Upload jumpbox instructions for OpenCode"
openshell sandbox upload "$SANDBOX_NAME" \
    "$SCRIPT_DIR/config/jumpbox-instructions.md" \
    /workspace/.opencode/instructions.md

step "Verify skills are available"
openshell sandbox exec --name "$SANDBOX_NAME" -- ls /workspace/skills/

echo ""
echo "============================================"
echo " Jumpbox SSH configured for '$SANDBOX_NAME'"
echo "============================================"
echo ""
echo " Jumpbox:     ${JUMPBOX_USER}@${JUMPBOX_HOST}"
echo " SSH key:     /sandbox/.ssh/jumpbox_key"
echo " Skills:      /workspace/skills/"
echo " Instructions: /workspace/.opencode/instructions.md"
echo ""
echo " Connect and use:"
echo "   openshell sandbox connect $SANDBOX_NAME"
echo "   opencode"
echo ""
echo " Example prompts:"
echo '   "Create a ROSA cluster called dev-trading in us-east-1 with 2 nodes"'
echo '   "Install OpenShift AI on the dev-trading cluster"'
echo '   "Deploy granite-3.1-2b model as a service"'
echo ""
