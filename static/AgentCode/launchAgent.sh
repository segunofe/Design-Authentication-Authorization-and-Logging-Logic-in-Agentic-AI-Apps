#!/bin/bash

# SEC307 Workshop - AgentCore Runtime Launch Script
# This script sets up the environment and deploys the AgentCore runtime with Cognito JWT authentication

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

print_header() {
    echo ""
    echo -e "${CYAN}=========================================="
    echo -e "$1"
    echo -e "==========================================${NC}"
    echo ""
}

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

print_step() {
    echo ""
    echo -e "${CYAN}>>> Step $1: $2${NC}"
    echo ""
}

# Change to script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

print_header "SEC307 Workshop - AgentCore Runtime Setup"

print_status "This script will:"
echo "  1. Set up Python virtual environment"
echo "  2. Install required dependencies"
echo "  3. Configure AgentCore with Cognito JWT authentication"
echo "  4. Deploy the AgentCore runtime"
echo ""

# Check if we should skip venv setup
SKIP_VENV=false
if [ "$1" == "--skip-venv" ]; then
    SKIP_VENV=true
    print_warning "Skipping virtual environment setup (--skip-venv flag detected)"
fi

# Step 1: Check and install python3.12-venv if needed
if [ "$SKIP_VENV" = false ]; then
    print_step "1" "Checking Python virtual environment dependencies"
    
    # Find a suitable Python >= 3.10
    PYTHON_CMD=""
    for cmd in python3.13 python3.12 python3.11 python3.10; do
        if command -v "$cmd" &>/dev/null; then
            PYTHON_CMD="$cmd"
            break
        fi
    done
    
    # If no Python >= 3.10 found, try to install Python 3.12
    if [ -z "$PYTHON_CMD" ]; then
        print_warning "Python 3.10+ not found. Installing Python 3.12..."
        
        if command -v dnf &>/dev/null; then
            # Amazon Linux 2023
            sudo dnf install -y python3.12 python3.12-pip 2>/dev/null || \
            sudo dnf install -y python3.11 python3.11-pip 2>/dev/null || true
        elif command -v yum &>/dev/null; then
            # Amazon Linux 2 / RHEL
            sudo yum install -y python3.12 2>/dev/null || \
            sudo yum install -y python3.11 2>/dev/null || true
        elif command -v apt &>/dev/null; then
            # Debian/Ubuntu
            sudo apt update && sudo apt install -y python3.12 python3.12-venv 2>/dev/null || true
        fi
        
        # Re-check after install
        for cmd in python3.13 python3.12 python3.11 python3.10; do
            if command -v "$cmd" &>/dev/null; then
                PYTHON_CMD="$cmd"
                break
            fi
        done
    fi
    
    if [ -z "$PYTHON_CMD" ]; then
        print_error "Could not find or install Python 3.10+. strands-agents requires Python >= 3.10."
        print_error "System Python version: $(python3 --version 2>&1)"
        exit 1
    fi
    
    print_success "Using $PYTHON_CMD ($($PYTHON_CMD --version 2>&1))"
    
    # Check if venv module is available for the selected Python
    if ! $PYTHON_CMD -c "import venv" 2>/dev/null; then
        print_warning "venv module not available for $PYTHON_CMD, attempting to install..."
        if command -v dnf &>/dev/null; then
            sudo dnf install -y "${PYTHON_CMD}-libs" 2>/dev/null || true
        elif command -v apt &>/dev/null; then
            PYVER=$($PYTHON_CMD --version 2>&1 | grep -oP '\d+\.\d+')
            sudo apt install -y "python${PYVER}-venv" 2>/dev/null || true
        fi
        
        if ! $PYTHON_CMD -c "import venv" 2>/dev/null; then
            print_error "venv module is not available for $PYTHON_CMD"
            exit 1
        fi
    fi
    
    print_success "Python venv module is available"
    
    # Step 2: Create Python virtual environment
    print_step "2" "Setting up Python virtual environment"
    
    if [ -d ".venv" ]; then
        # Check if existing venv uses a compatible Python version
        VENV_PYTHON_VER=$(.venv/bin/python --version 2>&1 | grep -oP '\d+\.\d+' || echo "0.0")
        VENV_MAJOR=$(echo "$VENV_PYTHON_VER" | cut -d. -f1)
        VENV_MINOR=$(echo "$VENV_PYTHON_VER" | cut -d. -f2)
        if [ "$VENV_MAJOR" -lt 3 ] || ([ "$VENV_MAJOR" -eq 3 ] && [ "$VENV_MINOR" -lt 10 ]); then
            print_warning "Existing venv uses Python $VENV_PYTHON_VER (< 3.10). Recreating..."
            rm -rf .venv
        else
            print_status "Existing virtual environment uses Python $VENV_PYTHON_VER"
        fi
    fi
    
    if [ ! -d ".venv" ]; then
        print_status "Creating Python virtual environment with $PYTHON_CMD..."
        $PYTHON_CMD -m venv .venv
        print_success "Virtual environment created"
    fi
    
    # Step 3: Activate virtual environment
    print_step "3" "Activating virtual environment"
    
    print_status "Activating .venv/bin/activate..."
    source .venv/bin/activate
    print_success "Virtual environment activated"
    
    # Step 4: Upgrade pip
    print_step "4" "Upgrading pip"
    
    print_status "Upgrading pip to latest version..."
    pip install --upgrade pip --quiet
    print_success "pip upgraded successfully"
    
    # Step 5: Install dependencies
    print_step "5" "Installing Python dependencies"
    
    print_status "Installing required packages"
    echo ""
    
    pip install -r requirements.txt --quiet
    print_success "All dependencies installed successfully"
