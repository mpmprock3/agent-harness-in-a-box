# Demo 2: OpenCode + Keycloak OIDC + MLflow

Deploy OpenShell on OpenShift with Keycloak authentication, OpenCode as the AI coding agent, and optional MLflow tracing. This demo builds on Demo 1 by adding OIDC authentication so users must log in before accessing sandboxes.

## What You Will Learn

- How to deploy Keycloak on OpenShift and configure OIDC for OpenShell
- How OIDC tokens flow between the CLI, Keycloak, and the OpenShell gateway
- How to build a custom sandbox image with OpenCode pre-installed
- How to use OpenCode inside a sandboxed environment
- How to add MLflow tracing to track agent activity

## Architecture

```
+--------------+    OIDC     +------------------+
|              +------------>+                  |
| openshell    |    login    |  Keycloak        |
| CLI          +<------------+  (OIDC Provider) |
|              |    JWT      |                  |
+------+-------+             +------------------+
       |
       | gRPC + Bearer token
       v
+------+----------+         +-------------------+
|                  | creates |                   |
| OpenShell        +-------->+ Sandbox Pods      |
| Gateway          |         | (OpenCode agent)  |
| (validates JWT)  |         |                   |
+---------+--------+         +---------+---------+
          |                            |
          |  inference.local           | (optional)
          +----------------------------+-----------> RHOAI MLflow
```

**How OIDC works with OpenShell:**

1. The CLI opens a browser to the Keycloak login page
2. User authenticates with username/password (local Keycloak users)
3. Keycloak issues a signed JWT with `realm_access.roles` containing `openshell-admin` or `openshell-user`
4. The CLI presents the JWT as a Bearer token on every gRPC call
5. The gateway validates the JWT against Keycloak's JWKS endpoint (in-cluster URL)
6. Role-based access: admins can manage providers and policies, users can create sandboxes

**Why Keycloak instead of Dex:**

The original openshell-demo uses Dex as an OIDC bridge for GitHub OAuth. Keycloak is a full OIDC provider that supports local users directly, with no external IdP dependency. OpenShell has native Keycloak support with a pre-built realm configuration.

## Prerequisites

- OpenShift 4.19+ cluster with cluster-admin access
- `oc` CLI configured and logged in
- Helm 3.x
- `openshell` CLI installed
- `podman` or `docker` for building the sandbox image (optional if using pre-built images)

## OpenShift-Specific Considerations

Deploying on OpenShift requires several adjustments compared to vanilla Kubernetes or local Docker. These are already integrated into the scripts and manifests in this repo, but understanding them helps with debugging:

| Issue | Root Cause | Fix |
|-------|-----------|-----|
| Gateway crashes with `failed to create /.local/state/` | OpenShift assigns arbitrary UIDs with no home directory | Set `HOME=/var/openshell` env var on the StatefulSet |
| CLI can't do OIDC discovery | `KC_HOSTNAME` uses in-cluster hostname unreachable from your Mac | Set `KC_HOSTNAME` to the external Keycloak route hostname |
| Gateway pod stuck in `ContainerCreating` | Chart expects TLS secrets named `openshell-server-tls` but cert-manager creates `openshell-tls` | Set `tls.certSecretName` and `tls.clientCaSecretName` in values |
| `HTTP/2 was not negotiated` | Edge TLS route breaks gRPC ALPN negotiation | Use `termination: passthrough` on the route |
| `forbidden: policy denied` in OpenCode | OpenCode binary registers as `/usr/local/bin/opencode` in `/proc/PID/exe`; supervisor proxy enforces binary-aware policy | Add `{ path: /usr/local/bin/opencode }` to network policy binaries |
| OpenCode hits placeholder URL | `.env` has example values; `setup-sandbox.sh` bakes them into the sandbox config | Fill in `.env` with real values **before** running `setup-sandbox.sh` |

## Quick Start (Automated)

