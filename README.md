# Agent Harness in a Box

Structured demos for running OpenShell and AI coding agents on OpenShift. Each demo is self-contained with step-by-step instructions, automated install scripts, and verification.

## What is OpenShell?

OpenShell is NVIDIA's agent-first platform providing safe, sandboxed runtimes for autonomous AI agents. It enforces security boundaries through Landlock filesystem isolation, seccomp syscall filtering, and network policy enforcement via an HTTP CONNECT proxy.

## Demos

| Demo | Description | Auth | AI Agent | Inference |
|------|-------------|------|----------|-----------|
| [01-basic-openshell](demos/01-basic-openshell/) | Basic OpenShell installation | None | Default | N/A |
| [02-opencode-keycloak](demos/02-opencode-keycloak/) | OpenCode + Keycloak OIDC + MLflow | Keycloak | OpenCode | LiteLLM |
| [03-claude-code](demos/03-claude-code/) | Claude Code + LiteLLM + MLflow | Keycloak | Claude Code | LiteLLM |
| [04-escape-the-shell](demos/04-escape-the-shell/) | Interactive CTF - OpenShell security layers | None | N/A | N/A |
| [05-hermes](demos/05-hermes/) | Hermes agent (NousResearch) + LiteLLM + MLflow | None | Hermes | LiteLLM |

## Prerequisites

- OpenShift 4.19+ cluster with cluster-admin access
- `oc` CLI configured and logged in
- Helm 3.x
- `openshell` CLI ([install guide](https://docs.nvidia.com/openshell/latest/install))

## TLS Mode (Optional)

By default, the demos run HTTP without TLS and use port-forward for sandbox operations. This works fine but requires an active port-forward session.

If you want proper TLS with passthrough routes (no port-forward needed), set `ENABLE_TLS=true`:

```bash
ENABLE_TLS=true bash demos/01-basic-openshell/install.sh
```

**Why TLS matters:** OpenShift HAProxy strips gRPC trailers from H2C, edge, and re-encrypt routes. Passthrough TLS is the only route type that preserves gRPC trailers end-to-end. Without TLS, sandbox create/exec operations need port-forward to bypass the route.

**What TLS does:**
- cert-manager creates a CA chain (SelfSigned -> CA Certificate -> CA Issuer -> Server/Client Certs)
- Gateway serves TLS on port 8080
- Route becomes passthrough (preserves gRPC trailers)
- Sandbox pods get a client TLS cert for mTLS with the gateway
- CLI connects with `--gateway-insecure` flag (self-signed CA)

**TLS prerequisites:**
- cert-manager installed on the cluster (v1.15+ recommended)
- Install: `oc apply -f https://github.com/cert-manager/cert-manager/releases/latest/download/cert-manager.yaml`

TLS is supported in demos 01, 02, 04, and 05.

## Quick Start

```bash
# Check prerequisites
bash common/prerequisites.sh

# Run Demo 1 (default - no TLS)
cd demos/01-basic-openshell
bash install.sh

# Verify
bash verify.sh

# Teardown when done
bash teardown.sh
```

## Test Cluster

The demos have been tested on:
- OpenShift 4.20 on AWS (gp3-csi storage)
- OpenShift AI 3.4.2 with MLflow

## References

- [OpenShell Documentation](https://docs.nvidia.com/openshell/latest/)
- [OpenShell on OpenShift](https://docs.nvidia.com/openshell/latest/kubernetes/openshift)
- [Agent Sandbox SIG](https://github.com/kubernetes-sigs/agent-sandbox)
- [Red Hat build of Agent Sandbox](https://docs.redhat.com/en/documentation/openshift_sandboxed_containers/1.12/html/deploying_red_hat_build_of_agent_sandbox/)
