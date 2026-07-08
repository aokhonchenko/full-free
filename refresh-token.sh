#!/bin/bash
#
# refresh-token.sh - Refresh Qwen OAuth token and sync to remote server
#
# Usage: ./refresh-token.sh [--no-browser]
#
# This script:
# 1. Refreshes the local Qwen token (usually auto-refreshes without browser)
# 2. Tests that the new token is valid
# 3. Copies it to the remote server (debian)
# 4. Syncs it to live-swe-agent config
#
# If auto-refresh fails, it will prompt you to authenticate via browser.
#

set -e

# Configuration
REMOTE_HOST="${REMOTE_HOST:-debian}"
LOCAL_CREDS="$HOME/.qwen/oauth_creds.json"
REMOTE_CREDS="~/.qwen/oauth_creds.json"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

log_info() { echo -e "${GREEN}✓${NC} $1"; }
log_warn() { echo -e "${YELLOW}⚠${NC} $1"; }
log_error() { echo -e "${RED}✗${NC} $1"; }

# Check if local qwen credentials exist
if [ ! -f "$LOCAL_CREDS" ]; then
    log_error "Local qwen credentials not found at $LOCAL_CREDS"
    echo "   Run 'qwen' to authenticate first."
    exit 1
fi

# Get current token
get_token() {
    python3 -c "import json; print(json.load(open('$LOCAL_CREDS'))['access_token'])" 2>/dev/null
}

# Test token validity
test_token() {
    local token="$1"
    local response=$(curl -s -w "\n%{http_code}" -m 10 -X POST "https://portal.qwen.ai/v1/chat/completions" \
        -H "Authorization: Bearer $token" \
        -H "Content-Type: application/json" \
        -d '{"model": "coder-model", "messages": [{"role": "user", "content": "hi"}], "max_tokens": 1}' 2>/dev/null)
    local http_code=$(echo "$response" | tail -1)
    [ "$http_code" = "200" ]
}

OLD_TOKEN=$(get_token)
echo "Current token: ${OLD_TOKEN:0:20}..."
echo ""

# Step 1: Try to refresh token by running qwen
echo "Step 1: Refreshing token via qwen-cli..."
if echo "test" | timeout 30 qwen >/dev/null 2>&1; then
    log_info "qwen-cli executed successfully"
else
    log_warn "qwen-cli had issues, but token may still have refreshed"
fi

NEW_TOKEN=$(get_token)

if [ "$OLD_TOKEN" = "$NEW_TOKEN" ]; then
    log_warn "Token unchanged after refresh attempt"
else
    log_info "Token changed: ${NEW_TOKEN:0:20}..."
fi
echo ""

# Step 2: Test the token
echo "Step 2: Testing token validity..."
if test_token "$NEW_TOKEN"; then
    log_info "Token is VALID!"
else
    log_error "Token is INVALID or expired"
    echo ""
    echo "The token could not be auto-refreshed."
    echo "Please run 'qwen' interactively to authenticate via browser."
    echo ""
    
    if [ "$1" != "--no-browser" ]; then
        read -p "Would you like to try authenticating now? [y/N] " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            echo "Running qwen interactively..."
            qwen
            NEW_TOKEN=$(get_token)
            if test_token "$NEW_TOKEN"; then
                log_info "Authentication successful!"
            else
                log_error "Authentication failed"
                exit 1
            fi
        else
            exit 1
        fi
    else
        exit 1
    fi
fi
echo ""

# Step 3: Copy to remote server
echo "Step 3: Copying token to remote server ($REMOTE_HOST)..."
if scp -q "$LOCAL_CREDS" "$REMOTE_HOST:$REMOTE_CREDS"; then
    log_info "Token copied to $REMOTE_HOST"
else
    log_error "Failed to copy token to $REMOTE_HOST"
    exit 1
fi
echo ""

# Step 4: Sync to live-swe-agent
echo "Step 4: Syncing token to live-swe-agent on $REMOTE_HOST..."
if ssh "$REMOTE_HOST" "~/sync-qwen-token.sh --force" 2>&1 | grep -q "Token is valid"; then
    log_info "Token synced and validated on remote server!"
else
    ssh "$REMOTE_HOST" "~/sync-qwen-token.sh --force"
fi
echo ""

# Step 5: Clear any token error flags
echo "Step 5: Clearing error flags..."
ssh "$REMOTE_HOST" "rm -f ~/ai_home/state/token_error.flag" 2>/dev/null || true
log_info "Error flags cleared"
echo ""

echo "========================================"
log_info "Token refresh complete!"
echo "========================================"
echo ""
echo "The AI agent will resume normal operation on the next cron run."
