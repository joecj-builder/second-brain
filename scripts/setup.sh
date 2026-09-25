#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"

echo "=== Second Brain Setup ==="
echo ""

# Check for config
CONFIG_FILE="${1:-../work-automation/config.yaml}"
if [ ! -f "$CONFIG_FILE" ]; then
    echo "Config file not found at $CONFIG_FILE"
    echo "Copy config.example.yaml to your work-automation repo as config.yaml and fill in your values."
    exit 1
fi

# Simple YAML parsing (vault path)
VAULT_PATH=$(grep 'path:' "$CONFIG_FILE" | head -1 | awk '{print $2}' | sed "s|~|$HOME|")

echo "Vault path: $VAULT_PATH"

# Create vault structure if it doesn't exist
if [ ! -d "$VAULT_PATH" ]; then
    echo "Creating vault at $VAULT_PATH..."
    cp -r "$REPO_DIR/plugins/second-brain/vault-template/" "$VAULT_PATH"
    echo "Vault created. Fill in Onboarding.md with your details."
else
    echo "Vault already exists at $VAULT_PATH — skipping."
fi

# Create .obsidianignore if needed
IGNORE_FILE="$VAULT_PATH/.obsidianignore"
if [ ! -f "$IGNORE_FILE" ] || ! grep -q "^Skills/" "$IGNORE_FILE"; then
    echo "Skills/" >> "$IGNORE_FILE"
    echo "Added Skills/ to .obsidianignore"
fi

echo ""
echo "=== Setup Complete ==="
echo ""
echo "Next steps:"
echo "1. Open $VAULT_PATH in Obsidian"
echo "2. Fill in Onboarding.md with your details"
echo "3. Create scheduled tasks with Claude Code's /schedule command"
echo "4. (Optional) Install the Slack screenshot LaunchAgent from scripts/"
