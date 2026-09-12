#!/bin/bash

# SEC307 Workshop - Activity 5 Generator Script
# This script updates the agent.py file with Activity 5 configuration
# and replaces the policy store ID placeholder with the CloudFormation export value

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

# Get the directory where this script is located
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Define file paths
SNIPPET_FILE="$SCRIPT_DIR/snippets/activity_5.snip"
AGENT_FILE="$SCRIPT_DIR/agent.py"
TEMP_FILE="$SCRIPT_DIR/temp_activity5.tmp"

print_status "Activity 5 Generator Script"
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

# Step 1: Get the policy store ID from CloudFormation export
print_status "Step 1: Retrieving policy store ID from CloudFormation export..."

POLICY_STORE_ID=$(aws cloudformation list-exports \
    --query "Exports[?Name=='sec307-agent-identity-policy-store-id'].Value" \
    --output text)

if [ -z "$POLICY_STORE_ID" ]; then
    print_error "Failed to retrieve policy store ID from CloudFormation export 'sec307-agent-identity-policy-store-id'"
    print_error "Please ensure the CloudFormation stack has been deployed and the export exists"
    exit 1
fi

print_success "Policy Store ID retrieved: $POLICY_STORE_ID"

# Step 2: Process the snippet file and replace the placeholder
print_status "Step 2: Processing snippet file and replacing placeholder..."

sed "s/###ACTIVITY5_POLICY_STORE###/$POLICY_STORE_ID/g" "$SNIPPET_FILE" > "$TEMP_FILE"

if [ $? -eq 0 ]; then
    print_success "Snippet file processed successfully"
else
    print_error "Failed to process snippet file"
    exit 1
fi

# Step 3: Update the agent.py file
print_status "Step 3: Updating agent.py file..."

# Create a backup of the original file
cp "$AGENT_FILE" "$AGENT_FILE.backup"
print_status "Backup created: $AGENT_FILE.backup"

# Use awk to replace content between the markers
awk '
BEGIN { in_activity5 = 0; replacement_done = 0 }
/^.*START OF ACTIVITY 5.*$/ { 
    print $0
    in_activity5 = 1
    if (!replacement_done) {
        while ((getline line < "'$TEMP_FILE'") > 0) {
            print line
        }
        close("'$TEMP_FILE'")
        replacement_done = 1
    }
    next
}
/^.*END OF ACTIVITY 5.*$/ { 
    in_activity5 = 0
    print $0
    next
}
!in_activity5 { print $0 }
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

# Step 4: Clean up temporary files
print_status "Step 4: Cleaning up..."
rm -f "$TEMP_FILE"
print_success "Temporary files cleaned up"

# Step 5: Verify the update
print_status "Step 5: Verifying update..."

# Check if the policy store ID appears in the file
if grep -q "$POLICY_STORE_ID" "$AGENT_FILE"; then
    print_success "Policy Store ID successfully inserted into agent.py"
else
    print_warning "Policy Store ID not found in updated file - please verify manually"
fi

# Check if Activity 5 markers are still present
if grep -q "START OF ACTIVITY 5" "$AGENT_FILE" && grep -q "END OF ACTIVITY 5" "$AGENT_FILE"; then
    print_success "Activity 5 markers are intact"
else
    print_error "Activity 5 markers missing - file may be corrupted"
    print_warning "Restoring from backup..."
    mv "$AGENT_FILE.backup" "$AGENT_FILE"
    exit 1
fi

print_success "Activity 5 configuration completed successfully!"
print_status "Summary:"
echo "  - Updated file: $AGENT_FILE"
echo "  - Backup file: $AGENT_FILE.backup"
echo "  - Policy Store ID: $POLICY_STORE_ID"
echo "  - Content: Dynamic tool filtering with Verified Permissions"
echo ""
print_status "Next steps:"
echo "  1. Review the updated agent.py file"
echo "  2. Test the dynamic tool filtering"
echo "  3. Deploy the updated agent"
echo ""
print_success "Script execution completed!"
