#!/bin/bash
# Setup an OpenCode sandbox with LiteLLM inference and RHOAI MLflow tracing.
# Requires Demo 2 infrastructure (Keycloak OIDC) already deployed via install.sh.
#
# Usage:
#   bash setup-sandbox.sh [sandbox-name]
#
# Environment:
#   SANDBOX_IMAGE  - Pre-baked image URL. When set, creates sandbox with --from
#                    and skips runtime install. Example:
#                    SANDBOX_IMAGE=quay.io/rcarrata/agentic-harness-openshell:opencode-v1 bash setup-sandbox.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
source "$REPO_ROOT/common/functions.sh"

SANDBOX_NAME="${1:-opencode-demo}"

if [ ! -f "$REPO_ROOT/.env" ]; then
    error "Missing .env file. Copy .env.example to .env and fill in your credentials."
    exit 1
fi
source "$REPO_ROOT/.env"

if [ -z "${LITELLM_API_KEY:-}" ]; then
    error "LITELLM_API_KEY not set in .env"
    exit 1
fi

export PATH="$HOME/bin:$PATH"

OCP_TOKEN=$(oc whoami -t 2>/dev/null || true)
if [ -z "$OCP_TOKEN" ]; then
    warn "Not logged into OpenShift - MLflow tracing will not work"
fi

# Sandbox-accessible MLflow URI (external route, not internal svc)
MLFLOW_SANDBOX_URI="https://mlflow-redhat-ods-applications.${OCP_APPS_DOMAIN}"

LITELLM_HOST=$(echo "${LITELLM_BASE_URL}" | sed -E 's|https?://||;s|/.*||')
export LITELLM_HOST

step "Render network policy (tier: ${POLICY_TIER:-standard})"
POLICY_TIER="${POLICY_TIER:-standard}"
POLICY_TEMPLATE="$SCRIPT_DIR/config/policy-${POLICY_TIER}.yaml.template"
if [ ! -f "$POLICY_TEMPLATE" ] && [ -f "$SCRIPT_DIR/config/policy-${POLICY_TIER}.yaml" ]; then
    POLICY_TEMPLATE="$SCRIPT_DIR/config/policy-${POLICY_TIER}.yaml"
fi
RENDERED_POLICY="/tmp/policy-${POLICY_TIER}-rendered.yaml"
if [[ "$POLICY_TEMPLATE" == *.template ]]; then
    render_policy "$POLICY_TEMPLATE" "$RENDERED_POLICY" "$OCP_APPS_DOMAIN"
else
    cp "$POLICY_TEMPLATE" "$RENDERED_POLICY"
fi

step "Register LiteLLM provider"
openshell provider delete litellm 2>/dev/null || true
openshell provider create \
    --name litellm \
    --type openai \
    --credential "OPENAI_API_KEY=${LITELLM_API_KEY}" \
    --config "base_url=${LITELLM_BASE_URL}"

step "Configure inference routing (optional)"
openshell inference set --provider litellm --model "${LITELLM_MODEL:-gemini-2.5-pro}" --no-verify 2>/dev/null \
    && info "User inference route set" \
    || warn "inference set not supported by this gateway version - OpenCode uses direct OPENAI_BASE_URL"
openshell inference set --provider litellm --model "${LITELLM_MODEL_SMALL:-llama-scout-17b}" --system --no-verify 2>/dev/null \
    && info "System inference route set" \
    || true

step "Create sandbox: $SANDBOX_NAME"
openshell sandbox delete "$SANDBOX_NAME" 2>/dev/null || true
sleep 3
if [ -n "${SANDBOX_IMAGE:-}" ]; then
    info "Using pre-baked image: $SANDBOX_IMAGE"
    openshell sandbox create --name "$SANDBOX_NAME" --from "$SANDBOX_IMAGE" --policy "$RENDERED_POLICY"
else
    openshell sandbox create --name "$SANDBOX_NAME" --policy "$RENDERED_POLICY"
fi

