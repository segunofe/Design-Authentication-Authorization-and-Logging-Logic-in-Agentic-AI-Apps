#!/bin/bash

# Deploy AgentCore Runtime with Corporate Identity Pool
# Complete workflow for deploying the Agent with Cognito JWT authentication

# Remove set -e to handle errors manually
# set -e

# Change to the directory where the script is located
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# Silence the @aws/agentcore (Node CLI) migration recommendation banner. The
# workshop deliberately uses the Python bedrock-agentcore-starter-toolkit
# (pinned in requirements.txt) for its `agentcore configure`/`launch` flow with
# customJWTAuthorizer + header allowlist. Migrating to the new declarative CLI
# is a separate, validated effort — see the migration spike. Suppress the noise.
export AGENTCORE_SUPPRESS_RECOMMENDATION=1

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

# Configuration
STACK_NAME="bootstrap-stack"
AGENT_NAME="sec307_agent"
ENTRYPOINT="agent.py"
REQUIREMENTS_FILE="requirements.txt"

echo "=========================================="
echo "AgentCore Runtime Deployment"
echo "=========================================="
echo ""

# Step 0: Check if agentcore CLI is installed
print_status "Step 0: Checking AgentCore CLI installation..."

if ! command -v agentcore &> /dev/null; then
    print_error "AgentCore CLI not found"
    echo ""
    echo "Please install the AgentCore CLI first:"
    echo "  pip install agentcore"
    echo ""
    echo "Or follow the installation instructions from AWS documentation"
    exit 1
else
    print_success "AgentCore CLI is already installed"
fi

# Step 0.5: Check AWS credentials
print_status "Step 0.5: Checking AWS credentials..."

# First, try to get caller identity (works with instance profile, env vars, or AWS config)
if ! aws sts get-caller-identity &>/dev/null; then
    print_error "AWS credentials not configured or invalid"
    print_error "Please ensure one of the following:"
    echo "  - Running on an EC2 instance with an IAM role attached"
    echo "  - AWS credentials configured via 'aws configure'"
    echo "  - Environment variables (AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY) set"
    exit 1
fi

CALLER_IDENTITY=$(aws sts get-caller-identity --query "Arn" --output text 2>/dev/null)
print_status "Current AWS Identity: $CALLER_IDENTITY"

# Check if using instance profile/execution role (preferred for EC2 instances)
if [[ "$CALLER_IDENTITY" == *"assumed-role/"* ]]; then
    ROLE_NAME=$(echo "$CALLER_IDENTITY" | sed -n 's/.*assumed-role\/\([^\/]*\).*/\1/p')
    print_status "Using IAM role: $ROLE_NAME"
    
    # Check if it's a restricted workshop role that needs to be overridden
    if [[ "$CALLER_IDENTITY" == *"code-editor-CodeEditorInstanceBootstrapRole"* ]] || [[ "$CALLER_IDENTITY" == *"assumed-role/TeamRole"* ]] || [[ "$CALLER_IDENTITY" == *"CloudFormation-"* ]]; then
        print_warning "Detected workshop environment role with limited permissions"
        print_warning "Current identity: $CALLER_IDENTITY"
        
        # Check if environment variables are set to override
        if [ -n "$AWS_ACCESS_KEY_ID" ] && [ -n "$AWS_SECRET_ACCESS_KEY" ]; then
            print_status "Environment variables detected - will use those credentials instead"
        else
            print_error "This identity does not have sufficient permissions for AgentCore deployment."
            echo ""
            echo "Please follow these steps:"
            echo ""
            echo "1. Go to your workshop page/dashboard"
            echo "2. Look for 'AWS CLI Credentials' or 'Temporary Credentials' section"
            echo "3. Copy the export commands (they should look like this):"
            echo "   export AWS_ACCESS_KEY_ID=AKIA..."
            echo "   export AWS_SECRET_ACCESS_KEY=..."
            echo "   export AWS_SESSION_TOKEN=..."
            echo ""
            echo "4. Paste and run those commands in this terminal"
            echo "5. Rerun this script"
            echo ""
            print_error "Script stopped. Please configure proper AWS credentials and try again."
            exit 1
        fi
    else
        print_success "Using instance/execution role credentials"
    fi
