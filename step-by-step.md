# Step-by-step: build the local agent loop from scratch

This guide walks through recreating this repository from an empty GitHub repo. It builds a local autonomous development loop:

```text
GitHub issue
-> agent:ready label or /agent run comment
-> GitHub Actions self-hosted runner container
-> mini-SWE-agent
-> Ollama container
-> direct commit to agent-dev
```

The workflow file lives on `main` because GitHub loads issue-triggered workflows from the default branch. Agent-produced code changes land only on `agent-dev`.

## 1. Choose names

These are the names used by this repository:

```bash
DEV_BRANCH="agent-dev"
RUNNER_NAME="docker-mini-swe-runner"
MODEL_NAME="qwen2.5-coder:7b"
OLLAMA_MOUNT="/mnt/ollama-usb/ollama"
```

## 2. Create or clone the repository

Create an empty GitHub repository, then clone it:

```bash
gh auth login
gh repo clone OWNER/REPO
cd REPO
```

If you are building from this template instead, create the new repository with **Use this template**, clone the new repository, and continue with the setup sections below.

## 3. Create the branch model

Create the development branch used for agent output:

```bash
git checkout main
git pull
git checkout -B agent-dev
git push -u origin agent-dev
git checkout main
```

Recommended branch policy:

| Branch | Recommended setup |
| --- | --- |
| `main` | Protected. Holds workflow, Docker, runner, and documentation files. |
| `agent-dev` | Unprotected or lightly protected. Receives direct workflow commits. |

## 4. Create repository folders

From the repository root:

```bash
mkdir -p .github/workflows
mkdir -p .github/ISSUE_TEMPLATE
mkdir -p config
mkdir -p runner
```

## 5. Add `.gitignore`

Create `.gitignore`:

```gitignore
.env
```

The `.env` file stores the temporary runner registration token and must not be committed.

## 6. Add Docker Compose

Create `docker-compose.yml`:

```yaml
services:
  ollama:
    image: ollama/ollama:latest
    container_name: ollama
    restart: unless-stopped
    ports:
      - "11434:11434"
    volumes:
      - /mnt/ollama-usb/ollama:/root/.ollama

  github-runner:
    build:
      context: ./runner
      args:
        RUNNER_VERSION: "2.328.0"
    container_name: github-mini-swe-runner
    restart: unless-stopped
    depends_on:
      - ollama
    environment:
      GH_RUNNER_REPO_URL: "${GH_RUNNER_REPO_URL}"
      GH_RUNNER_TOKEN: "${GH_RUNNER_TOKEN}"
      RUNNER_NAME: "${RUNNER_NAME}"
      RUNNER_LABELS: "self-hosted,linux,docker,mini-swe-agent"
    volumes:
      - ./config:/opt/agent-config:ro
      - runner-work:/actions-runner/_work

volumes:
  runner-work:
```

Ollama stores model data under `/root/.ollama` inside the container. This repo mounts that path to `/mnt/ollama-usb/ollama` on the host so larger models can live on external storage.

## 7. Prepare Ollama storage

On the Linux host that will run Docker, plug in the external drive and find its device name:

```bash
lsblk -f
```

Create and mount the storage path:

```bash
sudo mkdir -p /mnt/ollama-usb
sudo mount /dev/sdb1 /mnt/ollama-usb
sudo mkdir -p /mnt/ollama-usb/ollama
sudo chmod -R 777 /mnt/ollama-usb/ollama
df -h /mnt/ollama-usb
```

Replace `/dev/sdb1` with the actual device from `lsblk`.

Optional persistent mount:

```bash
sudo blkid /dev/sdb1
sudo nano /etc/fstab
```

Add a line like this, replacing the UUID and filesystem type:

```text
UUID=YOUR-USB-UUID /mnt/ollama-usb ext4 defaults,nofail 0 2
```

Test it:

```bash
sudo umount /mnt/ollama-usb
sudo mount -a
df -h /mnt/ollama-usb
```

