#!/bin/bash

# CDK Deployment Script for HarborMind
# Deploys AWS CDK stacks for platform admin and/or customer app
#
# Usage:
#   ./deploy-cdk.sh [environment] [deploy_type] [options]
#
# Arguments:
#   environment    - Environment to deploy to: dev, staging, or prod (default: dev)
#   deploy_type    - What to deploy: platform, customer, or both (default: both)
#   options        - Additional CDK options (e.g., --require-approval never)
#
# Environment Variables:
#   AWS_PROFILE    - AWS profile to use (default: default)
#   AWS_REGION     - AWS region (default: us-east-1)
#
# Examples:
#   # Deploy both CDK projects to dev
#   ./deploy-cdk.sh dev both
#
#   # Deploy only platform admin to prod without approval
#   ./deploy-cdk.sh prod platform --require-approval never
#
#   # Deploy customer app to staging with specific profile
#   AWS_PROFILE=staging-profile ./deploy-cdk.sh staging customer

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Default values
ENVIRONMENT=${1:-dev}
DEPLOY_TYPE=${2:-both}
CDK_OPTIONS=${@:3}
AWS_REGION=${AWS_REGION:-us-east-1}
AWS_PROFILE=${AWS_PROFILE:-default}

# Script directory
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
PROJECT_ROOT="${SCRIPT_DIR}/.."

# CDK directories
PLATFORM_CDK_DIR="${PROJECT_ROOT}/../HarborMind-Platform-Admin/HM-platform-admin-infrastructure"
CUSTOMER_CDK_DIR="${PROJECT_ROOT}/SaaS-infrastructure/cdk"

echo -e "${GREEN}🚀 HarborMind CDK Deployment Script${NC}"
echo -e "Environment: ${YELLOW}${ENVIRONMENT}${NC}"
echo -e "Deploy Type: ${YELLOW}${DEPLOY_TYPE}${NC}"
echo -e "AWS Region: ${YELLOW}${AWS_REGION}${NC}"
echo -e "AWS Profile: ${YELLOW}${AWS_PROFILE}${NC}"
if [ -n "$CDK_OPTIONS" ]; then
    echo -e "CDK Options: ${YELLOW}${CDK_OPTIONS}${NC}"
fi
echo ""

# Validate environment
if [[ ! "$ENVIRONMENT" =~ ^(dev|staging|prod)$ ]]; then
    echo -e "${RED}❌ Invalid environment: ${ENVIRONMENT}${NC}"
    echo -e "Valid environments: dev, staging, prod"
    exit 1
fi

# Validate deploy type
if [[ ! "$DEPLOY_TYPE" =~ ^(platform|customer|both)$ ]]; then
    echo -e "${RED}❌ Invalid deploy type: ${DEPLOY_TYPE}${NC}"
    echo -e "Valid types: platform, customer, both"
    exit 1
fi

# Check AWS Profile configuration
echo -e "${YELLOW}Checking AWS Profile configuration...${NC}"
CURRENT_PROFILE=$(aws configure get aws_access_key_id --profile ${AWS_PROFILE} 2>/dev/null)
if [ -z "$CURRENT_PROFILE" ]; then
    echo -e "${RED}❌ AWS Profile '${AWS_PROFILE}' is not configured.${NC}"
    echo -e "${YELLOW}Available profiles:${NC}"
    aws configure list-profiles 2>/dev/null || echo "No profiles found"
    echo ""
    echo -e "${YELLOW}To set up a profile, run:${NC}"
    echo -e "  aws configure --profile ${AWS_PROFILE}"
    echo ""
    echo -e "${YELLOW}Or specify a different profile:${NC}"
    echo -e "  AWS_PROFILE=your-profile $0 ${ENVIRONMENT} ${DEPLOY_TYPE}"
    exit 1
fi

# Get AWS Account ID for verification
AWS_ACCOUNT_ID=$(aws sts get-caller-identity --profile ${AWS_PROFILE} --query Account --output text 2>/dev/null)
if [ -z "$AWS_ACCOUNT_ID" ]; then
    echo -e "${RED}❌ Unable to get AWS account ID. Check your AWS credentials.${NC}"
    exit 1
fi

echo -e "${GREEN}✅ Using AWS Account: ${AWS_ACCOUNT_ID}${NC}"
echo ""

