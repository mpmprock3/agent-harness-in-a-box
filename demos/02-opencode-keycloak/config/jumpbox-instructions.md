# Jumpbox Remote Execution

You are running inside an OpenShell sandbox. You do NOT have direct access to AWS,
ROSA CLI, or OpenShift clusters. All infrastructure commands must be executed on
a remote jumpbox server via SSH.

## SSH Connection

```bash
ssh -i /sandbox/.ssh/jumpbox_key -o StrictHostKeyChecking=no ${JUMPBOX_USER}@${JUMPBOX_HOST} '<command>'
```

For multi-line scripts:

```bash
ssh -i /sandbox/.ssh/jumpbox_key -o StrictHostKeyChecking=no ${JUMPBOX_USER}@${JUMPBOX_HOST} bash -s <<'REMOTE'
# commands here run on the jumpbox
REMOTE
```

## Rules

1. **All infrastructure commands run on the jumpbox** — this includes: `rosa`, `oc`,
   `aws`, `helm`, `kubectl`, `openssl`, and any command that interacts with clusters or AWS.

2. **When following skill instructions**, the skills contain commands meant to run
   directly. You MUST wrap each command (or command block) inside the SSH pattern above.
   For example, if a skill says:
   ```bash
   rosa create cluster --cluster-name foo --sts --mode auto --yes
   ```
   You execute:
   ```bash
   ssh -i /sandbox/.ssh/jumpbox_key -o StrictHostKeyChecking=no ${JUMPBOX_USER}@${JUMPBOX_HOST} \
       'rosa create cluster --cluster-name foo --sts --mode auto --yes'
   ```

3. **For heredoc/multi-line commands** in skills (like `oc apply -f - <<'EOF' ...`),
   wrap the entire block in the SSH heredoc pattern:
   ```bash
   ssh -i /sandbox/.ssh/jumpbox_key -o StrictHostKeyChecking=no ${JUMPBOX_USER}@${JUMPBOX_HOST} bash -s <<'REMOTE'
   oc apply -f - <<'EOF'
   apiVersion: v1
   kind: Namespace
   ...
   EOF
   REMOTE
   ```

4. **Local commands are OK** for: `curl` (to test endpoints), `cat`, `echo`,
   file operations in `/sandbox` or `/workspace`, and `git` (to clone skill repos).

5. **Skills are in /workspace/skills/** — cloned from the GitHub skills repository.
   Read the SKILL.md file for each skill before executing.

6. **Always verify SSH connectivity first** before running any skill:
   ```bash
   ssh -i /sandbox/.ssh/jumpbox_key -o StrictHostKeyChecking=no ${JUMPBOX_USER}@${JUMPBOX_HOST} 'echo "Connected to $(hostname)"'
   ```

## Available Skills

| Skill | Directory | Use When |
|-------|-----------|----------|
| ROSA Install | `/workspace/skills/rosa-install/` | Create, manage, hibernate, or teardown ROSA clusters |
| OpenShift AI Install | `/workspace/skills/openshift-ai-install/` | Install RHOAI operators, GPU support, and MaaS gateway |
| MaaS Configure | `/workspace/skills/maas-configure/` | Deploy LLM models, create subscriptions, set up chat UI |

Read the SKILL.md in the appropriate directory, then execute the steps via SSH to the jumpbox.