## 8. Add the runner Dockerfile

Create `runner/Dockerfile`:

```dockerfile
FROM ubuntu:24.04

ARG RUNNER_VERSION=2.328.0

ENV DEBIAN_FRONTEND=noninteractive
ENV RUNNER_ALLOW_RUNASROOT=1
ENV PATH="/opt/mini-swe-agent-venv/bin:${PATH}"

RUN apt-get update && apt-get install -y \
    bash \
    ca-certificates \
    curl \
    git \
    jq \
    sudo \
    tar \
    unzip \
    zip \
    build-essential \
    python3 \
    python3-pip \
    python3-venv \
    nodejs \
    npm \
    && rm -rf /var/lib/apt/lists/*

RUN mkdir -p -m 755 /etc/apt/keyrings \
    && curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
      | tee /etc/apt/keyrings/githubcli-archive-keyring.gpg >/dev/null \
    && chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
      | tee /etc/apt/sources.list.d/github-cli.list >/dev/null \
    && apt-get update \
    && apt-get install -y gh \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /actions-runner

RUN curl -fsSL -o actions-runner-linux-x64.tar.gz \
      https://github.com/actions/runner/releases/download/v${RUNNER_VERSION}/actions-runner-linux-x64-${RUNNER_VERSION}.tar.gz \
    && tar xzf actions-runner-linux-x64.tar.gz \
    && rm actions-runner-linux-x64.tar.gz \
    && ./bin/installdependencies.sh

RUN python3 -m venv /opt/mini-swe-agent-venv \
    && /opt/mini-swe-agent-venv/bin/python -m pip install --upgrade pip \
    && /opt/mini-swe-agent-venv/bin/python -m pip install mini-swe-agent

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

ENTRYPOINT ["/entrypoint.sh"]
```

## 9. Add the runner entrypoint

Create `runner/entrypoint.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail

if [ -z "${GH_RUNNER_REPO_URL:-}" ]; then
  echo "Missing GH_RUNNER_REPO_URL"
  exit 1
fi

if [ -z "${GH_RUNNER_TOKEN:-}" ]; then
  echo "Missing GH_RUNNER_TOKEN"
  exit 1
fi

RUNNER_NAME="${RUNNER_NAME:-docker-mini-swe-runner}"
RUNNER_LABELS="${RUNNER_LABELS:-self-hosted,linux,docker,mini-swe-agent}"
RUNNER_WORKDIR="${RUNNER_WORKDIR:-_work}"

cleanup() {
  echo "Removing runner registration..."
  ./config.sh remove --unattended --token "${GH_RUNNER_TOKEN}" || true
}

trap cleanup EXIT INT TERM

if [ ! -f ".runner" ]; then
  ./config.sh \
    --url "${GH_RUNNER_REPO_URL}" \
    --token "${GH_RUNNER_TOKEN}" \
    --name "${RUNNER_NAME}" \
    --labels "${RUNNER_LABELS}" \
    --work "${RUNNER_WORKDIR}" \
    --unattended \
    --replace
fi

echo "Verifying installed tools..."
git --version
gh --version
python3 --version
mini --help >/dev/null

echo "Starting GitHub Actions runner..."
./run.sh
```

Make it executable:

```bash
chmod +x runner/entrypoint.sh
```

## 10. Add mini-SWE-agent Ollama config

Create `config/mini-local-ollama.yaml`:

```yaml
agent:
  mode: yolo
  step_limit: 30
  cost_limit: 0

model:
  model_name: "ollama/qwen2.5-coder:7b"
  cost_tracking: "ignore_errors"
  model_kwargs:
    api_base: "http://ollama:11434"
    temperature: 0
    drop_params: true

environment:
  env:
    PAGER: cat
    MANPAGER: cat
    LESS: -R
    PIP_PROGRESS_BAR: "off"
    TQDM_DISABLE: "1"
```