step "Wait for sandbox to be ready"
for i in $(seq 1 30); do
    STATUS=$(openshell sandbox list 2>/dev/null | grep "$SANDBOX_NAME" | sed 's/\x1b\[[0-9;]*m//g' | awk '{print $NF}')
    if [ "$STATUS" = "Ready" ]; then
        info "Sandbox is Ready"
        break
    fi
    if [ "$i" -eq 30 ]; then
        error "Sandbox did not become Ready within 150s"
        exit 1
    fi
    sleep 5
done

step "Apply network policy (tier: $POLICY_TIER)"
openshell policy set --policy "$RENDERED_POLICY" --wait "$SANDBOX_NAME"

if [ -z "${SANDBOX_IMAGE:-}" ]; then
    step "Install OpenCode in sandbox"
    openshell sandbox exec --name "$SANDBOX_NAME" -- bash -c 'mkdir -p /sandbox/.npm-global && export npm_config_prefix=/sandbox/.npm-global && npm install -g opencode-ai 2>&1 | tail -3'
else
    step "Verify OpenCode in sandbox"
    openshell sandbox exec --name "$SANDBOX_NAME" -- opencode --version
fi

step "Initialize workspace git repo (required by OpenCode)"
openshell sandbox exec --name "$SANDBOX_NAME" -- bash -c '
    cd /workspace
    if [ ! -d .git ]; then
        git config --global --add safe.directory /workspace
        git init
        git config user.email "sandbox@opencode.local"
        git config user.name "Sandbox"
        echo "# OpenCode Workspace" > README.md
        git add README.md
        git commit -m "init workspace" 2>/dev/null
    fi
' 2>&1 | tail -3
info "Workspace git repo ready"

step "Upload OpenCode config"
RENDERED_CONFIG="/tmp/opencode-config-rendered.json"
sed "s|\${LITELLM_BASE_URL}|${LITELLM_BASE_URL}|g; s|\${LITELLM_MODEL}|${LITELLM_MODEL:-gpt-oss-120b}|g; s|\${LITELLM_MODEL_SMALL}|${LITELLM_MODEL_SMALL:-llama-scout-17b}|g" \
    "$SCRIPT_DIR/config/opencode-config.json" > "$RENDERED_CONFIG"
openshell sandbox exec --name "$SANDBOX_NAME" -- mkdir -p /workspace/.opencode /sandbox/.config/opencode
CONFIG_B64=$(base64 < "$RENDERED_CONFIG")
openshell sandbox exec --name "$SANDBOX_NAME" -- bash -c "echo '${CONFIG_B64}' | base64 -d > /workspace/.opencode/config.json"
VERIFY=$(openshell sandbox exec --name "$SANDBOX_NAME" -- head -1 /workspace/.opencode/config.json 2>&1 | grep -c '{' || true)
if [ "$VERIFY" -ge 1 ]; then
    info "OpenCode config uploaded to /workspace/.opencode/config.json"
else
    error "Failed to write OpenCode config"
    exit 1
fi

step "Copy config to OpenCode 1.17+ paths"
openshell sandbox exec --name "$SANDBOX_NAME" -- bash -c '
    mkdir -p /sandbox/.config/opencode
    # OpenCode 1.17+ reads opencode.jsonc from ~/.config/opencode/ and workspace root
    cp /workspace/.opencode/config.json /sandbox/.config/opencode/opencode.jsonc 2>/dev/null
    cp /workspace/.opencode/config.json /workspace/opencode.jsonc 2>/dev/null
    # Remove MLflow plugin from startup (slows loading; re-add if MLflow is configured)
    sed -i "/plugin/d" /sandbox/.config/opencode/opencode.jsonc 2>/dev/null
    sed -i "/plugin/d" /workspace/opencode.jsonc 2>/dev/null
'
info "Config copied to ~/.config/opencode/opencode.jsonc and /workspace/opencode.jsonc"

