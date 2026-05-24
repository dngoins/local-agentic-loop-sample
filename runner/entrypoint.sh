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