Use `http://ollama:11434`, not `localhost`, because mini-SWE-agent runs in the runner container and Ollama runs as a separate Compose service.

## 11. Add the issue template

Create `.github/ISSUE_TEMPLATE/agent-task.yml`:

```yaml
name: Agent Task
description: Task for autonomous mini-SWE-agent
title: "[Agent]: "
labels:
  - agent:candidate
body:
  - type: textarea
    id: problem
    attributes:
      label: Problem
      description: What needs to be fixed, added, or changed?
      placeholder: Describe the task clearly.
    validations:
      required: true

  - type: textarea
    id: acceptance
    attributes:
      label: Acceptance criteria
      description: What must be true when this is done?
      placeholder: |
        - [ ] The behavior is implemented or fixed
        - [ ] Tests are added or updated if needed
        - [ ] Existing tests pass
    validations:
      required: true

  - type: textarea
    id: context
    attributes:
      label: Context
      description: Relevant files, logs, examples, or constraints.
    validations:
      required: false

  - type: dropdown
    id: risk
    attributes:
      label: Risk level
      options:
        - low
        - medium
        - high
    validations:
      required: true
```

## 12. Add the workflow

Create `.github/workflows/mini-swe-dev-loop.yml`.

Use the workflow in this repository as the source of truth. It:

- runs on `issues.labeled`, `issue_comment.created`, and `workflow_dispatch`;
- requires a self-hosted runner with the `mini-swe-agent` label;
- verifies the trigger actor has `write`, `maintain`, or `admin` permission;
- checks out `agent-dev`;
- confirms Ollama is reachable at `http://ollama:11434/api/tags`;
- builds a prompt from the issue body, labels, and recent comments;
- runs `mini -c /opt/agent-config/mini-local-ollama.yaml`;
- runs lightweight validation when common test files are present;
- commits and pushes changes only to `agent-dev`;
- updates issue labels to `agent:done`, `agent:failed`, or `agent:running`.

Copy the current file from `.github/workflows/mini-swe-dev-loop.yml` in this repository.

## 13. Commit the repository files to `main`

Commit the automation and Docker files to the default branch:

```bash
git checkout main
git add .github config runner docker-compose.yml .gitignore README.md step-by-step.md
git commit -m "Add local mini-SWE agent loop"
git push origin main
```

## 14. Enable GitHub Actions permissions

In GitHub, open:

```text
Repository
-> Settings
-> Actions
-> General
-> Workflow permissions
```

Select **Read and write permissions**, then save.

## 15. Create labels

Create the labels used by the workflow:

```bash
gh label create "agent:candidate" \
  --color "ededed" \
  --description "Candidate task for autonomous mini-SWE-agent"

gh label create "agent:ready" \
  --color "2ea44f" \
  --description "Approved for autonomous mini-SWE-agent run"

gh label create "agent:running" \
  --color "fbca04" \
  --description "mini-SWE-agent is currently working"

gh label create "agent:done" \
  --color "5319e7" \
  --description "mini-SWE-agent pushed changes to dev branch"

gh label create "agent:failed" \
  --color "d73a4a" \
  --description "mini-SWE-agent failed"

gh label create "agent:blocked" \
  --color "b60205" \
  --description "Do not run the agent on this issue"
```

## 16. Register the runner

In GitHub, open:

```text
Repository
-> Settings
-> Actions
-> Runners
-> New self-hosted runner
-> Linux
```

GitHub shows a registration command like:

```bash
./config.sh --url https://github.com/OWNER/REPO --token TOKEN_HERE
```

Create `.env` beside `docker-compose.yml`:

```dotenv
GH_RUNNER_REPO_URL=https://github.com/OWNER/REPO
GH_RUNNER_TOKEN=PASTE_RUNNER_TOKEN_HERE
RUNNER_NAME=docker-mini-swe-runner
```

Runner registration tokens expire quickly, so start the container soon after generating the token.

## 17. Start the local stack

From the repository root:

```bash
docker compose up -d --build
```