# Function to check if command exists
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# Check prerequisites
echo -e "${YELLOW}Checking prerequisites...${NC}"
if ! command_exists aws; then
    echo -e "${RED}❌ AWS CLI not found. Please install AWS CLI.${NC}"
    exit 1
fi

if ! command_exists npm; then
    echo -e "${RED}❌ npm not found. Please install Node.js and npm.${NC}"
    exit 1
fi

if ! command_exists cdk; then
    echo -e "${RED}❌ AWS CDK not found. Installing globally...${NC}"
    npm install -g aws-cdk
fi

echo -e "${GREEN}✅ All prerequisites installed${NC}"
echo ""

# Confirm before proceeding
echo -e "${YELLOW}⚠️  IMPORTANT: This script will deploy to the '${ENVIRONMENT}' environment${NC}"
echo -e "${YELLOW}   in AWS Account ${AWS_ACCOUNT_ID} using profile '${AWS_PROFILE}'${NC}"
echo ""
read -p "Do you want to continue? (y/N): " -n 1 -r
echo ""
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo -e "${YELLOW}Deployment cancelled.${NC}"
    exit 0
fi
echo ""

# Function to deploy CDK
deploy_cdk() {
    local cdk_dir=$1
    local stack_name=$2
    local description=$3
    
    echo -e "${BLUE}📦 Deploying ${description}...${NC}"
    echo -e "${BLUE}Directory: ${cdk_dir}${NC}"
    
    # Check if directory exists
    if [ ! -d "$cdk_dir" ]; then
        echo -e "${RED}❌ CDK directory not found: ${cdk_dir}${NC}"
        return 1
    fi
    
    # Change to CDK directory
    cd "$cdk_dir"
    
    # Install dependencies if needed
    if [ ! -d "node_modules" ]; then
        echo -e "${YELLOW}Installing dependencies...${NC}"
        npm install
    fi
    
    # Build TypeScript
    echo -e "${YELLOW}Building TypeScript...${NC}"
    npm run build
    
    # Bootstrap CDK if needed
    echo -e "${YELLOW}Checking CDK bootstrap...${NC}"
    if ! aws cloudformation describe-stacks --stack-name CDKToolkit --profile ${AWS_PROFILE} --region ${AWS_REGION} &>/dev/null; then
        echo -e "${YELLOW}Bootstrapping CDK...${NC}"
        cdk bootstrap aws://${AWS_ACCOUNT_ID}/${AWS_REGION} --profile ${AWS_PROFILE}
    fi
    
    # Synthesize CloudFormation
    echo -e "${YELLOW}Synthesizing CloudFormation templates...${NC}"
    cdk synth --profile ${AWS_PROFILE}
    
    # Deploy
    echo -e "${YELLOW}Deploying stacks...${NC}"
    if [ -n "$stack_name" ]; then
        # Deploy specific stack
        cdk deploy "$stack_name" --profile ${AWS_PROFILE} ${CDK_OPTIONS}
    else
        # Deploy all stacks
        cdk deploy --all --profile ${AWS_PROFILE} ${CDK_OPTIONS}
    fi
    
    if [ $? -eq 0 ]; then
        echo -e "${GREEN}✅ ${description} deployed successfully${NC}"
    else
        echo -e "${RED}❌ ${description} deployment failed${NC}"
        return 1
    fi
    
    echo ""
}

# Deploy based on type
DEPLOYMENT_SUCCESS=true

