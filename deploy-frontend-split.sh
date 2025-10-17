#!/bin/bash

# Enhanced Frontend Deployment Script for HarborMind - Split Frontend Structure
# Automatically gathers all configuration from deployed stacks
#
# Usage:
#   ./deploy-frontend-split.sh [environment] [deploy_type]
#
# Environment Variables:
#   AWS_PROFILE        - AWS profile to use (default: default)
#   AWS_REGION         - AWS region (default: us-east-1)
#   BASE_DOMAIN        - Base domain for URLs (default: harbormind.ai)
#   CUSTOM_API_URL     - Override API URL
#   CUSTOM_ADMIN_API_URL - Override Admin API URL
#   CUSTOM_APP_URL     - Override App URL
#   CUSTOM_ADMIN_URL   - Override Admin URL
#
# Examples:
#   # Deploy to dev with default domain
#   ./deploy-frontend-split.sh dev both
#
#   # Deploy to staging with custom domain
#   BASE_DOMAIN=mycompany.com ./deploy-frontend-split.sh staging both
#
#   # Deploy to prod with specific AWS profile
#   AWS_PROFILE=prod-profile ./deploy-frontend-split.sh prod both

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Default values
ENVIRONMENT=${1:-dev}
DEPLOY_TYPE=${2:-both} # app, admin, or both
AWS_REGION=${AWS_REGION:-us-east-1}
AWS_PROFILE=${AWS_PROFILE:-default}
AUTO_CONFIGURE=${AUTO_CONFIGURE:-true}
# Domain configuration - can be overridden with environment variables
BASE_DOMAIN=${BASE_DOMAIN:-harbormind.ai}

# Script directory
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
PROJECT_ROOT="${SCRIPT_DIR}/.."
FRONTEND_APP_DIR="${PROJECT_ROOT}/SaaS-frontend"
FRONTEND_ADMIN_DIR="${PROJECT_ROOT}/../HarborMind-Platform-Admin/HM-platform-admin-frontend"
CDK_DIR="${PROJECT_ROOT}/SaaS-infrastructure/cdk"
ADMIN_CDK_DIR="${PROJECT_ROOT}/../HarborMind-Platform-Admin/HM-platform-admin-infrastructure"

echo -e "${GREEN}🚀 HarborMind Frontend Deployment Script (Split Structure)${NC}"
echo -e "Environment: ${YELLOW}${ENVIRONMENT}${NC}"
echo -e "Deploy Type: ${YELLOW}${DEPLOY_TYPE}${NC}"
echo -e "AWS Region: ${YELLOW}${AWS_REGION}${NC}"
echo -e "AWS Profile: ${YELLOW}${AWS_PROFILE}${NC}"
echo -e "Base Domain: ${YELLOW}${BASE_DOMAIN}${NC}"
echo -e "Auto Configure: ${YELLOW}${AUTO_CONFIGURE}${NC}"
echo ""

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
    echo -e "  AWS_PROFILE=your-profile ./deploy-frontend-split.sh ${ENVIRONMENT} ${DEPLOY_TYPE}"
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

if ! command_exists jq; then
    echo -e "${RED}❌ jq not found. Please install jq for JSON parsing.${NC}"
    exit 1
fi

# Function to get stack output
get_stack_output() {
    local stack_name=$1
    local output_key=$2
    aws cloudformation describe-stacks \
        --stack-name "$stack_name" \
        --query "Stacks[0].Outputs[?OutputKey=='$output_key'].OutputValue" \
        --output text \
        --profile ${AWS_PROFILE} \
        --region ${AWS_REGION} 2>/dev/null || echo ""
}

# Function to get Cognito User Pool Client ID from User Pool ID
get_cognito_client_id() {
    local user_pool_id=$1
    local client_name_pattern=${2:-"admin-client"}
    
    if [ -z "$user_pool_id" ]; then
        echo ""
        return
    fi
    
    # List all clients for the user pool and find the first one (or one matching pattern)
    aws cognito-idp list-user-pool-clients \
        --user-pool-id "$user_pool_id" \
        --query "UserPoolClients[0].ClientId" \
        --output text \
        --profile ${AWS_PROFILE} \
        --region ${AWS_REGION} 2>/dev/null || echo ""
}

# Function to verify Cognito client exists
verify_cognito_client() {
    local user_pool_id=$1
    local client_id=$2
    
    if [ -z "$user_pool_id" ] || [ -z "$client_id" ]; then
        return 1
    fi
    
    aws cognito-idp describe-user-pool-client \
        --user-pool-id "$user_pool_id" \
        --client-id "$client_id" \
        --profile ${AWS_PROFILE} \
        --region ${AWS_REGION} &>/dev/null
}

# Function to check if stack exists
stack_exists() {
    local stack_name=$1
    aws cloudformation describe-stacks \
        --stack-name "$stack_name" \
        --profile ${AWS_PROFILE} \
        --region ${AWS_REGION} &>/dev/null
}