Check logs:

```bash
docker compose logs -f ollama
docker compose logs -f github-runner
```

The runner should appear as **Idle** in GitHub after registration.

## 18. Pull and test the Ollama model

Pull the configured model:

```bash
docker exec -it ollama ollama pull qwen2.5-coder:7b
```

Test it:

```bash
docker exec -it ollama ollama run qwen2.5-coder:7b "Write a one-line Python hello world."
```

Confirm model files are on external storage:

```bash
du -sh /mnt/ollama-usb/ollama
ls -lah /mnt/ollama-usb/ollama
```

## 19. Test runner-to-Ollama access

Open a shell in the runner container:

```bash
docker exec -it github-mini-swe-runner bash
```

Inside the container:

```bash
curl http://ollama:11434/api/tags
mini \
  -c /opt/agent-config/mini-local-ollama.yaml \
  -y \
  --exit-immediately \
  -t "Say hello. Do not modify files."
exit
```

## 20. Run the first agent task

Create an issue from the **Agent Task** template.

Example:

```markdown
Problem:
Add a simple README section explaining how to run the project locally.

Acceptance criteria:
- README has a "Local Development" section
- The section includes install and test commands
- Existing content remains unchanged
```

Trigger the agent:

```bash
gh issue edit ISSUE_NUMBER --add-label "agent:ready"
```

Watch:

```text
Repository
-> Actions
-> Mini SWE Agent Dev Branch Loop
```

The workflow should commit any changes to `agent-dev`.

## 21. Rerun an issue

Comment on the issue:

```text
/agent run
```

The workflow runs again and pushes another commit to `agent-dev` if mini-SWE-agent changes files.

You can also run the workflow manually:

```text
Actions
-> Mini SWE Agent Dev Branch Loop
-> Run workflow
-> issue_number = ISSUE_NUMBER
```

## 22. Use a different model

Pull another Ollama model:

```bash
docker exec -it ollama ollama pull qwen2.5-coder:14b
```

Update `config/mini-local-ollama.yaml`:

```yaml
model_name: "ollama/qwen2.5-coder:14b"
```

Restart the runner:

```bash
docker compose restart github-runner
```

## 23. Optional: enable NVIDIA GPU for Ollama

Install NVIDIA Container Toolkit on the host, then add this to the `ollama` service in `docker-compose.yml`:

```yaml
    gpus: all
```

Restart:

```bash
docker compose up -d
```

## 24. Daily operations

| Task | Command |
| --- | --- |
| Start stack | `docker compose up -d` |
| Stop stack | `docker compose down` |
| View runner logs | `docker compose logs -f github-runner` |
| View Ollama logs | `docker compose logs -f ollama` |
| List Ollama models | `docker exec -it ollama ollama list` |
| Pull default model | `docker exec -it ollama ollama pull qwen2.5-coder:7b` |
| Restart runner | `docker compose restart github-runner` |
| Rebuild runner | `docker compose up -d --build github-runner` |

## 25. Operational rules

- Only trusted users should add `agent:ready` or comment `/agent run`.
- Keep `main` protected.
- Review `agent-dev` before merging to `main`.
- Do not store production secrets on the runner host or in the runner container.
- Do not use this runner for public repos with untrusted contributors.
- Run one issue at a time because all changes land on a single dev branch.
- Keep the single workflow concurrency group unless you redesign the branch strategy.

## Result

After setup, the loop is:

```text
1. Create a GitHub issue.
2. Add agent:ready or comment /agent run.
3. GitHub Actions schedules the self-hosted Docker runner.
4. mini-SWE-agent reads the issue.
5. mini-SWE-agent calls Ollama at http://ollama:11434.
6. mini-SWE-agent edits the repository checkout.
7. The workflow commits changes.
8. The workflow pushes directly to agent-dev.
9. The issue is marked agent:done or agent:failed.
```

This setup does not require a Copilot license or paid model API, and the agent never pushes directly to `main`.
