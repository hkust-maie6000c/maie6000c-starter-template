#!/usr/bin/env bash
set -euo pipefail

SOURCE_REPO="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
WORKDIR="$(mktemp -d)"
REHEARSAL_DIR="${WORKDIR}/rehearsal"
KEEP_REHEARSAL="${KEEP_REHEARSAL:-false}"

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "Missing required command: $1" >&2
    exit 1
  }
}

cleanup() {
  if [[ -d "${REHEARSAL_DIR}" ]]; then
    (
      cd "${REHEARSAL_DIR}" &&
      docker compose down -v --remove-orphans >/dev/null 2>&1 || true
    )
  fi

  if [[ "${KEEP_REHEARSAL}" != "true" ]]; then
    rm -rf "${WORKDIR}"
  fi
}
trap cleanup EXIT

wait_for_url() {
  local url="$1"
  local timeout_seconds="$2"
  local started_at
  started_at="$(date +%s)"

  while true; do
    if python - <<PY
import sys
import urllib.request

url = "${url}"
try:
    with urllib.request.urlopen(url, timeout=3) as response:
        sys.exit(0 if response.status == 200 else 1)
except Exception:
    sys.exit(1)
PY
    then
      return 0
    fi

    if (( "$(date +%s)" - started_at >= timeout_seconds )); then
      echo "Timed out waiting for ${url}" >&2
      exit 1
    fi

    sleep 2
  done
}

echo "Checking required commands..."
require_cmd git
require_cmd docker
require_cmd python

docker compose version >/dev/null 2>&1 || {
  echo "docker compose is required." >&2
  exit 1
}

echo "Creating throwaway rehearsal clone..."
git clone "${SOURCE_REPO}" "${REHEARSAL_DIR}"

cd "${REHEARSAL_DIR}"

git config user.name "Student Walkthrough"
git config user.email "student-walkthrough@example.com"

cp .env.example .env

echo "Creating temporary virtual environment..."
python -m venv .venv-walkthrough
# shellcheck disable=SC1091
source .venv-walkthrough/bin/activate
python -m pip install --upgrade pip
pip install -e .[dev]

echo "Starting Docker stack..."
docker compose up -d --build

echo "Waiting for services to become healthy..."
wait_for_url "http://localhost:8100/health/ready" 90
wait_for_url "http://localhost:8000/health/ready" 90

echo "Running unit and integration tests..."
pytest -q tests/unit tests/integration

echo "Running smoke test..."
SMOKE_BASE_URL=http://localhost:8000 pytest tests/smoke -q

echo "Seeding demo data..."
docker compose run --rm api python scripts/seed_demo_data.py

echo "Preparing mock milestone artifacts..."
mkdir -p submissions/week03
cp templates/submissions/week03-README-template.md submissions/week03/README.md
cp templates/submissions/week04-README-template.md submissions/week04/README.md
cp templates/submissions/week07-README-template.md submissions/week07/README.md
cp templates/submissions/week13-README-template.md submissions/week13/README.md
cp templates/submissions/final-technical-brief-template.md submissions/week13/final-technical-brief.md
cp templates/ai-use-statement.md submissions/week13/ai-use-statement.md

git checkout -b walkthrough-self-check

echo "Walkthrough checkpoint completed." >> submissions/week03/README.md
git add submissions/week03/README.md
git commit -m "Complete walkthrough Week 03 readiness checkpoint"
git tag w03-readiness

echo "Walkthrough checkpoint completed." >> submissions/week04/README.md
git add submissions/week04/README.md
git commit -m "Complete walkthrough Week 04 proposal checkpoint"
git tag w04-proposal

echo "Walkthrough checkpoint completed." >> submissions/week07/README.md
git add submissions/week07/README.md
git commit -m "Complete walkthrough Week 07 midterm checkpoint"
git tag w07-midterm

echo "Walkthrough checkpoint completed." >> submissions/week13/README.md
git add submissions/week13/README.md submissions/week13/final-technical-brief.md submissions/week13/ai-use-statement.md
git commit -m "Complete walkthrough Week 13 final checkpoint"
git tag w13-final

deactivate

echo
echo "Student rehearsal completed successfully."
echo "Local milestone tags created:"
git tag --list 'w*'

if [[ "${KEEP_REHEARSAL}" == "true" ]]; then
  echo "Rehearsal repository kept at: ${REHEARSAL_DIR}"
else
  echo "Temporary rehearsal repository will be removed on exit."
fi
