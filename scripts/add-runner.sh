#!/bin/bash
# Usage: ./add-runner.sh <repo-name>
# Example: ./add-runner.sh hearth
#
# Sets up a new self-hosted GitHub Actions runner for a repo.
# Each repo gets its own runner instance in ~/actions-runners/<repo-name>/

set -euo pipefail

REPO_NAME="${1:?Usage: ./add-runner.sh <repo-name>}"
GITHUB_USER="dubsclaw"
RUNNER_BASE="$HOME/actions-runners"
RUNNER_DIR="$RUNNER_BASE/$REPO_NAME"
RUNNER_VERSION="2.322.0"
RUNNER_ARCHIVE="actions-runner-osx-arm64-${RUNNER_VERSION}.tar.gz"
RUNNER_URL="https://github.com/actions/runner/releases/download/v${RUNNER_VERSION}/${RUNNER_ARCHIVE}"

# Check if runner already exists
if [ -d "$RUNNER_DIR" ] && [ -f "$RUNNER_DIR/.runner" ]; then
  echo "Runner already exists at $RUNNER_DIR"
  echo "To re-register, first run: cd $RUNNER_DIR && ./svc.sh stop && ./svc.sh uninstall"
  exit 1
fi

# Create runner directory
mkdir -p "$RUNNER_DIR"

# Download runner if not cached
CACHE_DIR="$RUNNER_BASE/.cache"
mkdir -p "$CACHE_DIR"
if [ ! -f "$CACHE_DIR/$RUNNER_ARCHIVE" ]; then
  echo "Downloading GitHub Actions runner v${RUNNER_VERSION}..."
  curl -sL -o "$CACHE_DIR/$RUNNER_ARCHIVE" "$RUNNER_URL"
fi

# Extract runner
echo "Extracting runner to $RUNNER_DIR..."
tar xzf "$CACHE_DIR/$RUNNER_ARCHIVE" -C "$RUNNER_DIR"

# Get registration token
echo "Getting registration token for $GITHUB_USER/$REPO_NAME..."
TOKEN=$(gh api -X POST "/repos/$GITHUB_USER/$REPO_NAME/actions/runners/registration-token" --jq '.token')

# Register runner
echo "Registering runner..."
cd "$RUNNER_DIR"
./config.sh \
  --url "https://github.com/$GITHUB_USER/$REPO_NAME" \
  --token "$TOKEN" \
  --name "mac-mini-$REPO_NAME" \
  --labels "self-hosted,macOS,ARM64" \
  --unattended

# Install and start as service
echo "Installing runner as macOS service..."
./svc.sh install
./svc.sh start

echo ""
echo "Runner 'mac-mini-$REPO_NAME' is running for $GITHUB_USER/$REPO_NAME"
echo "Service: ~/Library/LaunchAgents/actions.runner.$GITHUB_USER-$REPO_NAME.mac-mini-$REPO_NAME.plist"
