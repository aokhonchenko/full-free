#!/bin/bash
# sync-qwen-token.sh - Sync qwen-cli OAuth token to live-SWE-agent config
# Usage: ~/sync-qwen-token.sh [--force]
#   --force: Skip early exit when token unchanged, always test validity

set -e

FORCE_TEST=false
if [ "$1" = "--force" ]; then
    FORCE_TEST=true
fi

QWEN_CREDS="$HOME/.qwen/oauth_creds.json"
SWE_ENV="$HOME/.config/mini-swe-agent/.env"

# Check if qwen credentials exist
if [ ! -f "$QWEN_CREDS" ]; then
    echo "❌ Error: qwen-cli credentials not found at $QWEN_CREDS"
    echo "   Run qwen on a machine with a browser to authenticate first."
    exit 1
fi

# Extract the access token using python
NEW_TOKEN=$(python3 << PYEOF
import json
with open("$QWEN_CREDS") as f:
    data = json.load(f)
    print(data["access_token"])
PYEOF
)

if [ -z "$NEW_TOKEN" ]; then
    echo "❌ Error: Could not extract access_token from $QWEN_CREDS"
    exit 1
fi

# Check if live-SWE-agent config exists
if [ ! -f "$SWE_ENV" ]; then
    echo "⚠️  live-SWE-agent config not found. Creating new one..."
    mkdir -p "$(dirname "$SWE_ENV")"
    cat > "$SWE_ENV" << ENVEOF
OPENAI_API_KEY=$NEW_TOKEN
OPENAI_BASE_URL=https://portal.qwen.ai/v1
MSWEA_MODEL_NAME=openai/coder-model
MSWEA_CONFIGURED=true
MSWEA_COST_TRACKING=ignore_errors
ENVEOF
    echo "✅ Created new config at $SWE_ENV"
else
    # Update existing config
    OLD_TOKEN=$(grep "^OPENAI_API_KEY=" "$SWE_ENV" | cut -d= -f2)
    
    if [ "$OLD_TOKEN" = "$NEW_TOKEN" ] && [ "$FORCE_TEST" = "false" ]; then
        echo "✅ Token is already up to date. No changes needed."
        echo "   Use --force to test token validity anyway."
        exit 0
    fi
    
    if [ "$OLD_TOKEN" = "$NEW_TOKEN" ]; then
        echo "ℹ️  Token unchanged, but --force specified. Testing validity..."
    else
        sed -i "s|^OPENAI_API_KEY=.*|OPENAI_API_KEY=$NEW_TOKEN|" "$SWE_ENV"
        echo "✅ Token updated successfully!"
        echo "   Old: ${OLD_TOKEN:0:20}..."
        echo "   New: ${NEW_TOKEN:0:20}..."
    fi
fi

# Function to test token validity
test_token() {
    local token="$1"
    RESPONSE=$(curl -s -w "\n%{http_code}" -X POST "https://portal.qwen.ai/v1/chat/completions" \
        -H "Authorization: Bearer $token" \
        -H "Content-Type: application/json" \
        -d "{\"model\": \"coder-model\", \"messages\": [{\"role\": \"user\", \"content\": \"hi\"}], \"max_tokens\": 5}")
    
    HTTP_CODE=$(echo "$RESPONSE" | tail -1)
    BODY=$(echo "$RESPONSE" | head -n -1)
    
    if [ "$HTTP_CODE" = "200" ]; then
        return 0
    else
        return 1
    fi
}

# Function to extract token from qwen credentials
extract_token() {
    python3 << PYEOF
import json
with open("$QWEN_CREDS") as f:
    data = json.load(f)
    print(data["access_token"])
PYEOF
}

# Function to refresh token using qwen-cli
refresh_token_via_qwen_cli() {
    echo "🔄 Refreshing token via qwen-cli..."
    # Run a minimal qwen command to trigger token refresh
    # The --no-stream and short prompt minimize cost
    echo "hi" | qwen --no-stream 2>/dev/null || true
    echo "   Token refresh attempted."
}

# Verify the token works
echo ""
echo "🔍 Testing token validity..."

if test_token "$NEW_TOKEN"; then
    echo "✅ Token is valid! API responded successfully."
else
    echo "⚠️  Token appears to be expired or invalid. HTTP code: $HTTP_CODE"
    echo "   Attempting to refresh via qwen-cli..."
    
    # Refresh token using qwen-cli
    refresh_token_via_qwen_cli
    
    # Re-extract the (hopefully refreshed) token
    NEW_TOKEN=$(extract_token)
    
    if [ -z "$NEW_TOKEN" ]; then
        echo "❌ Error: Could not extract refreshed token"
        exit 1
    fi
    
    # Update the config with refreshed token
    sed -i "s|^OPENAI_API_KEY=.*|OPENAI_API_KEY=$NEW_TOKEN|" "$SWE_ENV"
    echo "   Updated config with refreshed token: ${NEW_TOKEN:0:20}..."
    
    # Test again
    echo ""
    echo "🔍 Re-testing refreshed token..."
    if test_token "$NEW_TOKEN"; then
        echo "✅ Refreshed token is valid! API responded successfully."
    else
        echo "❌ Token still invalid after refresh! HTTP code: $HTTP_CODE"
        echo "   Response: $BODY"
        echo ""
        echo "   You may need to re-authenticate qwen-cli on a machine with a browser."
        exit 1
    fi
fi
