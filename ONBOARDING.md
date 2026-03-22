# CI/CD Pipeline - App Onboarding Guide

All apps should follow this pipeline. Central workflows live in `dubsclaw/cicd` (public repo). App repos are private.

## Architecture

```
git push to main
  -> CI (GitHub cloud runners, ~45s parallel):
      1. Branch naming check (advisory warning)
      2. Hadolint (Dockerfile lint)
      3. ESLint / language linter
      4. Tests (npm test)
      5. Secrets scan (Trivy)
  -> CD (self-hosted runner on Mac Mini, ~2 min):
      6. Native ARM64 Docker build
      7. Trivy image scan (CVEs)
      8. Push image to GHCR
      9. Sync project files
      10. docker compose up -d
      11. Deploy notification (Discord/Slack/Teams)
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

### 2. Add PR template

```bash
mkdir -p .github
cp /Users/dubs/apps/cicd/.github/pull_request_template.md .github/pull_request_template.md
```

This ensures every PR links back to a backlog issue and follows a consistent format.

### 3. Add workflow files

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
    secrets:
      NOTIFY_WEBHOOK_URL: ${{ secrets.NOTIFY_WEBHOOK_URL }}
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

Each app gets its own runner instance. Run the setup script:
```bash
/Users/dubs/apps/cicd/scripts/add-runner.sh <app-name>
```

This will:
- Create a runner at `~/actions-runners/<app-name>/`
- Register it with `dubsclaw/<app-name>` on GitHub
- Install and start it as a macOS LaunchAgent service
- Label it `self-hosted,macOS,ARM64`

The runner survives reboots. To manage it:
```bash
cd ~/actions-runners/<app-name>
./svc.sh status   # check status
./svc.sh stop     # stop
./svc.sh start    # start
./svc.sh uninstall && rm -rf ~/actions-runners/<app-name>  # remove
```

### 6. Connect GHCR package to repo

After the first successful CD build/push:
1. Go to https://github.com/dubsclaw?tab=packages
2. Click the new package
3. Package settings -> Manage Actions access -> Add the repo with Write role

### 7. Add deploy notification webhook (optional)

To get deploy notifications in Discord/Slack/Teams:

1. Create a webhook in your messaging tool:
   - **Discord**: Server Settings → Integrations → Webhooks → New Webhook
   - **Slack**: Create an Incoming Webhook app
   - **Teams**: Channel → Connectors → Incoming Webhook

2. Add it as a repo secret:
   ```bash
   gh secret set NOTIFY_WEBHOOK_URL --repo dubsclaw/<app-name>
   # Paste the webhook URL when prompted
   ```

3. The CD workflow defaults to Discord format. To change, add `notify_format` to the caller:
   ```yaml
   with:
     notify_format: "teams"  # or "slack"
   ```

### 8. Set up branch protection

For public repos, create a ruleset requiring PRs to main:

```bash
gh api repos/dubsclaw/<app-name>/rulesets --method POST --input - <<'EOF'
{
  "name": "Protect main",
  "target": "branch",
  "enforcement": "active",
  "conditions": {
    "ref_name": {
      "include": ["refs/heads/main"],
      "exclude": []
    }
  },
  "rules": [
    {
      "type": "pull_request",
      "parameters": {
        "required_approving_review_count": 0,
        "dismiss_stale_reviews_on_push": false,
        "require_code_owner_review": false,
        "require_last_push_approval": false,
        "required_review_thread_resolution": false
      }
    }
  ]
}
EOF
```

> **Note:** Branch protection and rulesets require GitHub Pro for private repos on personal accounts. Use a GitHub Organization (free tier) to get branch protection on private repos.

### 9. Ensure .env file exists in deploy directory

The CD pipeline syncs code but `.env` is gitignored. Make sure the app's `.env` file exists in the deploy directory before the first deploy.

## Code Quality Rules

The pipeline enforces:
- **Hadolint**: Dockerfile best practices (error threshold)
- **ESLint**: No unused variables/imports, React compiler rules, Next.js rules
- **Trivy**: Blocks on CRITICAL CVEs in Docker images
- **Secrets scan**: Blocks if secrets are found in code

Fix lint errors before pushing to main. The pipeline will reject bad code.

## Non-Node Apps

The CI template defaults to Node.js. For Python or other stacks:
- Set `run_lint: false` and `run_tests: false` in the caller workflow
- Add language-specific lint/test steps before the reusable workflow call
- The Docker build, scan, and push steps work for any Dockerfile

## Key Files

- Runner script: `/Users/dubs/apps/cicd/scripts/add-runner.sh`
- Runner installs: `~/actions-runners/<app-name>/`
- Runner services: `~/Library/LaunchAgents/actions.runner.dubsclaw-<app-name>.*.plist`
- Docker: OrbStack at `~/.orbstack/run/docker.sock`
- GHCR registry: `ghcr.io/dubsclaw/<app-name>`

## Troubleshooting

- **macOS Keychain errors**: The runner can't access Keychain. Docker auth is handled via temp config files in the CD workflow. Never use `docker login` directly on the runner.
- **docker compose exit 125**: Usually means `DOCKER_CONFIG` is interfering. The CD workflow unsets it before running compose.
- **Trivy not found**: The CD workflow installs Trivy via `brew` on first run. If brew isn't available, install Trivy manually.
- **Runner offline**: Check `cd ~/actions-runners/<app-name> && ./svc.sh status`. Restart with `./svc.sh start`.
