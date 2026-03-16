# CI/CD Pipeline - App Onboarding Guide

All apps should follow this pipeline. Central workflows live in `dubsclaw/cicd` (public repo). App repos are private.

## Architecture

```
git push to main
  -> CI (GitHub cloud runners):
      1. Hadolint (Dockerfile lint)
      2. ESLint / language linter
      3. Tests (npm test)
      4. Docker build (amd64 + arm64)
      5. Trivy scan (CVEs + secrets)
      6. Push image to GHCR
  -> CD (self-hosted runner on Mac Mini):
      7. Pull ARM64 image from GHCR
      8. Sync project files
      9. docker compose up -d
```

CI runs on every push and PR to `main`. CD only runs on `main` after CI passes.

## Repos

- **dubsclaw/cicd** (public) — reusable workflow templates at `.github/workflows/ci.yml` and `cd.yml`
- **App repos** (private) — each app has thin caller workflows that reference the cicd templates

## Onboarding a New App

### 1. Initialize git and create GitHub repo

```bash
cd /path/to/app
git init
git add -A
git commit -m "Initial commit"
gh repo create dubsclaw/<app-name> --private --source=. --push
```

### 2. Add workflow files

Create `.github/workflows/ci.yml`:
```yaml
name: CI

on:
  push:
    branches: [main]
  pull_request:
    branches: [main]
  workflow_dispatch:

jobs:
  ci:
    uses: dubsclaw/cicd/.github/workflows/ci.yml@main
    with:
      image_name: <app-name>
      node_version: "20"
    permissions:
      contents: read
      packages: write
      security-events: write
```

Create `.github/workflows/cd.yml`:
```yaml
name: CD

on:
  workflow_run:
    workflows: [CI]
    types: [completed]
    branches: [main]

jobs:
  cd:
    if: ${{ github.event.workflow_run.conclusion == 'success' }}
    uses: dubsclaw/cicd/.github/workflows/cd.yml@main
    with:
      image_name: <app-name>
      deploy_dir: /Users/dubs/.openclaw/workspace/projects/<app-name>
    permissions:
      contents: read
      packages: write
```

Replace `<app-name>` with the actual app name. Adjust `deploy_dir` if the app lives elsewhere.

### 3. Add lint/scan configs

`.hadolint.yaml`:
```yaml
ignored:
  - DL3018
  - DL3008
  - DL3059
```

`.trivyignore` (add known CVEs to suppress if needed):
```
# Base image vulnerabilities - tracked for update
```

### 4. Update docker-compose.yml

Add an `image:` line with a default that uses GHCR, alongside the existing `build:`:
```yaml
services:
  <app-name>:
    image: ${IMAGE:-ghcr.io/dubsclaw/<app-name>:latest}
    build: .
    ...
```

This lets `docker compose up` use the GHCR image by default (CD sets `IMAGE`), but `docker compose build` still works for local dev.

### 5. Register self-hosted runner

Each repo needs the runner registered (until we move to a GitHub org):
```bash
TOKEN=$(gh api -X POST /repos/dubsclaw/<app-name>/actions/runners/registration-token --jq '.token')
cd /Users/dubs/actions-runner
./config.sh --url https://github.com/dubsclaw/<app-name> --token "$TOKEN" --name mac-mini --labels self-hosted,macOS,ARM64 --unattended --replace
```

Note: the runner at `/Users/dubs/actions-runner` is already running as a macOS service. Re-registering it will switch it to the new repo. To support multiple repos, either:
- Create a GitHub org and register the runner at the org level
- Or set up multiple runner instances in different directories

### 6. Connect GHCR package to repo

After the first successful CI push:
1. Go to https://github.com/dubsclaw?tab=packages
2. Click the new package
3. Package settings -> Manage Actions access -> Add the repo with Write role

### 7. Ensure .env file exists in deploy directory

The CD pipeline syncs code but `.env` is gitignored. Make sure the app's `.env` file exists in the deploy directory before the first deploy.

## Code Quality Rules

The pipeline enforces:
- **Hadolint**: Dockerfile best practices (error threshold)
- **ESLint**: No unused variables/imports, React compiler rules, Next.js rules
- **Trivy**: Blocks on CRITICAL CVEs, warns on HIGH
- **Secrets scan**: Blocks if secrets are found in code

Fix lint errors before pushing to main. The pipeline will reject bad code.

## Non-Node Apps

The CI template defaults to Node.js. For Python or other stacks:
- Set `run_lint: false` and `run_tests: false` in the caller workflow
- Add language-specific lint/test steps before the reusable workflow call
- The Docker build, scan, and push steps work for any Dockerfile

## Key Files

- Runner install: `/Users/dubs/actions-runner/`
- Runner service: `~/Library/LaunchAgents/actions.runner.dubsclaw-triple-r-hub.mac-mini.plist`
- Docker config: OrbStack at `~/.orbstack/run/docker.sock`
- GHCR registry: `ghcr.io/dubsclaw/<app-name>`

## Troubleshooting

- **macOS Keychain errors**: The runner can't access Keychain. Docker auth is handled via temp config files in the CD workflow. Never use `docker login` directly on the runner.
- **ARM64 manifest errors**: CI builds multi-arch (amd64 + arm64). If you see manifest errors, the push step may have failed.
- **docker compose exit 125**: Usually means `DOCKER_CONFIG` is interfering. The CD workflow unsets it before running compose.