elif [[ "$CALLER_IDENTITY" == *":user/"* ]]; then
    print_status "Using IAM user credentials"
else
    print_status "Using AWS credentials from configured source"
fi

print_success "AWS credentials are properly configured"

# Step 1: Get AWS Region
AWS_REGION=$(aws configure get region)
if [ -z "$AWS_REGION" ]; then
    AWS_REGION="us-east-1"
fi
print_status "AWS Region: $AWS_REGION"

# Step 2: Fetch Cognito Configuration
print_status "Step 1: Fetching Cognito configuration from CloudFormation..."

# Check if CloudFormation stack exists
if ! aws cloudformation describe-stacks --stack-name "$STACK_NAME" --region "$AWS_REGION" &>/dev/null; then
    print_error "CloudFormation stack '$STACK_NAME' not found in region '$AWS_REGION'"
    print_error "Please ensure the bootstrap stack has been deployed first"
    print_status "Available stacks:"
    aws cloudformation list-stacks --stack-status-filter CREATE_COMPLETE UPDATE_COMPLETE --query "StackSummaries[].StackName" --output table --region "$AWS_REGION" 2>/dev/null || echo "  Unable to list stacks"
    exit 1
fi

USER_POOL_ID=$(aws cloudformation describe-stacks \
    --stack-name "$STACK_NAME" \
    --query "Stacks[0].Outputs[?OutputKey=='CorpUserPoolId'].OutputValue" \
    --output text \
    --region "$AWS_REGION" 2>/dev/null || echo "")

CLIENT_ID=$(aws cloudformation describe-stacks \
    --stack-name "$STACK_NAME" \
    --query "Stacks[0].Outputs[?OutputKey=='CorpUserPoolClientId'].OutputValue" \
    --output text \
    --region "$AWS_REGION" 2>/dev/null || echo "")

if [ -z "$USER_POOL_ID" ] || [ "$USER_POOL_ID" == "None" ]; then
    print_error "Failed to retrieve User Pool ID from stack outputs"
    print_status "Available outputs from stack '$STACK_NAME':"
    aws cloudformation describe-stacks --stack-name "$STACK_NAME" --query "Stacks[0].Outputs[].{Key:OutputKey,Value:OutputValue}" --output table --region "$AWS_REGION" 2>/dev/null || echo "  Unable to list outputs"
    exit 1
fi

if [ -z "$CLIENT_ID" ] || [ "$CLIENT_ID" == "None" ]; then
    print_error "Failed to retrieve Client ID from stack outputs"
    print_status "Available outputs from stack '$STACK_NAME':"
    aws cloudformation describe-stacks --stack-name "$STACK_NAME" --query "Stacks[0].Outputs[].{Key:OutputKey,Value:OutputValue}" --output table --region "$AWS_REGION" 2>/dev/null || echo "  Unable to list outputs"
    exit 1
fi

print_success "User Pool ID: $USER_POOL_ID"
print_success "Client ID: $CLIENT_ID"

DISCOVERY_URL="https://cognito-idp.${AWS_REGION}.amazonaws.com/${USER_POOL_ID}/.well-known/openid-configuration"
print_status "Discovery URL: $DISCOVERY_URL"

# Step 3: Get Execution Role
print_status "Step 2: Getting execution role..."

EXECUTION_ROLE_ARN=$(aws iam get-role \
    --role-name "sec307-agent-identity-agentruntime-execution-role" \
    --query "Role.Arn" \
    --output text 2>/dev/null || echo "")

if [ -z "$EXECUTION_ROLE_ARN" ] || [ "$EXECUTION_ROLE_ARN" == "None" ]; then
    print_warning "Default execution role 'sec307-agent-identity-agentruntime-execution-role' not found"
    print_status "Searching for alternative execution roles..."
    
    # Try to find any role that might work for AgentCore
    ALTERNATIVE_ROLES=$(aws iam list-roles --query "Roles[?contains(RoleName, 'agent') || contains(RoleName, 'runtime')].{RoleName:RoleName,Arn:Arn}" --output table 2>/dev/null || echo "")
    
    if [ -n "$ALTERNATIVE_ROLES" ]; then
        print_status "Found potential execution roles:"
        echo "$ALTERNATIVE_ROLES"
    fi
    
    print_status "Please enter the execution role ARN:"
    read -p "Execution Role ARN: " EXECUTION_ROLE_ARN
    
    if [ -z "$EXECUTION_ROLE_ARN" ]; then
        print_error "Execution role ARN is required"
        exit 1
    fi