```bash
# 1. Fill in your credentials FIRST
cp ../../.env.example ../../.env
# Edit .env with your actual LiteLLM endpoint, API key, and cluster domain

# 2. Deploy infrastructure
ENABLE_TLS=true bash install.sh

# 3. Register the gateway with your CLI
export OPENSHELL_GATEWAY_INSECURE=true
KC_ROUTE=$(oc -n openshell-keycloak get route keycloak -o jsonpath='{.spec.host}')
GW_ROUTE=$(oc -n openshell get route openshell-gw -o jsonpath='{.spec.host}')

openshell gateway add "https://$GW_ROUTE" \
    --name openshift \
    --gateway-insecure \
    --oidc-issuer "https://$KC_ROUTE/realms/openshell" \
    --oidc-client-id openshell-cli

# 4. Login (opens browser to Keycloak — use admin@test / admin)
openshell gateway login openshift

# 5. Create sandbox
export OPENSHELL_GATEWAY_INSECURE=true
bash setup-sandbox.sh

# 6. Connect and use OpenCode
openshell sandbox connect opencode-demo
# Inside sandbox: opencode
```

### TLS Mode

TLS is **required** for OpenShift because OpenShift HAProxy strips gRPC trailers from H2C, edge, and re-encrypt routes. Passthrough TLS is the only route type that preserves gRPC trailers.

When TLS is enabled:
- cert-manager creates a CA chain (SelfSigned -> CA Certificate -> CA Issuer -> Server/Client Certs)
- Gateway serves TLS on port 8080 with a passthrough route
- Sandbox pods get a client TLS cert for mTLS with the gateway
- CLI connects with `--gateway-insecure` flag (self-signed CA)
- Set `export OPENSHELL_GATEWAY_INSECURE=true` in your shell for all `openshell` CLI commands

