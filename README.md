# local-agentic-loop-sample

Sample setup for a local autonomous mini-SWE-agent loop using:

- GitHub issue triggers (`agent:ready`)
- A self-hosted GitHub Actions runner in Docker
- mini-SWE-agent running inside the runner container
- Ollama running in Docker with models stored on external storage
- Direct pushes to a dev branch (`agent-dev`), never to `main`

## Branch model

- `main`: stores automation files only (workflow + templates)
- `agent-dev`: receives agent-produced code commits

## Repository files in this sample

- `.github/workflows/mini-swe-dev-loop.yml`
- `.github/ISSUE_TEMPLATE/agent-task.yml`
- `docker-compose.yml`
- `runner/Dockerfile`
- `runner/entrypoint.sh`
- `config/mini-local-ollama.yaml`

## Quick setup

### 1) Mount external storage for Ollama

```bash
sudo mkdir -p /mnt/ollama-usb
sudo mount /dev/sdb1 /mnt/ollama-usb
sudo mkdir -p /mnt/ollama-usb/ollama
sudo chmod -R 777 /mnt/ollama-usb/ollama
```

### 2) Start the local stack

From this repository root:

```bash
docker compose up -d --build
```

Expected services:

- `ollama` on `http://localhost:11434`
- `github-mini-swe-runner` registered as a self-hosted runner

### 3) Pull a coding model

```bash
docker exec -it ollama ollama pull qwen2.5-coder:7b
```

### 4) Validate runner ↔ ollama connectivity

```bash
docker exec -it github-mini-swe-runner bash
curl http://ollama:11434/api/tags
mini -c /opt/agent-config/mini-local-ollama.yaml -y --exit-immediately -t "Say hello. Do not modify files."
```

## GitHub configuration checklist

1. Create and push `agent-dev` branch.
2. Add labels:
   - `agent:ready`
   - `agent:running`
   - `agent:done`
   - `agent:failed`
   - `agent:blocked`
3. Ensure Actions workflow permissions are set to **Read and write**.
4. Register the self-hosted runner and provide `GH_RUNNER_REPO_URL` + `GH_RUNNER_TOKEN` to the runner container environment.
5. Keep `main` protected; leave `agent-dev` unprotected (or lightly protected) for direct workflow pushes.

## Trigger flow

1. Create an issue from **Agent Task** template.
2. Apply label `agent:ready` (trusted users only).
3. Workflow runs mini-SWE-agent on the self-hosted runner.
4. Workflow commits and pushes directly to `agent-dev`.
5. Issue labels move to `agent:done` or `agent:failed`.

You can also trigger reruns by commenting:

```text
/agent run
```

## Security and operations notes

- Only trusted collaborators should trigger the agent.
- Do not run this pattern on untrusted public contribution paths.
- Do not store production secrets on this runner.
- One concurrency group is used to avoid branch trampling.