fi

print_success "Execution Role: $EXECUTION_ROLE_ARN"

# Step 4: Check required files
print_status "Step 3: Checking required files..."

if [ ! -f "$ENTRYPOINT" ]; then
    print_error "Entrypoint file '$ENTRYPOINT' not found in current directory"
    print_status "Current directory: $(pwd)"
    print_status "Files in current directory:"
    ls -la
    exit 1
fi

if [ ! -f "$REQUIREMENTS_FILE" ]; then
    print_error "Requirements file '$REQUIREMENTS_FILE' not found in current directory"
    print_status "Current directory: $(pwd)"
    print_status "Files in current directory:"
    ls -la
    exit 1
fi

print_success "Required files found: $ENTRYPOINT, $REQUIREMENTS_FILE"

# Step 5: Configure AgentCore
print_status "Step 4: Configuring AgentCore..."

print_status "Running agentcore configure with the following parameters:"
echo "  - Entrypoint: $ENTRYPOINT"
echo "  - Name: $AGENT_NAME"
echo "  - Execution Role: $EXECUTION_ROLE_ARN"
echo "  - Requirements File: $REQUIREMENTS_FILE"
echo "  - Discovery URL: $DISCOVERY_URL"
echo "  - Client ID: $CLIENT_ID"

if agentcore configure \
    --entrypoint "$ENTRYPOINT" \
    --name "$AGENT_NAME" \
    --region "$AWS_REGION" \
    --execution-role "$EXECUTION_ROLE_ARN" \
    --disable-otel \
    --disable-memory \
    --requirements-file "$REQUIREMENTS_FILE" \
    --request-header-allowlist "Authorization" \
    --authorizer-config "{\"customJWTAuthorizer\":{\"discoveryUrl\":\"$DISCOVERY_URL\",\"allowedClients\":[\"$CLIENT_ID\"]}}"; then
    print_success "AgentCore configured successfully"
else
    print_error "Failed to configure AgentCore"
    print_error "Please check the parameters above and try again"
    exit 1
fi

# Step 6: Deploy the runtime
print_status "Step 5: Deploying AgentCore runtime..."

print_status "Building and deploying agent container using CodeBuild..."
print_status "This may take several minutes..."

# Verify AWS credentials are still valid before deployment
print_status "Verifying AWS credentials and permissions..."
if ! aws sts get-caller-identity &>/dev/null; then
    print_error "AWS credentials are no longer valid"
    print_error "Please check your credentials and try again"
    exit 1
fi

CALLER_IDENTITY=$(aws sts get-caller-identity --output json 2>/dev/null)
print_status "AWS Identity: $(echo "$CALLER_IDENTITY" | jq -r '.Arn // .UserId' 2>/dev/null || echo "Unable to parse identity")"

if agentcore launch --auto-update-on-conflict; then
    print_success "AgentCore runtime deployed successfully"
else
    print_error "Failed to deploy AgentCore runtime"
    print_error "Common issues:"
    echo "  1. Insufficient AWS permissions"
    echo "  2. Missing or invalid execution role"
    echo "  3. Network connectivity issues"
    echo "  4. CodeBuild service limits reached"
    print_status "Check CloudWatch logs for more details"
    exit 1
fi

# config.js generation moved to launchAgent.sh (sole canonical writer
# for AGENTCORE_RUNTIME_ARN/ENDPOINT). The CFN ConfigUpdater Lambda in
# bootstrap-stack.yaml writes the Cognito-only stub at deploy time;
# launchAgent.sh overwrites it with the full payload after the runtime
# is deployed.

# Summary
echo ""
echo "=========================================="
echo "Deployment Complete!"
echo "=========================================="
echo ""
print_success "AgentCore has been configured and deployed with Cognito JWT authentication"
echo ""
print_status "Configuration Details:"
echo "  User Pool ID: $USER_POOL_ID"
echo "  Client ID: $CLIENT_ID"
echo "  Region: $AWS_REGION"
echo ""