else
    print_step "1-5" "Skipping virtual environment setup"
    print_warning "Make sure you have the required packages installed"
fi

# Step 6: Configure AgentCore
print_step "6" "Configuring AgentCore with Cognito JWT authentication"

print_status "Running deploy-agentcore-runtime.sh..."
echo ""

if [ -f "./deploy-agentcore-runtime.sh" ]; then
    chmod +x ./deploy-agentcore-runtime.sh
    if ./deploy-agentcore-runtime.sh; then
        print_success "AgentCore configuration and deployment completed successfully"
    else
        print_error "AgentCore configuration and deployment failed"
        print_error "Please check the error messages above and try again"
        exit 1
    fi
else
    print_error "deploy-agentcore-runtime.sh not found!"
    exit 1
fi

# Step 7: Generate config.js file
print_step "7" "Generating frontend config.js file"

print_status "Fetching configuration from CloudFormation and AgentCore..."

STACK_NAME="bootstrap-stack"
AWS_REGION=$(aws configure get region || echo "us-east-1")

S3_BUCKET_NAME=$(aws cloudformation describe-stacks \
    --stack-name "$STACK_NAME" \
    --query "Stacks[0].Outputs[?OutputKey=='S3BucketName'].OutputValue" \
    --output text \
    --region "$AWS_REGION" 2>/dev/null || echo "")

# CloudFront distribution that fronts the S3 bucket. Needed so we can bust the
# cache after re-uploading config.js below — otherwise CloudFront keeps serving
# the stale Cognito-only stub (DefaultTTL is 24h on the CachingOptimized policy)
# and the SPA logs in with an empty clientId.
CLOUDFRONT_DISTRIBUTION_ID=$(aws cloudformation describe-stacks \
    --stack-name "$STACK_NAME" \
    --query "Stacks[0].Outputs[?OutputKey=='CloudFrontDistributionId'].OutputValue" \
    --output text \
    --region "$AWS_REGION" 2>/dev/null || echo "")

# Get Cognito configuration from CloudFormation
STACK_NAME="bootstrap-stack"
AWS_REGION=$(aws configure get region || echo "us-east-1")

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

# Get AgentCore Runtime ARN
# Use COLUMNS=500 to prevent line wrapping in narrow terminals
AGENT_ARN=$(COLUMNS=500 agentcore status --agent sec307_agent 2>/dev/null | tr -d '\n' | sed -n 's/.*Agent ARN: \([^[:space:]]*\).*/\1/p')

if [ -z "$USER_POOL_ID" ] || [ -z "$CLIENT_ID" ]; then
    print_warning "Could not fetch Cognito configuration from CloudFormation"
    print_status "Using placeholder values in config.js"
    USER_POOL_ID="YOUR_USER_POOL_ID"
    CLIENT_ID="YOUR_CLIENT_ID"
fi

if [ -z "$AGENT_ARN" ]; then
    print_warning "Could not fetch AgentCore Runtime ARN"
    print_status "Using placeholder value in config.js"
    AGENT_ARN="YOUR_AGENTCORE_RUNTIME_ARN"
fi

# Generate config.js file
CONFIG_FILE="./config.js"

cat > "$CONFIG_FILE" << EOF
// Configuration file - Generated by launchAgent.sh
// Copy this to your frontend application's public directory

window.WORKSHOP_CONFIG = {
    COGNITO_USER_POOL_ID: '${USER_POOL_ID}',
    COGNITO_CLIENT_ID: '${CLIENT_ID}',
    S3_BUCKET_NAME: '${S3_BUCKET_NAME}',
    COGNITO_REGION: '${AWS_REGION}',
    AGENTCORE_RUNTIME_ARN: '${AGENT_ARN}',
    AGENTCORE_ENDPOINT: 'https://bedrock-agentcore.${AWS_REGION}.amazonaws.com',
};
EOF

print_success "config.js file generated successfully!"
print_status "Location: ${CYAN}${CONFIG_FILE}${NC}"
echo ""

aws s3 cp ${CONFIG_FILE} s3://${S3_BUCKET_NAME}/public/
aws s3 cp ${CONFIG_FILE} s3://${S3_BUCKET_NAME}/

print_success "config.js file synched with S3 successfully!"
print_status "Location: ${CYAN}s3://${S3_BUCKET_NAME}/${CONFIG_FILE}${NC}"
echo ""

# Bust the CloudFront cache so the browser fetches the config.js we just wrote
# instead of the stale stub the bootstrap stack seeded at deploy time. This is
# fire-and-forget on purpose: the WSParticipantRole is granted
# cloudfront:CreateInvalidation but NOT GetInvalidation, so we must not poll or
# `aws cloudfront wait` here (it would error). The invalidation completes on
# CloudFront's side in under a minute regardless.
if [ -n "$CLOUDFRONT_DISTRIBUTION_ID" ]; then
    print_status "Invalidating CloudFront cache for config.js (distribution ${CLOUDFRONT_DISTRIBUTION_ID})..."
    if aws cloudfront create-invalidation \
        --distribution-id "$CLOUDFRONT_DISTRIBUTION_ID" \
        --paths "/config.js" "/public/config.js" \
        --query "Invalidation.Id" --output text 2>/dev/null; then
        print_success "CloudFront invalidation requested — give it ~60s, then hard-refresh the app tab."
    else
        print_warning "Could not invalidate CloudFront automatically."
        print_status "If login shows an empty clientId, hard-refresh (Cmd/Ctrl+Shift+R) after a minute."
    fi
else
    print_warning "CloudFront distribution ID not found — skipping cache invalidation."
fi
echo ""

# Final Summary
print_header "Deployment Complete!"

print_header "Setup Complete!"