step "Set credentials and environment in sandbox"
openshell sandbox exec --name "$SANDBOX_NAME" -- bash -c "
sed -i '/OPENAI_API_KEY/d; /OPENAI_BASE_URL/d; /MLFLOW_TRACKING/d; /MLFLOW_EXPERIMENT/d; /MLFLOW_WORKSPACE/d; /NODE_TLS_REJECT/d; /npm_config_prefix/d; /npm-global/d; /LiteLLM credentials/d; /sandbox env/d; /OpenCode path/d; /RHOAI MLflow/d' /sandbox/.profile 2>/dev/null
echo '' >> /sandbox/.profile
echo '# LiteLLM credentials' >> /sandbox/.profile
echo 'export OPENAI_API_KEY=\"${LITELLM_API_KEY}\"' >> /sandbox/.profile
echo 'export OPENAI_BASE_URL=\"${LITELLM_BASE_URL}\"' >> /sandbox/.profile
echo '# RHOAI MLflow tracing' >> /sandbox/.profile
echo 'export MLFLOW_TRACKING_URI=\"${MLFLOW_SANDBOX_URI}\"' >> /sandbox/.profile
echo 'export MLFLOW_TRACKING_TOKEN=\"${OCP_TOKEN}\"' >> /sandbox/.profile
echo 'export MLFLOW_TRACKING_INSECURE_TLS=\"true\"' >> /sandbox/.profile
echo 'export MLFLOW_EXPERIMENT_NAME=\"opencode-sandbox\"' >> /sandbox/.profile
echo 'export MLFLOW_WORKSPACE=\"${MLFLOW_WORKSPACE:-openshell}\"' >> /sandbox/.profile
echo 'export NODE_TLS_REJECT_UNAUTHORIZED=\"0\"' >> /sandbox/.profile
echo '# OpenCode path' >> /sandbox/.profile
echo 'export npm_config_prefix=/sandbox/.npm-global' >> /sandbox/.profile
echo 'export PATH=\"/sandbox/.npm-global/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin\"' >> /sandbox/.profile
"
VERIFY=$(openshell sandbox exec --name "$SANDBOX_NAME" -- grep -c OPENAI_API_KEY /sandbox/.profile 2>&1 | tr -d '[:space:]' || true)
if [ "$VERIFY" -ge 1 ] 2>/dev/null; then
    info "Credentials written to /sandbox/.profile"
else
    error "Failed to write credentials to .profile"
    exit 1
fi

step "Ensure .bashrc sources .profile (sandbox connect uses non-login shell)"
openshell sandbox exec --name "$SANDBOX_NAME" -- bash -c '
    grep -q "source.*\.profile" /sandbox/.bashrc 2>/dev/null || \
    echo "
# Load sandbox credentials
[ -f /sandbox/.profile ] && source /sandbox/.profile
" >> /sandbox/.bashrc
'
info ".bashrc configured to source .profile"

