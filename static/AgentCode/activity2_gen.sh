#!/bin/bash

# SEC307 Workshop - Activity 2 Generator Script
# This script updates the agent.py file with Activity 2 MCP client configuration

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

print_status() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

print_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

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
SNIPPET_FILE="$SCRIPT_DIR/snippets/activity_2.snip"
AGENT_FILE="$SCRIPT_DIR/agent.py"
TEMP_FILE="$SCRIPT_DIR/temp_activity2.tmp"

print_status "Activity 2 Generator Script"
print_status "Gateway URL: $GATEWAY_URL"
print_status "Script Directory: $SCRIPT_DIR"

# Check if snippet file exists
if [ ! -f "$SNIPPET_FILE" ]; then
    print_error "Snippet file not found: $SNIPPET_FILE"
    exit 1
fi

# Check if agent.py file exists
if [ ! -f "$AGENT_FILE" ]; then
    print_error "Agent file not found: $AGENT_FILE"
    exit 1
fi

print_success "All required files found"

# Step 1: Read the snippet file and replace the placeholder
print_status "Step 1: Processing snippet file..."

# Read the snippet file and replace ###GATEWAY_URL### with the provided URL
sed "s|###GATEWAY_URL###|$GATEWAY_URL|g" "$SNIPPET_FILE" > "$TEMP_FILE"

if [ $? -eq 0 ]; then
    print_success "Placeholder replaced successfully"
else
    print_error "Failed to process snippet file"
    exit 1
fi

# Step 2: Update the agent.py file
print_status "Step 2: Updating agent.py file..."

# Create a backup of the original file
cp "$AGENT_FILE" "$AGENT_FILE.backup"
print_status "Backup created: $AGENT_FILE.backup"

# Use awk to replace content between the markers
awk '
BEGIN { in_activity2 = 0; replacement_done = 0 }
/^.*START OF ACTIVITY 2.*$/ { 
    print $0
    in_activity2 = 1
    if (!replacement_done) {
        while ((getline line < "'$TEMP_FILE'") > 0) {
            print line
        }
        close("'$TEMP_FILE'")
        replacement_done = 1
    }
    next
}
/^.*END OF ACTIVITY 2.*$/ { 
    in_activity2 = 0
    print $0
    next
}
!in_activity2 { print $0 }
' "$AGENT_FILE" > "$AGENT_FILE.new"

# Check if the awk command was successful
if [ $? -eq 0 ]; then
    # Replace the original file with the updated one
    mv "$AGENT_FILE.new" "$AGENT_FILE"
    print_success "Agent file updated successfully"
else
    print_error "Failed to update agent file"
    # Restore from backup
    mv "$AGENT_FILE.backup" "$AGENT_FILE"
    print_warning "Restored original file from backup"
    exit 1
fi

# Step 3: Clean up temporary files
print_status "Step 3: Cleaning up..."
rm -f "$TEMP_FILE"
print_success "Temporary files cleaned up"

# Step 4: Verify the update
print_status "Step 4: Verifying update..."

# Check if the gateway URL appears in the file
if grep -q "$GATEWAY_URL" "$AGENT_FILE"; then
    print_success "Gateway URL successfully inserted into agent.py"
else
    print_warning "Gateway URL not found in updated file - please verify manually"
fi

# Check if Activity 2 markers are still present
if grep -q "START OF ACTIVITY 2" "$AGENT_FILE" && grep -q "END OF ACTIVITY 2" "$AGENT_FILE"; then
    print_success "Activity 2 markers are intact"
else
    print_error "Activity 2 markers missing - file may be corrupted"
    print_warning "Restoring from backup..."
    mv "$AGENT_FILE.backup" "$AGENT_FILE"
    exit 1
fi

print_success "Activity 2 configuration completed successfully!"
print_status "Summary:"
echo "  - Gateway URL: $GATEWAY_URL"
echo "  - Updated file: $AGENT_FILE"
echo "  - Backup file: $AGENT_FILE.backup"
echo ""
print_status "Next steps:"
echo "  1. Review the updated agent.py file"
echo "  2. Test the MCP client connection"
echo "  3. Deploy the updated agent"
echo ""
print_success "Script execution completed!"