**TLS prerequisites:**
- cert-manager on the cluster. The install script auto-installs the [Red Hat cert-manager operator](https://github.com/redhat-cop/gitops-catalog/tree/main/openshift-cert-manager-operator) via OLM if CRDs are not already present. To install manually:
  ```bash
  oc apply -k https://github.com/redhat-cop/gitops-catalog/openshift-cert-manager-operator/operator/overlays/stable-v1
  ```

## Step-by-Step Guide

### Step 1: Prerequisites check

```bash
bash ../../common/prerequisites.sh
```

### Step 2: Deploy Keycloak

Create the namespace and apply all Keycloak manifests:

```bash
oc apply -f manifests/keycloak/namespace.yaml
oc apply -f manifests/keycloak/realm-configmap.yaml
oc apply -f manifests/keycloak/deployment.yaml
oc apply -f manifests/keycloak/service.yaml
```

Wait for Keycloak to be ready (it takes about 30-60 seconds to start and import the realm):

```bash
oc -n openshell-keycloak rollout status deployment/keycloak --timeout=120s
```

**What happens during startup:**

- Keycloak starts in `start-dev` mode (H2 in-memory database, no persistence needed for demos)
- The `--import-realm` flag imports the realm JSON from the mounted ConfigMap
- `KC_HOSTNAME` must be set to the **external route hostname** (e.g. `keycloak-openshell-keycloak.apps.cluster-xxx.example.com`) so that tokens carry an issuer URL reachable by both the gateway (in-cluster) and the CLI (your Mac)

> **Important:** Before deploying, edit `manifests/keycloak/deployment.yaml` and set `KC_HOSTNAME` to your cluster's Keycloak route hostname. The OIDC issuer URL in `manifests/openshell/values-keycloak.yaml` must match (use `https://` prefix since the route has edge TLS).

**The pre-configured realm includes:**

| Resource | Details |
|----------|---------|
| Realm | `openshell` |
| Roles | `openshell-admin` (full access), `openshell-user` (standard access) |
| Client `openshell-cli` | Public client with PKCE (for interactive CLI login) |
| Client `openshell-ci` | Confidential client (for CI/automation) |
| User `admin@test` | Password: `admin` - has both admin and user roles |
| User `user@test` | Password: `user` - has user role only |

### Step 3: Expose Keycloak

Create a Route for the Keycloak admin console and OIDC endpoints:

```bash
oc apply -f manifests/keycloak/route.yaml
```

Verify the OIDC discovery endpoint responds:

```bash
KC_ROUTE=$(oc -n openshell-keycloak get route keycloak -o jsonpath='{.spec.host}')
curl -sk "https://$KC_ROUTE/realms/openshell/.well-known/openid-configuration" | python3 -m json.tool | head -10
```

You should see a JSON response with `issuer`, `authorization_endpoint`, `token_endpoint`, etc.

**Access the admin console (optional):**

Open `https://<KC_ROUTE>` in your browser and log in with `admin`/`admin` to explore the realm, users, and clients.

### Step 4: Customize Keycloak users (optional)

To add custom users, either:

**Option A: Via the admin console**
1. Log in at `https://<KC_ROUTE>`
2. Select the `openshell` realm (dropdown in the top-left)
3. Go to Users > Add user
4. Set username and email, then go to Credentials tab to set a password
5. Go to Role Mapping tab and assign `openshell-user` (or `openshell-admin`)

**Option B: Via the realm JSON**
Edit `manifests/keycloak/realm-configmap.yaml` and add entries to the `users` array, then reapply:
```bash
oc apply -f manifests/keycloak/realm-configmap.yaml
oc -n openshell-keycloak rollout restart deployment/keycloak
```

### Step 5: Install Agent Sandbox CRDs

If you already completed Demo 1, skip this step.

```bash
oc apply -f \
    https://github.com/kubernetes-sigs/agent-sandbox/releases/latest/download/manifest.yaml
oc -n agent-sandbox-system wait --for=condition=Ready pod \
    -l control-plane=controller-manager --timeout=120s
```

### Step 6: Configure OpenShift for OpenShell

Create the namespace, SCC binding, and JWT signing secret:

```bash
# Create namespace
oc create ns openshell --dry-run=client -o yaml | oc apply -f -

# Grant privileged SCC to sandbox service account
oc adm policy add-scc-to-user privileged -z openshell-sandbox -n openshell

# Create JWT signing secret (if not already created by Demo 1)
if ! oc -n openshell get secret openshell-jwt-keys &>/dev/null; then
    openssl genpkey -algorithm Ed25519 -out /tmp/jwt-signing.pem
    openssl pkey -in /tmp/jwt-signing.pem -pubout -out /tmp/jwt-public.pem
    KID=$(openssl pkey -in /tmp/jwt-signing.pem -pubout -outform DER \
        | openssl dgst -sha256 -binary | openssl base64 -A | tr '+/' '-_' | tr -d '=')
    echo "$KID" > /tmp/jwt-kid.txt
    oc -n openshell create secret generic openshell-jwt-keys \
        --from-file=signing.pem=/tmp/jwt-signing.pem \
        --from-file=public.pem=/tmp/jwt-public.pem \
        --from-file=kid=/tmp/jwt-kid.txt
    rm -f /tmp/jwt-signing.pem /tmp/jwt-public.pem /tmp/jwt-kid.txt
fi
```

### Step 7: Install OpenShell with Keycloak OIDC

Before installing, update the values file for your cluster:

1. Edit `manifests/openshell/values-keycloak.yaml`:
   - Set `oidc.issuer` to `https://<your-keycloak-route>/realms/openshell`
   - If using TLS with cert-manager, set `tls.certSecretName` and `tls.clientCaSecretName` to match the secret names cert-manager creates (typically `openshell-tls` and `openshell-client-ca`)

2. Edit `manifests/keycloak/deployment.yaml`:
   - Set `KC_HOSTNAME` to your Keycloak route hostname (must match what you used in `oidc.issuer`)

Install using the Keycloak values overlay:

```bash
helm upgrade --install openshell oci://ghcr.io/nvidia/openshell/helm-chart \
    --namespace openshell \
    -f manifests/openshell/values-keycloak.yaml

# Fix for OpenShift arbitrary UIDs — gateway needs a writable HOME
oc -n openshell set env statefulset/openshell HOME=/var/openshell
```

Wait for the gateway:

```bash
oc -n openshell rollout status statefulset/openshell --timeout=300s
```

**What the values file configures:**

| Setting | Purpose |
|---------|---------|
| `pkiInitJob.enabled: false` | Disable PKI init job (incompatible with OpenShift SCCs) |
| `podSecurityContext.fsGroup: null` | Let OpenShift assign the group |
| `securityContext.runAsUser: null` | Let OpenShift assign the UID |
| `server.disableTls: false` | Enable TLS (required for passthrough route + gRPC) |
| `server.tls.certSecretName` | Must match cert-manager secret name |
| `oidc.issuer` | Must use the **external** Keycloak route URL |
| `oidc.audience` | Must match the Keycloak client ID (`openshell-cli`) |
| `oidc.rolesClaim` | `realm_access.roles` — where Keycloak puts roles in the JWT |

> **Why HOME=/var/openshell?** OpenShift assigns arbitrary UIDs that have no entry in `/etc/passwd` and no home directory. The gateway writes credential encryption state to `$HOME/.local/state/openshell/`. Without HOME set, it defaults to `/` which is read-only, causing a startup crash.

### Step 8: Create the gateway Route and register

The route **must** use passthrough TLS termination. Edge TLS breaks gRPC's HTTP/2 ALPN negotiation:

```bash
oc -n openshell apply -f manifests/openshell/route.yaml
```

Register the gateway with OIDC. Since we use self-signed certs, set the insecure flag:

```bash
export OPENSHELL_GATEWAY_INSECURE=true

KC_ROUTE=$(oc -n openshell-keycloak get route keycloak -o jsonpath='{.spec.host}')
GW_ROUTE=$(oc -n openshell get route openshell-gw -o jsonpath='{.spec.host}')

openshell gateway add "https://$GW_ROUTE" \
    --name openshift \
    --gateway-insecure \
    --oidc-issuer "https://$KC_ROUTE/realms/openshell" \
    --oidc-client-id "openshell-cli"
```

**Authenticate with the gateway:**

```bash
openshell gateway login openshift
```

This opens your browser to the Keycloak login page. Log in with `admin@test` / `admin` (or `user@test` / `user`).

Verify authentication works:

```bash
export OPENSHELL_GATEWAY_INSECURE=true
openshell status
```

> **Note:** You must set `export OPENSHELL_GATEWAY_INSECURE=true` in every terminal session that uses the `openshell` CLI, since the gateway uses self-signed TLS certificates. Add it to your shell profile for convenience.

### Step 9: Create an OpenCode sandbox

The recommended approach uses `setup-sandbox.sh`, which creates the sandbox, uploads OpenCode config, and injects LiteLLM + MLflow credentials.

> **Critical:** Fill in `.env` with **real values** before running `setup-sandbox.sh`. The script bakes the LiteLLM URL and API key into the sandbox config files. If `.env` has placeholder values, OpenCode will try to connect to `your-litellm-endpoint.example.com` and fail.

```bash
# Ensure .env exists with your credentials
cp ../../.env.example ../../.env
# Edit .env — fill in ALL values:
#   LITELLM_BASE_URL=https://your-actual-litellm-proxy/v1
#   LITELLM_API_KEY=sk-your-actual-key
#   OCP_APPS_DOMAIN=apps.your-cluster.example.com

# Must be set for all openshell CLI commands with self-signed TLS
export OPENSHELL_GATEWAY_INSECURE=true

bash setup-sandbox.sh
```

To use a pre-baked sandbox image (OpenCode already installed):

```bash
SANDBOX_IMAGE=quay.io/rcarrata/agentic-harness-openshell:opencode-v1 \
    bash setup-sandbox.sh
```

Connect and run OpenCode (credentials are auto-loaded from `.profile`):

```bash
export OPENSHELL_GATEWAY_INSECURE=true
openshell sandbox connect opencode-demo
# Inside the sandbox, OpenCode loads credentials automatically:
opencode
```

If you need to override the LiteLLM credentials inside the sandbox:

```bash
export OPENAI_API_KEY="sk-your-actual-key"
export OPENAI_BASE_URL="https://your-litellm-proxy/v1"
opencode
```

**Build your own sandbox image (optional):**

```bash
cd sandbox-image
podman build --platform linux/amd64 \
    -t quay.io/<your-org>/opencode-sandbox:latest \
    -f Containerfile.openshell .
podman push quay.io/<your-org>/opencode-sandbox:latest
```

Then use it: `SANDBOX_IMAGE=quay.io/<your-org>/opencode-sandbox:latest bash setup-sandbox.sh`

**Manual sandbox creation (without setup script):**

```bash
openshell sandbox create --name opencode-test \
    --from quay.io/<your-org>/opencode-sandbox:latest
openshell sandbox connect opencode-test

# Inside the sandbox, set credentials manually:
export OPENAI_API_KEY="your-litellm-key"
export OPENAI_BASE_URL="https://your-litellm-endpoint.example.com/v1"
opencode
```

### Step 10: Configure LiteLLM inference

If you used `setup-sandbox.sh`, this is already done. For manual setup:

```bash
openshell provider create openai \
    --name litellm \
    --base-url https://your-litellm-endpoint.example.com/v1 \
    --api-key <your-api-key>

openshell inference set --provider litellm --model gpt-oss-120b --role user
openshell inference set --provider litellm --model llama-scout-17b --role system

openshell policy set --global --policy /tmp/policy-standard-rendered.yaml --yes
```

### Step 10b: Choose an LLM model in OpenCode

The OpenCode config at `config/opencode-config.json` defines all available LiteLLM models. It is uploaded to `/workspace/.opencode/config.json` inside the sandbox by `setup-sandbox.sh`.

**Available models:**

| Model ID | Name | Reasoning | Context |
|----------|------|-----------|---------|
| `gpt-oss-120b` | GPT OSS 120B | Yes | 128K |
| `gemini-2.5-pro` | Gemini 2.5 Pro | Yes | 1M |
| `llama-scout-17b` | Llama Scout 17B | No | 128K |
| `qwen3-235b` | Qwen3 235B | Yes | 128K |
| `minimax-m2` | MiniMax M2 | No | 128K |

**Change the default model before creating the sandbox:**

Edit `config/opencode-config.json` and set `"model"` and `"small_model"`:

```json
{
  "model": "litellm/gemini-2.5-pro",
  "small_model": "litellm/llama-scout-17b"
}
```

**Switch models inside a running OpenCode session:**

Type `/model` in the OpenCode prompt to interactively pick from the configured models.

**Change the default model in an existing sandbox:**

```bash
openshell sandbox exec --name opencode-demo -- \
    sed -i 's|"model": "litellm/.*"|"model": "litellm/qwen3-235b"|' \
    /workspace/.opencode/config.json
```

Then restart OpenCode to pick up the change.

### Step 11: Configure RHOAI MLflow tracing (optional)

`setup-sandbox.sh` configures MLflow automatically when an OCP token is available. For manual setup, see `overlays/mlflow/README.md`.

Access the RHOAI MLflow dashboard at the route exposed by OpenShift AI and navigate to the `openshell` workspace.

## Sandbox Security: Standard Policy

This demo uses a **standard** policy - a balanced tier for coding agents that allows inference, package registries, and read-only GitHub access while blocking direct AI APIs and arbitrary web browsing.

### Network Allowlisting

Unlike the strict policy (Demo 01), the standard tier opens access to package registries and code hosts that coding agents need:

```bash
# From inside the sandbox:
curl https://registry.npmjs.org/express    # -> HTTP 200 (npm allowed)
curl https://pypi.org/simple/requests/     # -> HTTP 200 (PyPI allowed)
curl https://api.anthropic.com             # -> HTTP 403 (direct AI APIs not needed)
curl https://example.com                   # -> HTTP 403 (not in policy)
```

### L7 Inspection: Read-Only Enforcement

GitHub is allowed but restricted to read-only access. The CONNECT proxy terminates TLS and inspects each HTTP request at Layer 7:

```bash
curl https://api.github.com/repos/NVIDIA/OpenShell    # -> HTTP 200 (GET allowed)
curl -X POST https://api.github.com/repos/.../issues  # -> HTTP 403 (POST blocked!)
```

The proxy returns a structured JSON error for blocked methods:

```json
{"error": "policy_denied", "detail": "POST not permitted by read-only policy"}
```

### Filesystem: Landlock Enforcement

Same Landlock rules as the strict tier - filesystem access is identical across all policy levels:

```bash
echo test > /workspace/test.txt    # OK (read-write path)
echo test > /tmp/test.txt          # OK (read-write path)
echo test > /etc/test.txt          # Permission denied (read-only)
echo test > /usr/test.txt          # Permission denied (read-only)
cat /etc/os-release                # OK (read-only allows reads)
```

### Comparing Tiers

Switch to strict to see the contrast (hot-reload, no restart needed):

```bash
openshell policy set --global --policy ../01-basic-openshell/config/policy-strict.yaml --yes
curl https://registry.npmjs.org/express    # -> HTTP 403 (was 200!)
```

### Run the Full Security Test

```bash
bash setup-sandbox.sh              # create sandbox with standard policy
bash test-sandbox-security.sh      # run all tests, see color-coded report
```

This runs network allowlisting, L7 inspection, Landlock, and process isolation tests.

## Teardown

Remove everything:

```bash
bash teardown.sh
```

This removes both the OpenShell and Keycloak namespaces.

## Troubleshooting

### Gateway pod crashes with `failed to create /.local/state/openshell/`

OpenShift assigns arbitrary UIDs with no home directory. The gateway tries to write credential state to `$HOME/.local/state/...` but `HOME` defaults to `/` which is read-only.

**Fix:**
```bash
oc -n openshell set env statefulset/openshell HOME=/var/openshell
oc -n openshell delete pod openshell-0  # force restart with new env
```

### Gateway pod stuck in `ContainerCreating` — TLS secret not found

When `disableTls: false`, the chart mounts TLS secrets. If cert-manager created secrets with different names than the chart defaults, the pod can't start.

**Fix:** Check what secrets exist and update values:
```bash
oc -n openshell get secrets | grep tls
# Then set tls.certSecretName and tls.clientCaSecretName in values-keycloak.yaml
```

### `HTTP/2 was not negotiated` when CLI connects

gRPC requires HTTP/2. Edge TLS termination on OpenShift routes doesn't properly negotiate HTTP/2 ALPN for gRPC.

**Fix:** The route must use passthrough TLS:
```yaml
spec:
  tls:
    termination: passthrough
```

### `OIDC discovery issuer mismatch` when registering gateway

The CLI's `--oidc-issuer` URL must exactly match what Keycloak returns in its `/.well-known/openid-configuration` response.

**Fix:** `KC_HOSTNAME` in the Keycloak deployment controls the issuer. Set it to the external route hostname and update `oidc.issuer` in values to match:
```bash
# Check what Keycloak advertises:
KC_ROUTE=$(oc -n openshell-keycloak get route keycloak -o jsonpath='{.spec.host}')
curl -sk "https://$KC_ROUTE/realms/openshell/.well-known/openid-configuration" | grep issuer
```

### `invalid peer certificate: UnknownIssuer` from CLI

The gateway uses self-signed TLS certificates from cert-manager.

**Fix:** Set the insecure flag:
```bash
export OPENSHELL_GATEWAY_INSECURE=true
# Or per-command:
openshell --gateway-insecure sandbox list
```

### `forbidden: policy denied` when using OpenCode

This is the OpenShell supervisor's network proxy denying the connection. Three common causes:

**1. Wrong binary path in policy**

The supervisor identifies processes by their binary path from `/proc/PID/exe`. OpenCode's ELF binary registers as `/usr/local/bin/opencode` even though it's installed at `/sandbox/.npm-global/lib/node_modules/opencode-ai/bin/opencode.exe`. The policy must include this path.

Check the supervisor logs:
```bash
oc -n openshell logs default--opencode-demo -c agent | grep "Cannot access"
```

**Fix:** Add to the network policy's `binaries` section:
```yaml
binaries:
  - { path: /usr/local/bin/opencode }
```

**2. No `binaries` section in policy = deny all**

The network policy uses an **allowlist** model. If the `binaries` section is missing entirely, NO binary can access that endpoint (not even curl).

**3. Wrong LiteLLM URL in OpenCode config**

If `.env` had placeholder values when `setup-sandbox.sh` ran, the baked-in config points to `your-litellm-endpoint.example.com`.

**Fix:**
```bash
export OPENSHELL_GATEWAY_INSECURE=true
openshell sandbox exec --name opencode-demo -- \
    sed -i 's|https://your-litellm-endpoint.example.com/v1|https://your-actual-url/v1|g' \
    /sandbox/.config/opencode/opencode.jsonc
```

### Helm upgrade fails with `conflict with kubectl-client-side-apply`

This happens when the ConfigMap was previously created or modified with `kubectl apply`, creating a field manager conflict with Helm's server-side apply.

**Fix:**
```bash
oc -n openshell delete configmap openshell-config
helm upgrade --install openshell ...  # Helm recreates it cleanly
```

### "PermissionDenied" when accessing the gateway

The OIDC token does not have the required roles. Check that:
1. The user has `openshell-admin` or `openshell-user` role in Keycloak
2. The `rolesClaim` in Helm values matches Keycloak's token structure (`realm_access.roles`)

### Keycloak pod not starting

Check the logs:
```bash
oc -n openshell-keycloak logs deployment/keycloak
```

Common issues:
- Realm JSON syntax error in the ConfigMap
- Resource limits too low (Keycloak needs at least 512Mi)

## References

- [OpenShell Access Control](https://docs.nvidia.com/openshell/latest/kubernetes/access-control)
- [OpenShell on OpenShift](https://docs.nvidia.com/openshell/latest/kubernetes/openshift)
- [Keycloak Documentation](https://www.keycloak.org/documentation)
