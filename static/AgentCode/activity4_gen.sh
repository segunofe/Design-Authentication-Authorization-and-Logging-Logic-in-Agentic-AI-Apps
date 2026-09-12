#!/bin/bash

# SEC307 Workshop - Activity 4 Generator Script
# Updates agent.py with the Activity 4 (external Inventory MCP server) client
# configuration.
#
# Security note: this script NO LONGER fetches or embeds the Cognito client
# secret. The Inventory MCP client's credentials live in the AgentCore Identity
# vault behind an OAuth2 credential provider created by the bootstrap stack.
# Here we only inject the (non-secret) provider name and the gateway URL; the
# agent exchanges its workload identity for a token at runtime (M2M).

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

print_status()  { echo -e "${BLUE}[INFO]${NC} $1"; }
print_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
print_error()   { echo -e "${RED}[ERROR]${NC} $1"; }
print_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }

# Check if gateway_url parameter is provided
if [ $# -eq 0 ]; then
    print_error "Usage: $0 <gateway_url>"
    print_error "Example: $0 https://gateway-abc123.gateway.us-east-1.aws.dev/mcp"
    exit 1
fi

GATEWAY_URL="$1"

# Safety net: AgentCore Gateway MCP endpoints must end with /mcp.
# Strip any trailing slash, then append /mcp if it is missing.
GATEWAY_URL="${GATEWAY_URL%/}"
if [[ "$GATEWAY_URL" != */mcp ]]; then
    print_warning "Gateway URL did not end with '/mcp'; appending it automatically"
    GATEWAY_URL="${GATEWAY_URL}/mcp"
fi

# Get the directory where this script is located
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Define file paths
SNIPPET_FILE="$SCRIPT_DIR/snippets/activity_4.snip"
AGENT_FILE="$SCRIPT_DIR/agent.py"
TEMP_FILE="$SCRIPT_DIR/temp_activity4.tmp"

print_status "Activity 4 Generator Script - External Inventory MCP Server"
print_status "Gateway URL: $GATEWAY_URL"
print_status "Script Directory: $SCRIPT_DIR"

# Check required files
if [ ! -f "$SNIPPET_FILE" ]; then
    print_error "Snippet file not found: $SNIPPET_FILE"
    exit 1
fi
if [ ! -f "$AGENT_FILE" ]; then
    print_error "Agent file not found: $AGENT_FILE"
    exit 1
fi
print_success "All required files found"

# Step 1: Get AWS region
print_status "Step 1: Detecting AWS region..."
AWS_REGION=$(aws configure get region 2>/dev/null || echo "us-east-1")
print_status "Using AWS region: $AWS_REGION"

# Step 2: Fetch the AgentCore Identity OAuth2 credential provider name
print_status "Step 2: Fetching the Inventory OAuth2 credential provider name from CloudFormation..."

BOOTSTRAP_STACK="bootstrap-stack"

if ! aws cloudformation describe-stacks --stack-name "$BOOTSTRAP_STACK" --region "$AWS_REGION" >/dev/null 2>&1; then
    print_error "Bootstrap stack '$BOOTSTRAP_STACK' not found in region '$AWS_REGION'"
    aws cloudformation list-stacks --stack-status-filter CREATE_COMPLETE UPDATE_COMPLETE --query "StackSummaries[].StackName" --output table --region "$AWS_REGION" 2>/dev/null || echo "  Unable to list stacks"
    exit 1
fi
print_success "Bootstrap stack found"

OAUTH_PROVIDER_NAME=$(aws cloudformation describe-stacks \
    --stack-name "$BOOTSTRAP_STACK" \
    --query "Stacks[0].Outputs[?OutputKey=='InventoryMCPOAuthProviderName'].OutputValue" \
    --output text \
    --region "$AWS_REGION" 2>&1)

if [ $? -ne 0 ] || [ -z "$OAUTH_PROVIDER_NAME" ] || [ "$OAUTH_PROVIDER_NAME" == "None" ]; then
    print_error "Failed to fetch InventoryMCPOAuthProviderName from $BOOTSTRAP_STACK"
    print_status "Available outputs from stack '$BOOTSTRAP_STACK':"
    aws cloudformation describe-stacks --stack-name "$BOOTSTRAP_STACK" --query "Stacks[0].Outputs[].{Key:OutputKey,Value:OutputValue}" --output table --region "$AWS_REGION" 2>/dev/null || echo "  Unable to list outputs"
    exit 1
fi
print_success "Inventory OAuth2 credential provider: $OAUTH_PROVIDER_NAME"

# Step 3: Process the snippet file and replace placeholders
print_status "Step 3: Processing snippet file..."
sed -e "s|###ACTIVITY4_OAUTH_PROVIDER_NAME###|$OAUTH_PROVIDER_NAME|g" \
    -e "s|###ACTIVITY4_GATEWAY_URL###|$GATEWAY_URL|g" \
    "$SNIPPET_FILE" > "$TEMP_FILE"

if [ $? -eq 0 ]; then
    print_success "All placeholders replaced successfully"
else
    print_error "Failed to process snippet file"
    exit 1
fi

# Step 4: Update the agent.py file
print_status "Step 4: Updating agent.py file..."
cp "$AGENT_FILE" "$AGENT_FILE.backup"
print_status "Backup created: $AGENT_FILE.backup"

awk '
BEGIN { in_activity4 = 0; replacement_done = 0 }
/^.*START OF ACTIVITY 4.*$/ {
    print $0
    in_activity4 = 1
    if (!replacement_done) {
        while ((getline line < "'$TEMP_FILE'") > 0) {
            print line
        }
        close("'$TEMP_FILE'")
        replacement_done = 1
    }
    next
}
/^.*END OF ACTIVITY 4.*$/ {
    in_activity4 = 0
    print $0
    next
}
!in_activity4 { print $0 }
' "$AGENT_FILE" > "$AGENT_FILE.new"

if [ $? -eq 0 ]; then
    mv "$AGENT_FILE.new" "$AGENT_FILE"
    print_success "Agent file updated successfully"
else
    print_error "Failed to update agent file"
    mv "$AGENT_FILE.backup" "$AGENT_FILE"
    print_warning "Restored original file from backup"
    exit 1
fi

# Step 5: Clean up
print_status "Step 5: Cleaning up..."
rm -f "$TEMP_FILE"
print_success "Temporary files cleaned up"

# Step 6: Verify the update
print_status "Step 6: Verifying update..."
if grep -q "$OAUTH_PROVIDER_NAME" "$AGENT_FILE"; then
    print_success "AgentCore Identity provider configuration successfully inserted into agent.py"
else
    print_warning "Provider configuration not found in updated file - please verify manually"
fi

if grep -q "START OF ACTIVITY 4" "$AGENT_FILE" && grep -q "END OF ACTIVITY 4" "$AGENT_FILE"; then
    print_success "Activity 4 markers are intact"
else
    print_error "Activity 4 markers missing - file may be corrupted"
    print_warning "Restoring from backup..."
    mv "$AGENT_FILE.backup" "$AGENT_FILE"
    exit 1
fi

print_success "Activity 4 configuration completed successfully!"
print_status "Summary:"
echo "  - Gateway URL: $GATEWAY_URL"
echo "  - AgentCore Identity OAuth2 provider: $OAUTH_PROVIDER_NAME"
echo "  - AWS Region: $AWS_REGION"
echo "  - Updated file: $AGENT_FILE"
echo "  - Backup file: $AGENT_FILE.backup"
echo ""
print_status "Next steps:"
echo "  1. Review the updated agent.py file"
echo "  2. Deploy the updated agent using ./launchAgent.sh"
echo ""
print_success "Script execution completed!"