# Deploy customer first as platform depends on it (WAF exports)
if [[ "$DEPLOY_TYPE" == "customer" || "$DEPLOY_TYPE" == "both" ]]; then
    echo -e "${YELLOW}👥 Deploying Customer App CDK...${NC}"
    echo -e "${YELLOW}Note: Deploying in phases to handle cross-stack dependencies${NC}"

    # Prepare customer CDK
    cd "$CUSTOMER_CDK_DIR"

    # Install dependencies if needed
    if [ ! -d "node_modules" ]; then
        echo -e "${YELLOW}Installing dependencies...${NC}"
        npm install
    fi

    # Build TypeScript
    echo -e "${YELLOW}Building TypeScript...${NC}"
    npm run build

    # Bootstrap CDK if needed
    echo -e "${YELLOW}Checking CDK bootstrap...${NC}"
    if ! aws cloudformation describe-stacks --stack-name CDKToolkit --profile ${AWS_PROFILE} --region ${AWS_REGION} &>/dev/null; then
        echo -e "${YELLOW}Bootstrapping CDK...${NC}"
        cdk bootstrap aws://${AWS_ACCOUNT_ID}/${AWS_REGION} --profile ${AWS_PROFILE}
    fi

    # Synthesize CloudFormation
    echo -e "${YELLOW}Synthesizing CloudFormation templates...${NC}"
    cdk synth --profile ${AWS_PROFILE}

    echo ""

    # Phase 1: Foundation stacks
    echo -e "${BLUE}Phase 1: Foundation stacks (DNS, Foundation, Data)${NC}"
    if ! cdk deploy HarborMind-${ENVIRONMENT}-DNS HarborMind-${ENVIRONMENT}-Foundation HarborMind-${ENVIRONMENT}-Data --profile ${AWS_PROFILE} ${CDK_OPTIONS}; then
        echo -e "${RED}❌ Phase 1 deployment failed${NC}"
        DEPLOYMENT_SUCCESS=false
    else
        # Phase 2: Lambda and Operations
        echo -e "${BLUE}Phase 2: Lambda Functions and Operations${NC}"
        if ! cdk deploy HarborMind-${ENVIRONMENT}-LambdaFunctions HarborMind-${ENVIRONMENT}-Analytics HarborMind-${ENVIRONMENT}-Operations --profile ${AWS_PROFILE} ${CDK_OPTIONS}; then
            echo -e "${RED}❌ Phase 2 deployment failed${NC}"
            DEPLOYMENT_SUCCESS=false
        else
            # Phase 3: Remaining stacks
            echo -e "${BLUE}Phase 3: API Gateway and remaining stacks${NC}"
            if ! cdk deploy --all --profile ${AWS_PROFILE} ${CDK_OPTIONS}; then
                echo -e "${RED}❌ Phase 3 deployment failed${NC}"
                DEPLOYMENT_SUCCESS=false
            fi
        fi
    fi
fi

if [[ "$DEPLOY_TYPE" == "platform" || "$DEPLOY_TYPE" == "both" ]]; then
    echo -e "${YELLOW}🏢 Deploying Platform Admin CDK...${NC}"
    if ! deploy_cdk "$PLATFORM_CDK_DIR" "" "Platform Admin Infrastructure"; then
        DEPLOYMENT_SUCCESS=false
    fi
fi

# Display completion message
echo ""
if [ "$DEPLOYMENT_SUCCESS" = true ]; then
    echo -e "${GREEN}🎉 CDK Deployment Complete!${NC}"
    echo ""
    echo -e "${YELLOW}Deployed to:${NC}"
    echo -e "  Environment: ${GREEN}${ENVIRONMENT}${NC}"
    echo -e "  AWS Account: ${GREEN}${AWS_ACCOUNT_ID}${NC}"
    echo -e "  AWS Region: ${GREEN}${AWS_REGION}${NC}"
    echo ""
    
    if [[ "$DEPLOY_TYPE" == "platform" || "$DEPLOY_TYPE" == "both" ]]; then
        echo -e "${YELLOW}Platform Admin Stacks:${NC}"
        cd "$PLATFORM_CDK_DIR" && cdk ls --profile ${AWS_PROFILE} 2>/dev/null | while read stack; do
            echo -e "  - ${GREEN}${stack}${NC}"
        done
    fi
    
    if [[ "$DEPLOY_TYPE" == "customer" || "$DEPLOY_TYPE" == "both" ]]; then
        echo -e "${YELLOW}Customer App Stacks:${NC}"
        cd "$CUSTOMER_CDK_DIR" && cdk ls --profile ${AWS_PROFILE} 2>/dev/null | while read stack; do
            echo -e "  - ${GREEN}${stack}${NC}"
        done
    fi
    
    echo ""
    echo -e "${YELLOW}Next Steps:${NC}"
    echo -e "1. Deploy the frontend applications:"
    echo -e "   ${BLUE}./scripts/deploy-frontend-split.sh ${ENVIRONMENT} both${NC}"
    echo ""
    echo -e "2. Create platform admin user (if needed):"
    echo -e "   ${BLUE}./scripts/create-platform-admin.sh ${ENVIRONMENT}${NC}"
    echo ""
else
    echo -e "${RED}❌ CDK Deployment Failed!${NC}"
    echo -e "Please check the error messages above and try again."
    exit 1
fi