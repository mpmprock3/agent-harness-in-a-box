#!/bin/bash
# Configure a sandbox with HTTP API access to a jumpbox and clone skill repos.
# Run AFTER setup-sandbox.sh has created the sandbox.
#
# This script dynamically updates the network policy to allow HTTP to the
# jumpbox IP, so different users can point to different jumpboxes without
# editing the policy template.
#
# Usage:
#   bash setup-jumpbox-api.sh [sandbox-name]
#
# Required env vars:
#   JUMPBOX_HOST       - Jumpbox hostname or IP (e.g., x.x.x.x)
#   JUMPBOX_TOKEN      - Bearer token for jumpbox API authentication
#
# Optional:
#   JUMPBOX_PORT       - API port (default: 8443)
#   SKILLS_REPO        - Git URL for skills repo (default: https://github.com/mpmprock3/ai-platform-skills.git)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
source "$REPO_ROOT/common/functions.sh"

SANDBOX_NAME="${1:-opencode-demo}"
JUMPBOX_PORT="${JUMPBOX_PORT:-8443}"
SKILLS_REPO="${SKILLS_REPO:-https://github.com/mpmprock3/ai-platform-skills.git}"

if [ -z "${JUMPBOX_HOST:-}" ]; then
    error "JUMPBOX_HOST not set. Export it before running this script."
    exit 1
fi
if [ -z "${JUMPBOX_TOKEN:-}" ]; then
    error "JUMPBOX_TOKEN not set. Export it before running this script."
    exit 1
fi

# Load .env for LITELLM_HOST and OCP_APPS_DOMAIN (needed to re-render policy)
if [ -f "$REPO_ROOT/.env" ]; then
    source "$REPO_ROOT/.env"
fi
LITELLM_HOST=$(echo "${LITELLM_BASE_URL:-}" | sed -E 's|https?://||;s|/.*||')
export LITELLM_HOST
export JUMPBOX_HOST

step "Re-render network policy with jumpbox API access"
POLICY_TIER="${POLICY_TIER:-standard}"
POLICY_TEMPLATE="$SCRIPT_DIR/config/policy-${POLICY_TIER}.yaml.template"
RENDERED_POLICY="/tmp/policy-${POLICY_TIER}-rendered.yaml"
if [ -f "$POLICY_TEMPLATE" ]; then
    render_policy "$POLICY_TEMPLATE" "$RENDERED_POLICY" "${OCP_APPS_DOMAIN:-apps.example.com}"
    info "Policy rendered with JUMPBOX_HOST=$JUMPBOX_HOST"
else
    error "Policy template not found: $POLICY_TEMPLATE"
    exit 1
fi

step "Apply updated network policy (hot-reload)"
openshell policy set --policy "$RENDERED_POLICY" --wait "$SANDBOX_NAME"
info "Network policy updated — HTTP to $JUMPBOX_HOST:$JUMPBOX_PORT is now allowed"

step "Set jumpbox environment variables in sandbox"
openshell sandbox exec --name "$SANDBOX_NAME" -- sh -c "
    sed -i '/JUMPBOX_HOST/d; /JUMPBOX_PORT/d; /JUMPBOX_TOKEN/d; /Jumpbox API config/d' /sandbox/.profile 2>/dev/null || true
    cat >> /sandbox/.profile <<'VARS'

# Jumpbox API config
export JUMPBOX_HOST=\"$JUMPBOX_HOST\"
export JUMPBOX_PORT=\"$JUMPBOX_PORT\"
export JUMPBOX_TOKEN=\"$JUMPBOX_TOKEN\"
VARS
"

step "Test API connectivity to jumpbox"
RESULT=$(openshell sandbox exec --name "$SANDBOX_NAME" -- \
    curl -s --max-time 10 "http://${JUMPBOX_HOST}:${JUMPBOX_PORT}/health" 2>&1 | grep -oE '\{.*\}' | head -1 || true)

if echo "$RESULT" | grep -q '"status"'; then
    info "API connectivity verified: $RESULT"
else
    warn "API test returned: $RESULT"
    warn "Check: (1) jumpbox API is running (plain HTTP, not HTTPS), (2) security group allows port $JUMPBOX_PORT, (3) network policy is applied"
    warn "Continuing with setup — fix connectivity before using OpenCode"
fi

step "Clone skills repository into sandbox"
openshell sandbox exec --name "$SANDBOX_NAME" -- \
    bash -c "rm -rf /workspace/skills; git clone $SKILLS_REPO /workspace/skills 2>&1 | tail -1 && echo OK"

step "Upload jumpbox instructions for OpenCode"
openshell sandbox exec --name "$SANDBOX_NAME" -- mkdir -p /workspace/.opencode
# Upload instructions via base64 (openshell sandbox upload is unreliable)
INSTRUCTIONS_B64=$(base64 < "$SCRIPT_DIR/config/jumpbox-instructions.md")
openshell sandbox exec --name "$SANDBOX_NAME" -- bash -c "echo '${INSTRUCTIONS_B64}' | base64 -d > /workspace/.opencode/instructions.md"
# Verify upload
INSTR_VERIFY=$(openshell sandbox exec --name "$SANDBOX_NAME" -- head -1 /workspace/.opencode/instructions.md 2>&1 | grep -oE '#' | wc -l || true)
if [ "${INSTR_VERIFY:-0}" -ge 1 ]; then
    info "Instructions uploaded to /workspace/.opencode/instructions.md"
else
    warn "Instructions upload may have failed — retrying via openshell upload"
    openshell sandbox exec --name "$SANDBOX_NAME" -- rm -f /workspace/.opencode/instructions.md
    openshell sandbox upload "$SANDBOX_NAME" "$SCRIPT_DIR/config/jumpbox-instructions.md" /workspace/.opencode/
    openshell sandbox exec --name "$SANDBOX_NAME" -- \
        mv /workspace/.opencode/jumpbox-instructions.md /workspace/.opencode/instructions.md 2>/dev/null || true
fi

step "Copy instructions to AGENTS.md (OpenCode 1.17+ reads from workspace root)"
openshell sandbox exec --name "$SANDBOX_NAME" -- \
    cp /workspace/.opencode/instructions.md /workspace/AGENTS.md
openshell sandbox exec --name "$SANDBOX_NAME" -- bash -c '
    cd /workspace
    git add -A 2>/dev/null
    git commit -m "add skills and jumpbox instructions" 2>/dev/null || true
'
info "Instructions available at /workspace/AGENTS.md (OpenCode 1.17+) and /workspace/.opencode/instructions.md"

step "Verify skills are available"
openshell sandbox exec --name "$SANDBOX_NAME" -- ls /workspace/skills/

echo ""
echo "============================================"
echo " Jumpbox API configured for '$SANDBOX_NAME'"
echo "============================================"
echo ""
echo " Jumpbox:      http://${JUMPBOX_HOST}:${JUMPBOX_PORT}"
echo " Auth:         Bearer token set in sandbox env"
echo " Skills:       /workspace/skills/"
echo " Instructions: /workspace/.opencode/instructions.md"
echo ""
echo " Network policy updated to allow HTTP to $JUMPBOX_HOST:$JUMPBOX_PORT"
echo " To change the jumpbox, re-run with a different JUMPBOX_HOST."
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
