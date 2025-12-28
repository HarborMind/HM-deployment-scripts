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
    cdk synth -c environment=${ENVIRONMENT} --profile ${AWS_PROFILE}
    
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

# Function to configure provisioned concurrency for latency-sensitive Lambda functions
# This is done outside of CDK to avoid Lambda version conflicts during deployment
configure_provisioned_concurrency() {
    local function_name=$1
    local alias_name="live"
    local concurrency=${2:-1}

    echo -e "${YELLOW}  Configuring provisioned concurrency for ${function_name}...${NC}"

    # Check if function exists
    if ! aws lambda get-function --function-name ${function_name} --profile ${AWS_PROFILE} --region ${AWS_REGION} &>/dev/null; then
        echo -e "${YELLOW}  ⚠️  Function ${function_name} not found, skipping${NC}"
        return 0
    fi

    # Publish new version
    VERSION=$(aws lambda publish-version \
        --function-name ${function_name} \
        --profile ${AWS_PROFILE} \
        --region ${AWS_REGION} \
        --query 'Version' --output text 2>/dev/null)

    if [ -z "$VERSION" ] || [ "$VERSION" == "None" ]; then
        echo -e "${RED}  ❌ Failed to publish version for ${function_name}${NC}"
        return 1
    fi

    # Create or update alias
    if aws lambda get-alias --function-name ${function_name} --name ${alias_name} --profile ${AWS_PROFILE} --region ${AWS_REGION} &>/dev/null; then
        aws lambda update-alias \
            --function-name ${function_name} \
            --name ${alias_name} \
            --function-version ${VERSION} \
            --profile ${AWS_PROFILE} \
            --region ${AWS_REGION} >/dev/null 2>&1
    else
        aws lambda create-alias \
            --function-name ${function_name} \
            --name ${alias_name} \
            --function-version ${VERSION} \
            --profile ${AWS_PROFILE} \
            --region ${AWS_REGION} >/dev/null 2>&1
    fi

    # Set provisioned concurrency
    aws lambda put-provisioned-concurrency-config \
        --function-name ${function_name} \
        --qualifier ${alias_name} \
        --provisioned-concurrent-executions ${concurrency} \
        --profile ${AWS_PROFILE} \
        --region ${AWS_REGION} >/dev/null 2>&1

    if [ $? -eq 0 ]; then
        echo -e "${GREEN}  ✅ Provisioned concurrency configured (version ${VERSION})${NC}"
    else
        echo -e "${RED}  ❌ Failed to configure provisioned concurrency${NC}"
        return 1
    fi
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
    cdk synth -c environment=${ENVIRONMENT} --profile ${AWS_PROFILE}

    echo ""

    # Phase 1: DNS
    echo -e "${BLUE}Phase 1: DNS${NC}"
    if ! cdk deploy HarborMind-${ENVIRONMENT}-DNS -c environment=${ENVIRONMENT} --profile ${AWS_PROFILE} ${CDK_OPTIONS}; then
        echo -e "${RED}❌ Phase 1 deployment failed${NC}"
        DEPLOYMENT_SUCCESS=false
    else
        # Phase 2: Foundation
        echo -e "${BLUE}Phase 2: Foundation${NC}"
        if ! cdk deploy HarborMind-${ENVIRONMENT}-Foundation -c environment=${ENVIRONMENT} --profile ${AWS_PROFILE} ${CDK_OPTIONS}; then
            echo -e "${RED}❌ Phase 2 deployment failed${NC}"
            DEPLOYMENT_SUCCESS=false
        else
            # Phase 3: Data, CSPM, Assets, and Neptune (all read KMS key ARN from SSM - no stack dependency)
            echo -e "${BLUE}Phase 3: Data, CSPM, Assets, and Neptune${NC}"
            echo -e "${YELLOW}Note: CSPM creates cspm-findings table, Assets creates assets table for IAM/Bedrock discovery${NC}"
            echo -e "${YELLOW}      Neptune creates graph database for attack path analysis${NC}"
            if ! cdk deploy Data HarborMind-${ENVIRONMENT}-CSPM HarborMind-${ENVIRONMENT}-Assets HarborMind-${ENVIRONMENT}-Neptune -c environment=${ENVIRONMENT} --profile ${AWS_PROFILE} ${CDK_OPTIONS}; then
                echo -e "${RED}❌ Phase 3 deployment failed${NC}"
                DEPLOYMENT_SUCCESS=false
            else
                # Phase 4: Lambda Functions and SearchData
                echo -e "${BLUE}Phase 4: Lambda Functions and SearchData${NC}"
                echo -e "${YELLOW}Note: Lambda Functions exports function ARNs to SSM, SearchData is isolated for independent lifecycle management${NC}"
                if ! cdk deploy HarborMind-${ENVIRONMENT}-LambdaFunctions HarborMind-${ENVIRONMENT}-SearchData -c environment=${ENVIRONMENT} --profile ${AWS_PROFILE} ${CDK_OPTIONS}; then
                    echo -e "${RED}❌ Phase 4 deployment failed${NC}"
                    DEPLOYMENT_SUCCESS=false
                else
                    # Phase 5: API Gateway Core (creates SSM parameters that Analytics needs)
                    echo -e "${BLUE}Phase 5: API Gateway Core${NC}"
                    echo -e "${YELLOW}Note: API Gateway Core creates the base REST API and must deploy before route stacks${NC}"
                    if ! cdk deploy HarborMind-${ENVIRONMENT}-ApiGatewayCore -c environment=${ENVIRONMENT} --profile ${AWS_PROFILE} ${CDK_OPTIONS}; then
                        echo -e "${RED}❌ Phase 5 deployment failed${NC}"
                        DEPLOYMENT_SUCCESS=false
                    else
                        # Bootstrap OpenSearch VPC endpoint to SSM Parameter Store (after SearchData)
                        echo -e "${BLUE}Bootstrapping OpenSearch VPC endpoint...${NC}"
                        OPENSEARCH_DOMAIN_NAME="hm-${ENVIRONMENT}-search"
                        VPC_ENDPOINT=$(aws opensearch describe-domain --domain-name ${OPENSEARCH_DOMAIN_NAME} --query 'DomainStatus.Endpoints.vpc' --output text --profile ${AWS_PROFILE} 2>/dev/null || echo "")

                        if [ -n "$VPC_ENDPOINT" ] && [ "$VPC_ENDPOINT" != "None" ]; then
                            echo -e "${YELLOW}Found OpenSearch VPC endpoint: ${VPC_ENDPOINT}${NC}"
                            aws ssm put-parameter \
                                --name "/${ENVIRONMENT}/searchdata/opensearch/vpc-endpoint" \
                                --value "${VPC_ENDPOINT}" \
                                --type String \
                                --description "OpenSearch VPC endpoint for ${ENVIRONMENT} environment" \
                                --overwrite \
                                --profile ${AWS_PROFILE} \
                                --region ${AWS_REGION} 2>/dev/null
                            echo -e "${GREEN}✅ OpenSearch VPC endpoint stored in SSM Parameter Store${NC}"
                        else
                            echo -e "${YELLOW}⚠️  OpenSearch domain not deployed in VPC or not found, skipping VPC endpoint bootstrap${NC}"
                        fi

                        # Phase 6: SecurityAuth
                        echo -e "${BLUE}Phase 6: SecurityAuth${NC}"
                        if ! cdk deploy HarborMind-${ENVIRONMENT}-SecurityAuth -c environment=${ENVIRONMENT} --profile ${AWS_PROFILE} ${CDK_OPTIONS}; then
                            echo -e "${RED}❌ Phase 6 deployment failed${NC}"
                            DEPLOYMENT_SUCCESS=false
                        else
                            # Phase 7: Analytics
                            echo -e "${BLUE}Phase 7: Analytics${NC}"
                            echo -e "${YELLOW}Note: Analytics imports API Gateway and SearchData parameters from SSM${NC}"
                            if ! cdk deploy HarborMind-${ENVIRONMENT}-Analytics -c environment=${ENVIRONMENT} --profile ${AWS_PROFILE} ${CDK_OPTIONS}; then
                                echo -e "${RED}❌ Phase 7 deployment failed${NC}"
                                DEPLOYMENT_SUCCESS=false
                            else
                                # Phase 8: Operations (creates Lambda functions needed by API Routes)
                                echo -e "${BLUE}Phase 8: Operations${NC}"
                                echo -e "${YELLOW}Note: Operations creates Lambda functions (ScanManagement, CatalogManagement, AwsAccountManagement) needed by API Routes${NC}"
                                if ! cdk deploy HarborMind-${ENVIRONMENT}-Operations -c environment=${ENVIRONMENT} --profile ${AWS_PROFILE} ${CDK_OPTIONS}; then
                                    echo -e "${RED}❌ Phase 8 deployment failed${NC}"
                                    DEPLOYMENT_SUCCESS=false
                                else
                                    # Configure provisioned concurrency for latency-sensitive functions
                                    echo -e "${BLUE}Configuring provisioned concurrency for latency-sensitive Lambda functions...${NC}"
                                    configure_provisioned_concurrency "hm-${ENVIRONMENT}-dashboard-metrics"
                                    configure_provisioned_concurrency "hm-${ENVIRONMENT}-list-integrations"
                                    configure_provisioned_concurrency "hm-${ENVIRONMENT}-update-integration"
                                    configure_provisioned_concurrency "hm-${ENVIRONMENT}-catalog-findings"
                                    configure_provisioned_concurrency "hm-${ENVIRONMENT}-update-tenant-config"
                                    configure_provisioned_concurrency "hm-${ENVIRONMENT}-scan-submit-results" 2  # High concurrency for scan result submissions
                                    configure_provisioned_concurrency "hm-${ENVIRONMENT}-m365-discover"  # M365 discovery endpoint
                                    configure_provisioned_concurrency "hm-${ENVIRONMENT}-aws-discover"   # AWS discovery endpoint
                                    configure_provisioned_concurrency "hm-${ENVIRONMENT}-m365-settings"  # M365 settings saving
                                    configure_provisioned_concurrency "hm-${ENVIRONMENT}-m365-connect"   # M365 connection saving
                                    configure_provisioned_concurrency "hm-${ENVIRONMENT}-user-management"  # Settings > Users tab
                                    configure_provisioned_concurrency "hm-${ENVIRONMENT}-get-tenant-config"  # Settings > Scanner/Discovery config loading
                                    configure_provisioned_concurrency "hm-${ENVIRONMENT}-api-clients"  # Settings > API Keys tab
                                    configure_provisioned_concurrency "hm-${ENVIRONMENT}-sso-config"  # Settings > SSO tab
                                    echo ""

                                    # Phase 9: API Routes (depends on Operations for Lambda functions)
                                    echo -e "${BLUE}Phase 9: API Routes${NC}"
                                    echo -e "${YELLOW}Note: Deploying route stacks for Orchestrators, Data, Config, and Search${NC}"
                                    echo -e "${YELLOW}      Data/Orchestrators depend on Operations for scan/catalog Lambda functions${NC}"
                                    if ! cdk deploy HarborMind-${ENVIRONMENT}-ApiRoutes-Orchestrators HarborMind-${ENVIRONMENT}-ApiRoutes-Data HarborMind-${ENVIRONMENT}-ApiRoutes-Config HarborMind-${ENVIRONMENT}-ApiRoutes-Search -c environment=${ENVIRONMENT} --profile ${AWS_PROFILE} ${CDK_OPTIONS}; then
                                        echo -e "${RED}❌ Phase 9 deployment failed${NC}"
                                        DEPLOYMENT_SUCCESS=false
                                    else
                                        # Create API Gateway deployment to activate route changes
                                        echo -e "${BLUE}Creating API Gateway deployment...${NC}"
                                        REST_API_ID=$(aws ssm get-parameter --name "/${ENVIRONMENT}/api-gateway/rest-api/id" --query "Parameter.Value" --output text --profile ${AWS_PROFILE} --region ${AWS_REGION} 2>/dev/null || echo "")
                                        if [ -n "$REST_API_ID" ] && [ "$REST_API_ID" != "None" ]; then
                                            aws apigateway create-deployment \
                                                --rest-api-id ${REST_API_ID} \
                                                --stage-name ${ENVIRONMENT} \
                                                --description "Post-CDK deployment for ${ENVIRONMENT}" \
                                                --profile ${AWS_PROFILE} \
                                                --region ${AWS_REGION} 2>/dev/null
                                            echo -e "${GREEN}✅ API Gateway deployment created${NC}"
                                        else
                                            echo -e "${YELLOW}⚠️  Could not find REST API ID, skipping deployment${NC}"
                                        fi

                                        # Phase 10: SecurityInfrastructure
                                        echo -e "${BLUE}Phase 10: SecurityInfrastructure${NC}"
                                        if ! cdk deploy HarborMind-${ENVIRONMENT}-SecurityInfrastructure -c environment=${ENVIRONMENT} --profile ${AWS_PROFILE} ${CDK_OPTIONS}; then
                                            echo -e "${RED}❌ Phase 10 deployment failed${NC}"
                                            DEPLOYMENT_SUCCESS=false
                                        else
                                            # Phase 11: Frontend
                                            echo -e "${BLUE}Phase 11: Frontend${NC}"
                                            if ! cdk deploy HarborMind-${ENVIRONMENT}-Frontend -c environment=${ENVIRONMENT} --profile ${AWS_PROFILE} ${CDK_OPTIONS}; then
                                                echo -e "${RED}❌ Phase 11 deployment failed${NC}"
                                                DEPLOYMENT_SUCCESS=false
                                            fi
                                        fi
                                    fi
                                fi
                            fi
                        fi
                    fi
                fi
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
        cd "$PLATFORM_CDK_DIR" && cdk ls -c environment=${ENVIRONMENT} --profile ${AWS_PROFILE} 2>/dev/null | while read stack; do
            echo -e "  - ${GREEN}${stack}${NC}"
        done
    fi
    
    if [[ "$DEPLOY_TYPE" == "customer" || "$DEPLOY_TYPE" == "both" ]]; then
        echo -e "${YELLOW}Customer App Stacks:${NC}"
        cd "$CUSTOMER_CDK_DIR" && cdk ls -c environment=${ENVIRONMENT} --profile ${AWS_PROFILE} 2>/dev/null | while read stack; do
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