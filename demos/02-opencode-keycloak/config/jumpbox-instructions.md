# Jumpbox Remote Execution

You are running inside an OpenShell sandbox. You do NOT have direct access to AWS,
ROSA CLI, or OpenShift clusters. All infrastructure commands must be executed on
a remote jumpbox server via its HTTP API.

## API Connection

The jumpbox exposes an HTTP API. Use `curl` to execute commands remotely.

**Health check:**
```bash
curl -s http://${JUMPBOX_HOST}:${JUMPBOX_PORT}/health
```

**Execute a command:**
```bash
curl -s -X POST "http://${JUMPBOX_HOST}:${JUMPBOX_PORT}/exec" \
  -H "Authorization: Bearer ${JUMPBOX_TOKEN}" \
  -H "Content-Type: application/json" \
  -d '{"command": "<command>"}'
```

The response is JSON: `{"exit_code": 0, "stdout": "...", "stderr": "..."}`

For long-running commands, add a timeout (in seconds):
```bash
curl -s -X POST "http://${JUMPBOX_HOST}:${JUMPBOX_PORT}/exec" \
  -H "Authorization: Bearer ${JUMPBOX_TOKEN}" \
  -H "Content-Type: application/json" \
  -d '{"command": "<command>", "timeout": 600}'
```

## Rules

1. **All infrastructure commands run on the jumpbox** — this includes: `rosa`, `oc`,
   `aws`, `helm`, `kubectl`, `openssl`, and any command that interacts with clusters or AWS.

2. **When following skill instructions**, the skills contain commands meant to run
   directly. You MUST wrap each command inside the API call pattern above.
   For example, if a skill says:
   ```bash
   rosa create cluster --cluster-name foo --sts --mode auto --yes
   ```
   You execute:
   ```bash
   curl -s -X POST "http://${JUMPBOX_HOST}:${JUMPBOX_PORT}/exec" \
     -H "Authorization: Bearer ${JUMPBOX_TOKEN}" \
     -H "Content-Type: application/json" \
     -d '{"command": "rosa create cluster --cluster-name foo --sts --mode auto --yes", "timeout": 600}'
   ```

3. **For multi-line commands** in skills, join them with `&&` or `;`, or use a
   subshell. Escape inner quotes with backslash:
   ```bash
   curl -s -X POST "http://${JUMPBOX_HOST}:${JUMPBOX_PORT}/exec" \
     -H "Authorization: Bearer ${JUMPBOX_TOKEN}" \
     -H "Content-Type: application/json" \
     -d '{"command": "oc apply -f - <<EOF\napiVersion: v1\nkind: Namespace\nmetadata:\n  name: test\nEOF"}'
   ```

4. **Local commands are OK** for: `cat`, `echo`, file operations in `/sandbox`
   or `/workspace`, and `git` (to clone skill repos).

5. **Skills are in /workspace/skills/** — cloned from the GitHub skills repository.
   Read the SKILL.md file for each skill before executing.

6. **Always verify API connectivity first** before running any skill:
   ```bash
   curl -s http://${JUMPBOX_HOST}:${JUMPBOX_PORT}/health
   ```

## Available Skills

| Skill | Directory | Use When |
|-------|-----------|----------|
| ROSA Install | `/workspace/skills/rosa-install/` | Create, manage, hibernate, or teardown ROSA clusters |
| OpenShift AI Install | `/workspace/skills/openshift-ai-install/` | Install RHOAI operators, GPU support, and MaaS gateway |
| MaaS Configure | `/workspace/skills/maas-configure/` | Deploy LLM models, create subscriptions, set up chat UI |

Read the SKILL.md in the appropriate directory, then execute the steps via the jumpbox API.