step "Install MLflow tracing plugin"
if [ -n "$OCP_TOKEN" ]; then
    # Install @mlflow/opencode plugin (downloads from npm, then replace with pre-built version)
    openshell sandbox exec --name "$SANDBOX_NAME" -- sh -c 'export npm_config_prefix=/sandbox/.npm-global && export PATH="/sandbox/.npm-global/bin:$PATH" && opencode plugin @mlflow/opencode 2>&1 || echo "Plugin install: non-fatal"'

    # Replace cached plugin with pre-built version (includes workspace header fix)
    openshell sandbox exec --name "$SANDBOX_NAME" -- sh -c '
        CACHED_CORE=$(find /sandbox/.cache/opencode/packages -path "*/@mlflow/core/dist" -type d 2>/dev/null | head -1)
        CACHED_OC=$(find /sandbox/.cache/opencode/packages -path "*/@mlflow/opencode/dist" -type d 2>/dev/null | head -1)
        [ -d "/opt/mlflow-plugin/core/dist" ] && [ -n "${CACHED_CORE:-}" ] && cp -r /opt/mlflow-plugin/core/dist/* "$CACHED_CORE/" && echo "Replaced @mlflow/core"
        [ -d "/opt/mlflow-plugin/opencode/dist" ] && [ -n "${CACHED_OC:-}" ] && cp -r /opt/mlflow-plugin/opencode/dist/* "$CACHED_OC/" && echo "Replaced @mlflow/opencode"
    ' 2>&1 || true
    info "MLflow tracing plugin installed"
else
    warn "MLflow plugin: SKIP (no OCP token)"
fi

step "Create MLflow experiment"
if [ -n "$OCP_TOKEN" ]; then
    # mlflow[kubernetes] handles auth natively (Bearer token + X-Mlflow-Workspace header)
    openshell sandbox exec --name "$SANDBOX_NAME" -- sh -c "export MLFLOW_TRACKING_URI='${MLFLOW_SANDBOX_URI}' MLFLOW_TRACKING_TOKEN='${OCP_TOKEN}' MLFLOW_TRACKING_INSECURE_TLS=true MLFLOW_WORKSPACE='${MLFLOW_WORKSPACE:-openshell}' && python3 -c 'import os, mlflow; mlflow.set_tracking_uri(os.environ[\"MLFLOW_TRACKING_URI\"]); name=\"opencode-sandbox\"; exp=mlflow.get_experiment_by_name(name); print(exp.experiment_id if exp else mlflow.create_experiment(name))' 2>&1 || echo 'MLflow setup: non-fatal'"
    info "MLflow experiment opencode-sandbox created"
else
    warn "MLflow experiment: SKIP (no OCP token)"
fi

step "Test LiteLLM from sandbox"
RESULT=$(openshell sandbox exec --name "$SANDBOX_NAME" -- curl -s -w "\n%{http_code}" -X POST "${LITELLM_BASE_URL}/chat/completions" -H "Authorization: Bearer ${LITELLM_API_KEY}" -H "Content-Type: application/json" -d '{"model":"'"${LITELLM_MODEL:-gpt-oss-120b}"'","messages":[{"role":"user","content":"Say ok"}],"max_tokens":5}' 2>&1 | grep -v "Using sandbox")
HTTP_CODE=$(echo "$RESULT" | tail -1)
if [ "$HTTP_CODE" = "200" ]; then
    info "LiteLLM test: OK (HTTP 200) - model: ${LITELLM_MODEL:-gpt-oss-120b}"
else
    warn "LiteLLM test: HTTP $HTTP_CODE"
fi

step "Test RHOAI MLflow from sandbox"
if [ -n "$OCP_TOKEN" ]; then
    MLF_CODE=$(openshell sandbox exec --name "$SANDBOX_NAME" -- curl -sk -o /dev/null -w "%{http_code}" -H "Authorization: Bearer ${OCP_TOKEN}" -H "X-Mlflow-Workspace: ${MLFLOW_WORKSPACE:-openshell}" "${MLFLOW_SANDBOX_URI}/api/2.0/mlflow/experiments/search?max_results=1" 2>&1 | grep -v "Using sandbox")
    if [ "$MLF_CODE" = "200" ]; then
        info "RHOAI MLflow test: OK (HTTP 200)"
    else
        warn "RHOAI MLflow test: HTTP $MLF_CODE"
    fi
else
    warn "RHOAI MLflow test: SKIP (no OCP token)"
fi

echo ""
echo "============================================"
echo " Sandbox '$SANDBOX_NAME' ready!"
echo "============================================"
echo ""
echo " Connect with:"
echo "   openshell sandbox connect $SANDBOX_NAME"
echo ""
echo " Inside the sandbox (credentials auto-loaded):"
echo "   opencode"
echo ""
echo " Model: ${LITELLM_MODEL:-gpt-oss-120b}"
echo " MLflow: ${MLFLOW_SANDBOX_URI}"
echo " MLflow traces: automatic (@mlflow/opencode plugin, fires on session idle)"
echo ""