# Gather configuration from deployed stacks
if [[ "$AUTO_CONFIGURE" == "true" ]]; then
    echo -e "${YELLOW}Gathering configuration from deployed stacks...${NC}"
    
    # Check required stacks exist
    echo -e "${YELLOW}Checking required CloudFormation stacks...${NC}"
    
    MISSING_STACKS=()
    
    # Foundation stack (required for customer app)
    if ! stack_exists "HarborMind-${ENVIRONMENT}-Foundation"; then
        MISSING_STACKS+=("HarborMind-${ENVIRONMENT}-Foundation (provides customer user pool)")
    else
        echo -e "${GREEN}✓${NC} Foundation stack found"
    fi
    
    # Platform Admin stack (required for admin app)
    if ! stack_exists "HarborMind-${ENVIRONMENT}-PlatformAdmin"; then
        MISSING_STACKS+=("HarborMind-${ENVIRONMENT}-PlatformAdmin (provides admin user pool and S3 bucket)")
    else
        echo -e "${GREEN}✓${NC} Platform Admin stack found"
    fi
    
    # API Gateway stack (required for both)
    if ! stack_exists "HarborMind-${ENVIRONMENT}-ApiGateway"; then
        MISSING_STACKS+=("HarborMind-${ENVIRONMENT}-ApiGateway (provides API endpoints)")
    else
        echo -e "${GREEN}✓${NC} API Gateway stack found"
    fi
    
    # Frontend stack (required for customer app)
    if ! stack_exists "HarborMind-${ENVIRONMENT}-Frontend"; then
        MISSING_STACKS+=("HarborMind-${ENVIRONMENT}-Frontend (provides customer S3 bucket)")
    else
        echo -e "${GREEN}✓${NC} Frontend stack found"
    fi
    
    if [ ${#MISSING_STACKS[@]} -gt 0 ]; then
        echo ""
        echo -e "${RED}❌ Missing required CloudFormation stacks:${NC}"
        for stack in "${MISSING_STACKS[@]}"; do
            echo -e "   - $stack"
        done
        echo ""
        echo -e "${YELLOW}To deploy the missing stacks, run:${NC}"
        echo -e "   # For main infrastructure:"
        echo -e "   cd infrastructure/cdk"
        echo -e "   npm run deploy:${ENVIRONMENT}"
        echo ""
        echo -e "   # For admin infrastructure:"
        echo -e "   cd platform-admin/infrastructure"
        echo -e "   cdk deploy HarborMind-${ENVIRONMENT}-PlatformAdmin"
        echo ""
        echo -e "${YELLOW}Or deploy individual stacks:${NC}"
        echo -e "   cdk deploy HarborMind-${ENVIRONMENT}-Foundation"
        echo -e "   cdk deploy HarborMind-${ENVIRONMENT}-PlatformAdmin"
        echo -e "   cdk deploy HarborMind-${ENVIRONMENT}-ApiGateway"
        echo -e "   cdk deploy HarborMind-${ENVIRONMENT}-Frontend"
        exit 1
    fi
    
    echo ""
    
    # Get configuration values
    echo -e "${BLUE}📋 Retrieving configuration values...${NC}"
    
    # Regular User Pool (from Foundation stack)
    USER_POOL_ID=$(get_stack_output "HarborMind-${ENVIRONMENT}-Foundation" "UserPoolId")
    USER_POOL_CLIENT_ID=$(get_stack_output "HarborMind-${ENVIRONMENT}-Foundation" "UserPoolClientId")
    IDENTITY_POOL_ID=$(get_stack_output "HarborMind-${ENVIRONMENT}-Foundation" "IdentityPoolId")
    
    # If customer client ID not found in stack outputs, try to fetch dynamically
    if [ -z "$USER_POOL_CLIENT_ID" ] && [ -n "$USER_POOL_ID" ]; then
        echo -e "${YELLOW}⚠️  Customer User Pool Client ID not found in stack outputs. Attempting to fetch dynamically...${NC}"
        USER_POOL_CLIENT_ID=$(get_cognito_client_id "$USER_POOL_ID" "customer-client")
        if [ -n "$USER_POOL_CLIENT_ID" ]; then
            echo -e "${GREEN}✅ Found customer client ID: ${USER_POOL_CLIENT_ID}${NC}"
        fi
    fi
    
    # Verify the customer client exists
    if [ -n "$USER_POOL_ID" ] && [ -n "$USER_POOL_CLIENT_ID" ]; then
        if ! verify_cognito_client "$USER_POOL_ID" "$USER_POOL_CLIENT_ID"; then
            echo -e "${YELLOW}⚠️  Customer User Pool Client ${USER_POOL_CLIENT_ID} does not exist. Fetching current client...${NC}"
            USER_POOL_CLIENT_ID=$(get_cognito_client_id "$USER_POOL_ID")
            if [ -n "$USER_POOL_CLIENT_ID" ]; then
                echo -e "${GREEN}✅ Found valid customer client ID: ${USER_POOL_CLIENT_ID}${NC}"
            else
                echo -e "${RED}❌ No valid customer client found for user pool ${USER_POOL_ID}${NC}"
            fi
        fi
    fi
    
    # Get Cognito domain for customer user pool from stack output
    CUSTOMER_COGNITO_DOMAIN=$(get_stack_output "HarborMind-${ENVIRONMENT}-Foundation" "UserPoolDomain")
    if [ -z "$CUSTOMER_COGNITO_DOMAIN" ]; then
        echo -e "${YELLOW}⚠️  No Cognito domain found for customer user pool. OAuth flows may not work.${NC}"
    fi
    
    # Clean up domain if it has duplicate suffixes
    if [[ "$CUSTOMER_COGNITO_DOMAIN" == *.amazonaws.com*.amazonaws.com ]]; then
        CUSTOMER_COGNITO_DOMAIN=$(echo "$CUSTOMER_COGNITO_DOMAIN" | sed 's/\.auth\.us-east-1\.amazonaws\.com\.auth\.us-east-1\.amazonaws\.com/.auth.us-east-1.amazonaws.com/')
        echo -e "${YELLOW}⚠️  Fixed duplicate domain suffix for customer domain${NC}"
    fi
    
    # Admin User Pool (from Platform Admin stack)
    ADMIN_USER_POOL_ID=$(get_stack_output "HarborMind-${ENVIRONMENT}-PlatformAdmin" "AdminUserPoolId")
    ADMIN_USER_POOL_CLIENT_ID=$(get_stack_output "HarborMind-${ENVIRONMENT}-PlatformAdmin" "AdminUserPoolClientId")
    ADMIN_COGNITO_DOMAIN=$(get_stack_output "HarborMind-${ENVIRONMENT}-PlatformAdmin" "AdminCognitoDomain")
    
    # If admin client ID not found in stack outputs, try to fetch dynamically
    if [ -z "$ADMIN_USER_POOL_CLIENT_ID" ] && [ -n "$ADMIN_USER_POOL_ID" ]; then
        echo -e "${YELLOW}⚠️  Admin User Pool Client ID not found in stack outputs. Attempting to fetch dynamically...${NC}"
        ADMIN_USER_POOL_CLIENT_ID=$(get_cognito_client_id "$ADMIN_USER_POOL_ID" "admin-client")
        if [ -n "$ADMIN_USER_POOL_CLIENT_ID" ]; then
            echo -e "${GREEN}✅ Found admin client ID: ${ADMIN_USER_POOL_CLIENT_ID}${NC}"
        fi
    fi
    
    # Verify the admin client exists
    if [ -n "$ADMIN_USER_POOL_ID" ] && [ -n "$ADMIN_USER_POOL_CLIENT_ID" ]; then
        if ! verify_cognito_client "$ADMIN_USER_POOL_ID" "$ADMIN_USER_POOL_CLIENT_ID"; then
            echo -e "${YELLOW}⚠️  Admin User Pool Client ${ADMIN_USER_POOL_CLIENT_ID} does not exist. Fetching current client...${NC}"
            ADMIN_USER_POOL_CLIENT_ID=$(get_cognito_client_id "$ADMIN_USER_POOL_ID")
            if [ -n "$ADMIN_USER_POOL_CLIENT_ID" ]; then
                echo -e "${GREEN}✅ Found valid admin client ID: ${ADMIN_USER_POOL_CLIENT_ID}${NC}"
            else
                echo -e "${RED}❌ No valid admin client found for user pool ${ADMIN_USER_POOL_ID}${NC}"
            fi
        fi
    fi
    
    # Clean up admin domain if it has duplicate suffixes
    if [[ "$ADMIN_COGNITO_DOMAIN" == *.amazonaws.com*.amazonaws.com ]]; then
        ADMIN_COGNITO_DOMAIN=$(echo "$ADMIN_COGNITO_DOMAIN" | sed 's/\.auth\.us-east-1\.amazonaws\.com\.auth\.us-east-1\.amazonaws\.com/.auth.us-east-1.amazonaws.com/')
        echo -e "${YELLOW}⚠️  Fixed duplicate domain suffix for admin domain${NC}"
    fi
    
    # API Gateway URLs (from ApiGateway stack)
    API_GATEWAY_URL=$(get_stack_output "HarborMind-${ENVIRONMENT}-ApiGateway" "ApiGatewayUrl")
    WEBSOCKET_API_URL=$(get_stack_output "HarborMind-${ENVIRONMENT}-ApiGateway" "WebSocketApiEndpointWithStage")
    
    # Frontend infrastructure
    # App resources from Frontend stack
    APP_BUCKET=$(get_stack_output "HarborMind-${ENVIRONMENT}-Frontend" "AppBucketName")
    APP_DISTRIBUTION_ID=$(get_stack_output "HarborMind-${ENVIRONMENT}-Frontend" "AppDistributionId")
    
    # Admin resources from Platform Admin stack
    ADMIN_BUCKET=$(get_stack_output "HarborMind-${ENVIRONMENT}-PlatformAdmin" "AdminBucketName")
    ADMIN_DISTRIBUTION_ID=$(get_stack_output "HarborMind-${ENVIRONMENT}-PlatformAdmin" "AdminDistributionId")
    
    # Construct domain URLs based on environment and configuration
    # For production, use clean URLs without environment prefix
    if [ "${ENVIRONMENT}" = "prod" ]; then
        API_URL="https://api.${BASE_DOMAIN}"
        ADMIN_API_URL="https://api-admin.${BASE_DOMAIN}"
        APP_URL="https://app.${BASE_DOMAIN}"
        ADMIN_URL="https://admin.${BASE_DOMAIN}"
    else
        # For non-prod, include environment in subdomain
        API_URL="https://api.${ENVIRONMENT}.${BASE_DOMAIN}"
        ADMIN_API_URL="https://api-admin.${ENVIRONMENT}.${BASE_DOMAIN}"
        APP_URL="https://app.${ENVIRONMENT}.${BASE_DOMAIN}"
        ADMIN_URL="https://admin.${ENVIRONMENT}.${BASE_DOMAIN}"
    fi
    
    # Allow override via environment variables
    API_URL=${CUSTOM_API_URL:-$API_URL}
    ADMIN_API_URL=${CUSTOM_ADMIN_API_URL:-$ADMIN_API_URL}
    APP_URL=${CUSTOM_APP_URL:-$APP_URL}
    ADMIN_URL=${CUSTOM_ADMIN_URL:-$ADMIN_URL}
    
    # Display gathered configuration
    echo -e "${GREEN}✅ Configuration retrieved successfully:${NC}"
    echo -e "  ${BLUE}AWS Account:${NC} ${AWS_ACCOUNT_ID}"
    echo -e "  ${BLUE}AWS Region:${NC} ${AWS_REGION}"
    echo -e "  ${BLUE}Environment:${NC} ${ENVIRONMENT}"
    echo ""
    echo -e "  ${BLUE}User Pools:${NC}"
    if [[ "$DEPLOY_TYPE" == "app" || "$DEPLOY_TYPE" == "both" ]]; then
        echo -e "    ${BLUE}Customer Pool:${NC}"
        echo -e "      Pool ID: ${USER_POOL_ID:-${RED}NOT FOUND${NC}}"
        echo -e "      Client ID: ${USER_POOL_CLIENT_ID:-${RED}NOT FOUND${NC}}"
        echo -e "      Domain: ${CUSTOMER_COGNITO_DOMAIN:-${YELLOW}Not configured${NC}}"
    fi
    if [[ "$DEPLOY_TYPE" == "admin" || "$DEPLOY_TYPE" == "both" ]]; then
        echo -e "    ${BLUE}Admin Pool:${NC}"
        echo -e "      Pool ID: ${ADMIN_USER_POOL_ID:-${RED}NOT FOUND${NC}}"
        echo -e "      Client ID: ${ADMIN_USER_POOL_CLIENT_ID:-${RED}NOT FOUND${NC}}"
        echo -e "      Domain: ${ADMIN_COGNITO_DOMAIN:-${YELLOW}Not configured${NC}}"
    fi
    echo ""
    echo -e "  ${BLUE}API Endpoints:${NC}"
    echo -e "    Customer API: ${API_URL}"
    echo -e "    Admin API: ${ADMIN_API_URL}"
    echo -e "    Gateway URL: ${API_GATEWAY_URL:-${RED}NOT FOUND${NC}}"
    echo -e "    WebSocket: ${WEBSOCKET_API_URL:-${YELLOW}Not found${NC}}"
    echo ""
    echo -e "  ${BLUE}Frontend Hosting:${NC}"
    if [[ "$DEPLOY_TYPE" == "app" || "$DEPLOY_TYPE" == "both" ]]; then
        echo -e "    App Bucket: ${APP_BUCKET:-${RED}NOT FOUND${NC}}"
        echo -e "    App URL: ${APP_URL}"
    fi
    if [[ "$DEPLOY_TYPE" == "admin" || "$DEPLOY_TYPE" == "both" ]]; then
        echo -e "    Admin Bucket: ${ADMIN_BUCKET:-${RED}NOT FOUND${NC}}"
        echo -e "    Admin URL: ${ADMIN_URL}"
    fi
    echo ""
    
    # Check for critical missing values
    CRITICAL_MISSING=false
    
    if [[ "$DEPLOY_TYPE" == "app" || "$DEPLOY_TYPE" == "both" ]]; then
        if [ -z "$USER_POOL_ID" ] || [ -z "$USER_POOL_CLIENT_ID" ]; then
            echo -e "${RED}❌ Missing customer authentication configuration${NC}"
            echo -e "   The Foundation stack may not have exported the required outputs."
            CRITICAL_MISSING=true
        fi
    fi
    
    if [[ "$DEPLOY_TYPE" == "admin" || "$DEPLOY_TYPE" == "both" ]]; then
        if [ -z "$ADMIN_USER_POOL_ID" ] || [ -z "$ADMIN_USER_POOL_CLIENT_ID" ]; then
            echo -e "${RED}❌ Missing admin authentication configuration${NC}"
            echo -e "   The Admin stack may not have exported the required outputs."
            CRITICAL_MISSING=true
        fi
    fi
    
    if [ "$CRITICAL_MISSING" = true ]; then
        echo ""
        echo -e "${YELLOW}Please check that your CDK stacks are properly configured and have the required outputs.${NC}"
        exit 1
    fi
    
    # Validate required values based on deploy type
    if [[ "$DEPLOY_TYPE" == "app" || "$DEPLOY_TYPE" == "both" ]]; then
        if [ -z "$APP_BUCKET" ]; then
            echo -e "${RED}❌ App bucket name not found. Please ensure Frontend stack is deployed.${NC}"
            exit 1
        fi
        if [ -z "$APP_DISTRIBUTION_ID" ]; then
            echo -e "${RED}❌ App CloudFront distribution ID not found. Please ensure Frontend stack is deployed.${NC}"
            exit 1
        fi
    fi
    
    if [[ "$DEPLOY_TYPE" == "admin" || "$DEPLOY_TYPE" == "both" ]]; then
        if [ -z "$ADMIN_BUCKET" ]; then
            echo -e "${RED}❌ Admin bucket name not found. Please ensure Admin stack is deployed.${NC}"
            exit 1
        fi
        if [ -z "$ADMIN_DISTRIBUTION_ID" ]; then
            echo -e "${RED}❌ Admin CloudFront distribution ID not found. Please ensure Admin stack is deployed.${NC}"
            exit 1
        fi
    fi
    
    # Generate configuration files (both .env for build and config.js for runtime)
    echo -e "${YELLOW}Creating configuration files...${NC}"
    
    # Clean up any existing .env files first
    echo -e "${YELLOW}Cleaning up existing .env files...${NC}"
    rm -f "${FRONTEND_APP_DIR}/.env" "${FRONTEND_APP_DIR}/.env.*"
    rm -f "${FRONTEND_ADMIN_DIR}/.env" "${FRONTEND_ADMIN_DIR}/.env.*"
    
    # Generate files for customer app
    if [[ "$DEPLOY_TYPE" == "app" || "$DEPLOY_TYPE" == "both" ]]; then
        # Generate .env file for build process
        cat > "${FRONTEND_APP_DIR}/.env" <<EOF
# HarborMind Customer App Configuration - ${ENVIRONMENT}
# Generated at: $(date)
# This file is used during build and will not be deployed

VITE_ENVIRONMENT=${ENVIRONMENT}
VITE_AWS_REGION=${AWS_REGION}
VITE_USER_POOL_ID=${USER_POOL_ID}
VITE_USER_POOL_CLIENT_ID=${USER_POOL_CLIENT_ID}
VITE_IDENTITY_POOL_ID=${IDENTITY_POOL_ID:-}
VITE_COGNITO_DOMAIN=${CUSTOMER_COGNITO_DOMAIN}
VITE_API_URL=${API_URL}
VITE_WEBSOCKET_URL=${WEBSOCKET_API_URL:-}
VITE_APP_NAME=HarborMind
VITE_APP_VERSION=1.0.0
EOF
        echo -e "${GREEN}✅ Customer app .env file created for build${NC}"
        
        # Generate config.js for runtime
        cat > "${FRONTEND_APP_DIR}/public/config.js" <<EOF
// Dynamic configuration for HarborMind Customer App
// Generated at: $(date)
// Environment: ${ENVIRONMENT}

window._HARBORMIND_CONFIG_ = {
  environment: '${ENVIRONMENT}',
  region: '${AWS_REGION}',
  userPoolId: '${USER_POOL_ID}',
  userPoolClientId: '${USER_POOL_CLIENT_ID}',
  identityPoolId: '${IDENTITY_POOL_ID:-}',
  cognitoDomain: '${CUSTOMER_COGNITO_DOMAIN}',
  apiUrl: '${API_URL}',
  websocketUrl: '${WEBSOCKET_API_URL:-}',
  appName: 'HarborMind',
  appVersion: '1.0.0'
};
EOF
        echo -e "${GREEN}✅ Customer app dynamic config (config.js) created${NC}"
    fi
    
    # Generate files for admin portal
    if [[ "$DEPLOY_TYPE" == "admin" || "$DEPLOY_TYPE" == "both" ]]; then
        # Check if admin frontend exists
        if [ ! -f "${FRONTEND_ADMIN_DIR}/package.json" ]; then
            echo -e "${YELLOW}⚠️  Admin frontend not found at ${FRONTEND_ADMIN_DIR}${NC}"
            echo -e "${YELLOW}   The platform-admin directory doesn't contain a frontend app.${NC}"
            echo -e "${YELLOW}   Admin UI is deployed as part of the Admin stack infrastructure.${NC}"
            echo -e "${YELLOW}   Skipping admin frontend configuration.${NC}"
        else
            # Generate .env file for build process
            cat > "${FRONTEND_ADMIN_DIR}/.env" <<EOF
# HarborMind Admin Portal Configuration - ${ENVIRONMENT}
# Generated at: $(date)
# This file is used during build and will not be deployed

VITE_ENVIRONMENT=${ENVIRONMENT}
VITE_AWS_REGION=${AWS_REGION}
VITE_IS_ADMIN=true
VITE_ADMIN_USER_POOL_ID=${ADMIN_USER_POOL_ID}
VITE_ADMIN_USER_POOL_CLIENT_ID=${ADMIN_USER_POOL_CLIENT_ID}
VITE_ADMIN_COGNITO_DOMAIN=${ADMIN_COGNITO_DOMAIN}
VITE_ADMIN_API_URL=${ADMIN_API_URL}
VITE_USER_POOL_ID=${ADMIN_USER_POOL_ID}
VITE_USER_POOL_CLIENT_ID=${ADMIN_USER_POOL_CLIENT_ID}
VITE_COGNITO_DOMAIN=${ADMIN_COGNITO_DOMAIN}
VITE_API_URL=${ADMIN_API_URL}
VITE_WEBSOCKET_URL=${WEBSOCKET_API_URL:-}
VITE_APP_NAME=HarborMind Admin
VITE_APP_VERSION=1.0.0
EOF
            echo -e "${GREEN}✅ Admin portal .env file created for build${NC}"
            
            # Generate config.js for runtime
            cat > "${FRONTEND_ADMIN_DIR}/public/config.js" <<EOF
// Dynamic configuration for HarborMind Admin Portal
// Generated at: $(date)
// Environment: ${ENVIRONMENT}

window._HARBORMIND_CONFIG_ = {
  environment: '${ENVIRONMENT}',
  region: '${AWS_REGION}',
  isAdmin: true,
  adminUserPoolId: '${ADMIN_USER_POOL_ID}',
  adminUserPoolClientId: '${ADMIN_USER_POOL_CLIENT_ID}',
  adminCognitoDomain: '${ADMIN_COGNITO_DOMAIN}',
  adminApiUrl: '${ADMIN_API_URL}',
  // Regular pool for compatibility
  userPoolId: '${ADMIN_USER_POOL_ID}',
  userPoolClientId: '${ADMIN_USER_POOL_CLIENT_ID}',
  cognitoDomain: '${ADMIN_COGNITO_DOMAIN}',
  apiUrl: '${ADMIN_API_URL}',
  websocketUrl: '${WEBSOCKET_API_URL:-}',
  appName: 'HarborMind Admin',
  appVersion: '1.0.0'
};
EOF
            echo -e "${GREEN}✅ Admin portal dynamic config (config.js) created${NC}"
        fi
    fi
fi

# Function to build frontend
build_frontend() {
    local type=$1
    local frontend_dir=$2
    
    echo -e "${YELLOW}Building ${type} frontend for ${ENVIRONMENT} environment...${NC}"
    echo -e "${BLUE}Directory: ${frontend_dir}${NC}"
    echo -e "${BLUE}Using dynamic configuration from config.js${NC}"
    
    # Change to frontend directory
    cd "${frontend_dir}"
    
    # Install dependencies if needed
    if [ ! -d "node_modules" ]; then
        echo -e "${YELLOW}Installing ${type} frontend dependencies...${NC}"
        npm install
    fi
    
    # Clean any existing build to ensure fresh compilation
    if [ -d "dist" ]; then
        echo -e "${YELLOW}Cleaning existing build directory...${NC}"
        rm -rf dist
    fi

    # Show that we're using dynamic config
    echo -e "${BLUE}Configuration loaded dynamically at runtime${NC}"
    echo ""

    # Build
    echo -e "${YELLOW}Running build...${NC}"
    npm run build

    # Verify templates were copied during build
    if [ -d "public/templates" ]; then
        if [ ! -d "dist/templates" ]; then
            echo -e "${YELLOW}⚠️  Templates not found in dist/ - copying manually...${NC}"
            mkdir -p dist/templates
            cp -r public/templates/* dist/templates/
        fi

        # Show template status
        echo -e "${GREEN}✅ CloudFormation templates included in build:${NC}"
        ls -lh dist/templates/*.yaml | awk '{print "   - " $9 " (" $5 ")"}'
        echo ""
    fi
    
    if [ ! -d "dist" ]; then
        echo -e "${RED}❌ ${type} build failed - dist directory not found${NC}"
        exit 1
    fi
    
    echo -e "${GREEN}✅ ${type} build completed for ${ENVIRONMENT} environment${NC}"
    echo ""
}

# Build frontend based on deployment type
if [[ "$DEPLOY_TYPE" == "app" || "$DEPLOY_TYPE" == "both" ]]; then
    build_frontend "Customer App" "${FRONTEND_APP_DIR}"
fi

if [[ "$DEPLOY_TYPE" == "admin" || "$DEPLOY_TYPE" == "both" ]]; then
    # Check if admin frontend exists before building
    if [ ! -f "${FRONTEND_ADMIN_DIR}/package.json" ]; then
        echo -e "${YELLOW}⚠️  Admin frontend not found at ${FRONTEND_ADMIN_DIR}${NC}"
        echo -e "${YELLOW}   The platform-admin directory doesn't contain a frontend app.${NC}"
        echo -e "${YELLOW}   Skipping admin frontend build.${NC}"
        echo ""
    else
        build_frontend "Admin Portal" "${FRONTEND_ADMIN_DIR}"
    fi
fi

# Function to deploy to S3
deploy_to_s3() {
    local bucket=$1
    local type=$2
    local dist_dir=$3
    
    echo -e "${YELLOW}Deploying ${type} to S3 bucket: ${bucket}...${NC}"
    
    # Sync files to S3
    aws s3 sync "${dist_dir}/" "s3://${bucket}/" \
        --delete \
        --profile ${AWS_PROFILE} \
        --region ${AWS_REGION} \
        --cache-control "public, max-age=31536000" \
        --exclude "index.html" \
        --exclude "config.js" \
        --exclude "*.json" \
        --exclude "*.xml"
    
    # Upload index.html without cache
    aws s3 cp "${dist_dir}/index.html" "s3://${bucket}/index.html" \
        --profile ${AWS_PROFILE} \
        --region ${AWS_REGION} \
        --cache-control "no-cache, no-store, must-revalidate" \
        --content-type "text/html"
    
    # Upload config.js without cache (for dynamic configuration)
    if [ -f "${dist_dir}/config.js" ]; then
        aws s3 cp "${dist_dir}/config.js" "s3://${bucket}/config.js" \
            --profile ${AWS_PROFILE} \
            --region ${AWS_REGION} \
            --cache-control "no-cache, no-store, must-revalidate" \
            --content-type "application/javascript"
    fi
    
    # Upload other root files without heavy caching
    for file in ${dist_dir}/*.json ${dist_dir}/*.xml ${dist_dir}/*.txt; do
        if [ -f "$file" ]; then
            filename=$(basename "$file")
            aws s3 cp "$file" "s3://${bucket}/${filename}" \
                --profile ${AWS_PROFILE} \
                --region ${AWS_REGION} \
                --cache-control "public, max-age=3600"
        fi
    done

    # Upload CloudFormation templates without cache (so updates are immediate)
    if [ -d "${dist_dir}/templates" ]; then
        echo -e "${YELLOW}Uploading CloudFormation templates...${NC}"
        for template in ${dist_dir}/templates/*.yaml; do
            if [ -f "$template" ]; then
                filename=$(basename "$template")
                aws s3 cp "$template" "s3://${bucket}/templates/${filename}" \
                    --profile ${AWS_PROFILE} \
                    --region ${AWS_REGION} \
                    --cache-control "no-cache, no-store, must-revalidate" \
                    --content-type "text/yaml"
                echo -e "  ${GREEN}✓${NC} Uploaded templates/${filename}"
            fi
        done
    fi

    echo -e "${GREEN}✅ ${type} deployed to S3${NC}"
}

# Function to invalidate CloudFront
invalidate_cloudfront() {
    local distribution_id=$1
    local type=$2
    
    echo -e "${YELLOW}Creating CloudFront invalidation for ${type}...${NC}"
    
    INVALIDATION_ID=$(aws cloudfront create-invalidation \
        --distribution-id ${distribution_id} \
        --paths "/*" \
        --profile ${AWS_PROFILE} \
        --region ${AWS_REGION} \
        --query 'Invalidation.Id' \
        --output text)
    
    echo -e "${GREEN}✅ CloudFront invalidation created: ${INVALIDATION_ID}${NC}"
}

# Deploy based on type
if [[ "$DEPLOY_TYPE" == "app" || "$DEPLOY_TYPE" == "both" ]]; then
    deploy_to_s3 "$APP_BUCKET" "Customer App" "${FRONTEND_APP_DIR}/dist"
    invalidate_cloudfront "$APP_DISTRIBUTION_ID" "Customer App"
fi

if [[ "$DEPLOY_TYPE" == "admin" || "$DEPLOY_TYPE" == "both" ]]; then
    # Check if admin frontend exists and was built before deploying
    if [ ! -f "${FRONTEND_ADMIN_DIR}/package.json" ]; then
        echo -e "${YELLOW}⚠️  Admin frontend not found - skipping deployment${NC}"
        echo -e "${YELLOW}   The platform-admin directory doesn't contain a frontend app.${NC}"
        echo ""
    elif [ ! -d "${FRONTEND_ADMIN_DIR}/dist" ]; then
        echo -e "${YELLOW}⚠️  Admin frontend not built - skipping deployment${NC}"
        echo ""
    else
        deploy_to_s3 "$ADMIN_BUCKET" "Admin Portal" "${FRONTEND_ADMIN_DIR}/dist"
        invalidate_cloudfront "$ADMIN_DISTRIBUTION_ID" "Admin Portal"
    fi
fi

# Clean up temporary .env files (they're not needed after build)
echo ""
echo -e "${YELLOW}Cleaning up temporary .env files...${NC}"
if [[ "$DEPLOY_TYPE" == "app" || "$DEPLOY_TYPE" == "both" ]]; then
    rm -f "${FRONTEND_APP_DIR}/.env"
    echo -e "${GREEN}✅ Removed customer app .env file${NC}"
fi
if [[ "$DEPLOY_TYPE" == "admin" || "$DEPLOY_TYPE" == "both" ]]; then
    if [ -f "${FRONTEND_ADMIN_DIR}/.env" ]; then
        rm -f "${FRONTEND_ADMIN_DIR}/.env"
        echo -e "${GREEN}✅ Removed admin portal .env file${NC}"
    fi
fi

# Verify template deployment
if [[ "$DEPLOY_TYPE" == "app" || "$DEPLOY_TYPE" == "both" ]]; then
    if [ -d "${FRONTEND_APP_DIR}/dist/templates" ]; then
        echo ""
        echo -e "${YELLOW}Verifying CloudFormation template deployment...${NC}"
        TEMPLATE_COUNT=$(ls -1 "${FRONTEND_APP_DIR}/dist/templates"/*.yaml 2>/dev/null | wc -l)
        if [ $TEMPLATE_COUNT -gt 0 ]; then
            echo -e "${GREEN}✅ ${TEMPLATE_COUNT} CloudFormation template(s) deployed${NC}"
            echo -e "${BLUE}Template URLs:${NC}"
            for template in ${FRONTEND_APP_DIR}/dist/templates/*.yaml; do
                filename=$(basename "$template")
                echo -e "  ${APP_URL}/templates/${filename}"
            done
        fi
        echo ""
    fi
fi

# Display completion message
echo ""
echo -e "${GREEN}🎉 Deployment Complete!${NC}"
echo ""
echo -e "${YELLOW}URLs:${NC}"
if [[ "$DEPLOY_TYPE" == "app" || "$DEPLOY_TYPE" == "both" ]]; then
    echo -e "  Customer App: ${GREEN}${APP_URL}${NC}"
fi
if [[ "$DEPLOY_TYPE" == "admin" || "$DEPLOY_TYPE" == "both" ]]; then
    if [ -f "${FRONTEND_ADMIN_DIR}/package.json" ] && [ -d "${FRONTEND_ADMIN_DIR}/dist" ]; then
        echo -e "  Admin Portal: ${GREEN}${ADMIN_URL}${NC}"
    else
        echo -e "  Admin Portal: ${GREEN}${ADMIN_URL}${NC} (deployed via Admin stack)"
    fi
fi
echo ""
echo -e "${YELLOW}API Endpoints:${NC}"
echo -e "  Customer API: ${GREEN}${API_URL}${NC}"
echo -e "  Admin API: ${GREEN}${ADMIN_API_URL}${NC}"
echo -e "  WebSocket: ${GREEN}${WEBSOCKET_API_URL}${NC}"
echo ""
echo -e "${YELLOW}Note:${NC} CloudFront invalidation may take a few minutes to complete."
echo ""

# Save deployment info
DEPLOYMENT_INFO="${CDK_DIR}/.last-deployment-${ENVIRONMENT}.json"
cat > "$DEPLOYMENT_INFO" <<EOF
{
  "timestamp": "$(date -u +"%Y-%m-%dT%H:%M:%SZ")",
  "environment": "${ENVIRONMENT}",
  "deployType": "${DEPLOY_TYPE}",
  "urls": {
    "app": "${APP_URL}",
    "admin": "${ADMIN_URL}",
    "api": "${API_URL}",
    "adminApi": "${ADMIN_API_URL}",
    "websocket": "${WEBSOCKET_API_URL}"
  },
  "cognito": {
    "userPoolId": "${USER_POOL_ID}",
    "adminUserPoolId": "${ADMIN_USER_POOL_ID}"
  }
}
EOF

echo -e "${GREEN}✅ Deployment info saved to: ${DEPLOYMENT_INFO}${NC}"