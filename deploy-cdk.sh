#!/bin/bash

# CDK Deployment Script for HarborMind
# Deploys AWS CDK stacks for platform admin and/or customer app
#
# Usage:
#   ./deploy-cdk.sh [environment] [deploy_type] [options]
#
# Arguments:
#   environment    - Environment to deploy to: dev, dev1, dev2, ..., staging, or prod (default: dev)
#   deploy_type    - What to deploy: platform, customer, or both (default: both)
#   options        - Additional CDK options (e.g., --require-approval never)
#
# Environment Variables:
#   AWS_PROFILE    - AWS profile to use (default: default)
#   AWS_REGION     - AWS region (default: us-east-1)
#   VPC_ID         - VPC ID override (required for ad-hoc dev environments like dev1, dev2)
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
AWS_PROFILE=${AWS_PROFILE:-dev-sso}

# Auto-approve CDK deployments (skip confirmation prompts)
# Override by passing --require-approval broadening in CDK_OPTIONS
if [[ ! "$CDK_OPTIONS" =~ "--require-approval" ]]; then
    CDK_OPTIONS="--require-approval never ${CDK_OPTIONS}"
fi

# Export for CDK's internal AWS SDK calls (needed for context lookups like valueFromLookup)
export AWS_PROFILE
export AWS_REGION

# Script directory
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
PROJECT_ROOT="${SCRIPT_DIR}/.."

# CDK directories
PLATFORM_CDK_DIR="${PROJECT_ROOT}/HarborMind-Platform-Admin/HM-platform-admin-infrastructure"
CUSTOMER_CDK_DIR="${PROJECT_ROOT}/HarborMind-SaaS/SaaS-infrastructure/cdk"

echo -e "${GREEN}🚀 HarborMind CDK Deployment Script${NC}"
echo -e "Environment: ${YELLOW}${ENVIRONMENT}${NC}"
echo -e "Deploy Type: ${YELLOW}${DEPLOY_TYPE}${NC}"
echo -e "AWS Region: ${YELLOW}${AWS_REGION}${NC}"
echo -e "AWS Profile: ${YELLOW}${AWS_PROFILE}${NC}"
if [ -n "$CDK_OPTIONS" ]; then
    echo -e "CDK Options: ${YELLOW}${CDK_OPTIONS}${NC}"
fi
echo ""

# Validate environment (dev, dev1, dev2, devfoo, staging, prod)
if [[ ! "$ENVIRONMENT" =~ ^(dev[a-z0-9]*|staging|prod)$ ]]; then
    echo -e "${RED}❌ Invalid environment: ${ENVIRONMENT}${NC}"
    echo -e "Valid environments: dev, dev1, dev2, ..., staging, prod"
    exit 1
fi

# Validate deploy type
if [[ ! "$DEPLOY_TYPE" =~ ^(platform|customer|both)$ ]]; then
    echo -e "${RED}❌ Invalid deploy type: ${DEPLOY_TYPE}${NC}"
    echo -e "Valid types: platform, customer, both"
    exit 1
fi

# Check AWS credentials (works with both static credentials and SSO profiles)
echo -e "${YELLOW}Checking AWS credentials...${NC}"
AWS_ACCOUNT_ID=$(aws sts get-caller-identity --profile ${AWS_PROFILE} --query Account --output text 2>/dev/null)
if [ -z "$AWS_ACCOUNT_ID" ] || [ "$AWS_ACCOUNT_ID" == "None" ]; then
    echo -e "${RED}❌ Unable to authenticate with AWS profile '${AWS_PROFILE}'.${NC}"
    echo -e "${YELLOW}Available profiles:${NC}"
    aws configure list-profiles 2>/dev/null || echo "No profiles found"
    echo ""
    echo -e "${YELLOW}For SSO profiles, run:${NC}"
    echo -e "  aws sso login --profile ${AWS_PROFILE}"
    echo ""
    echo -e "${YELLOW}Or specify a different profile:${NC}"
    echo -e "  AWS_PROFILE=your-profile $0 ${ENVIRONMENT} ${DEPLOY_TYPE}"
    exit 1
fi

echo -e "${GREEN}✅ Using AWS Account: ${AWS_ACCOUNT_ID}${NC}"

# Export SSO credentials as environment variables for CDK
# CDK has issues with SSO profiles when stacks have explicit env.account set
# This converts the SSO session to static credentials that CDK can use
echo -e "${YELLOW}Exporting credentials for CDK...${NC}"
eval "$(aws configure export-credentials --profile ${AWS_PROFILE} --format env 2>/dev/null)" || true
if [ -n "$AWS_ACCESS_KEY_ID" ]; then
    echo -e "${GREEN}✅ Credentials exported for CDK${NC}"
else
    echo -e "${YELLOW}⚠️  Could not export credentials, CDK will use profile directly${NC}"
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
        cdk deploy "$stack_name" -c environment=${ENVIRONMENT} --profile ${AWS_PROFILE} ${CDK_OPTIONS}
    else
        # Deploy all stacks
        cdk deploy --all -c environment=${ENVIRONMENT} --profile ${AWS_PROFILE} ${CDK_OPTIONS}
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

    # Bootstrap shared layer SSM parameter (required for cdk synth - valueFromLookup)
    echo -e "${BLUE}Checking shared layer SSM parameter...${NC}"
    EXISTING_LAYER_ARN=$(aws ssm get-parameter --name "/${ENVIRONMENT}/lambda/layers/shared/arn" --query "Parameter.Value" --output text --profile ${AWS_PROFILE} --region ${AWS_REGION} 2>/dev/null || echo "")
    if [ -z "$EXISTING_LAYER_ARN" ] || [ "$EXISTING_LAYER_ARN" == "None" ]; then
        echo -e "${YELLOW}Creating placeholder shared layer SSM parameter to unblock cdk synth...${NC}"
        aws ssm put-parameter \
            --name "/${ENVIRONMENT}/lambda/layers/shared/arn" \
            --value "arn:aws:lambda:${AWS_REGION}:${AWS_ACCOUNT_ID}:layer:shared:1" \
            --type String \
            --description "Shared Lambda layer ARN for ${ENVIRONMENT} (placeholder - Foundation stack will publish real value)" \
            --profile ${AWS_PROFILE} \
            --region ${AWS_REGION} 2>/dev/null
        echo -e "${GREEN}✅ Placeholder shared layer SSM parameter created${NC}"
    else
        echo -e "${GREEN}✅ Shared layer SSM parameter already exists${NC}"
    fi

    # Bootstrap DynamoDB table SSM parameters (required by Foundation → MultiTenantAuth)
    # These are created by DataStack (Phase 3) but Foundation (Phase 2) references them.
    # Only create if they don't exist — won't overwrite real values on subsequent deployments.
    echo -e "${BLUE}Checking DynamoDB table SSM parameters...${NC}"

    EXISTING_TU_NAME=$(aws ssm get-parameter --name "/${ENVIRONMENT}/dynamodb/tables/tenantusers/name" --query "Parameter.Value" --output text --profile ${AWS_PROFILE} --region ${AWS_REGION} 2>/dev/null || echo "")
    if [ -z "$EXISTING_TU_NAME" ] || [ "$EXISTING_TU_NAME" == "None" ]; then
        echo -e "${YELLOW}Creating placeholder tenantusers/name SSM parameter...${NC}"
        aws ssm put-parameter \
            --name "/${ENVIRONMENT}/dynamodb/tables/tenantusers/name" \
            --value "placeholder-tenantusers" \
            --type String \
            --description "Tenant users table name for ${ENVIRONMENT} (placeholder - DataStack will publish real value)" \
            --profile ${AWS_PROFILE} \
            --region ${AWS_REGION} 2>/dev/null
    fi

    EXISTING_TU_ARN=$(aws ssm get-parameter --name "/${ENVIRONMENT}/dynamodb/tables/tenantusers/arn" --query "Parameter.Value" --output text --profile ${AWS_PROFILE} --region ${AWS_REGION} 2>/dev/null || echo "")
    if [ -z "$EXISTING_TU_ARN" ] || [ "$EXISTING_TU_ARN" == "None" ]; then
        echo -e "${YELLOW}Creating placeholder tenantusers/arn SSM parameter...${NC}"
        aws ssm put-parameter \
            --name "/${ENVIRONMENT}/dynamodb/tables/tenantusers/arn" \
            --value "arn:aws:dynamodb:${AWS_REGION}:${AWS_ACCOUNT_ID}:table/placeholder-tenantusers" \
            --type String \
            --description "Tenant users table ARN for ${ENVIRONMENT} (placeholder - DataStack will publish real value)" \
            --profile ${AWS_PROFILE} \
            --region ${AWS_REGION} 2>/dev/null
    fi

    # Check for CodeConnection (needed for CICD stack)
    echo -e "${BLUE}Checking AWS CodeConnection for GitHub...${NC}"
    CODE_CONNECTION_ID=""

    # Try to find an existing CodeConnection for GitHub
    EXISTING_CONNECTION=$(aws codeconnections list-connections \
        --provider-type-filter GitHub \
        --max-results 1 \
        --query "Connections[?ConnectionStatus=='AVAILABLE'] | [0].ConnectionArn" \
        --output text \
        --profile ${AWS_PROFILE} \
        --region ${AWS_REGION} 2>/dev/null || echo "")

    if [ -n "$EXISTING_CONNECTION" ] && [ "$EXISTING_CONNECTION" != "None" ]; then
        # Extract connection ID from ARN (format: arn:aws:codeconnections:region:account:connection/ID)
        CODE_CONNECTION_ID=$(echo "$EXISTING_CONNECTION" | awk -F'/' '{print $NF}')
        echo -e "${GREEN}✅ Found existing CodeConnection: ${CODE_CONNECTION_ID}${NC}"
    else
        echo -e "${YELLOW}No CodeConnection found. CICD stack requires an AWS CodeConnection to GitHub.${NC}"
        echo -e "${YELLOW}Create one at: https://console.aws.amazon.com/codesuite/settings/connections${NC}"
        echo -e "${YELLOW}Steps:${NC}"
        echo -e "${YELLOW}  1. Click 'Create connection'${NC}"
        echo -e "${YELLOW}  2. Select 'GitHub' as the provider${NC}"
        echo -e "${YELLOW}  3. Name it 'harbormind-github-${ENVIRONMENT}'${NC}"
        echo -e "${YELLOW}  4. Click 'Connect to GitHub' and authorize${NC}"
        echo -e "${YELLOW}  5. Copy the Connection ID (last part of the ARN)${NC}"
        echo ""
        echo -n "Enter CodeConnection ID (or press Enter to skip CICD): "
        read CODE_CONNECTION_ID
        echo ""

        if [ -z "$CODE_CONNECTION_ID" ]; then
            echo -e "${YELLOW}⚠️  No CodeConnection provided - CICD stack will not deploy${NC}"
        else
            echo -e "${GREEN}✅ Using CodeConnection: ${CODE_CONNECTION_ID}${NC}"
        fi
    fi
    echo ""

    EXISTING_AL_NAME=$(aws ssm get-parameter --name "/${ENVIRONMENT}/dynamodb/tables/auditlogs/name" --query "Parameter.Value" --output text --profile ${AWS_PROFILE} --region ${AWS_REGION} 2>/dev/null || echo "")
    if [ -z "$EXISTING_AL_NAME" ] || [ "$EXISTING_AL_NAME" == "None" ]; then
        echo -e "${YELLOW}Creating placeholder auditlogs/name SSM parameter...${NC}"
        aws ssm put-parameter \
            --name "/${ENVIRONMENT}/dynamodb/tables/auditlogs/name" \
            --value "placeholder-auditlogs" \
            --type String \
            --description "Audit logs table name for ${ENVIRONMENT} (placeholder - DataStack will publish real value)" \
            --profile ${AWS_PROFILE} \
            --region ${AWS_REGION} 2>/dev/null
    fi

    echo -e "${GREEN}✅ DynamoDB table SSM parameters ready${NC}"

    # Bootstrap VPC SSM parameter (required by cdk synth — valueFromLookup resolves at synth time)
    echo -e "${BLUE}Bootstrapping VPC SSM parameter for ${ENVIRONMENT} environment...${NC}"
    # Resolve VPC ID: env var > known fallback > auto-discover > error
    RESOLVED_VPC_ID="${VPC_ID:-}"
    if [ -z "$RESOLVED_VPC_ID" ]; then
        case "$ENVIRONMENT" in
            dev)     RESOLVED_VPC_ID="vpc-0a99d3f090507d392" ;;
            staging) RESOLVED_VPC_ID="vpc-0a50c9b073975739a" ;;
            prod)    RESOLVED_VPC_ID="vpc-0b12512ca2ff8d232" ;;
            *)
                # Try to discover a non-default VPC in the account
                RESOLVED_VPC_ID=$(aws ec2 describe-vpcs --filters "Name=isDefault,Values=false" --query "Vpcs[0].VpcId" --output text --profile ${AWS_PROFILE} --region ${AWS_REGION} 2>/dev/null || echo "")
                if [ -z "$RESOLVED_VPC_ID" ] || [ "$RESOLVED_VPC_ID" == "None" ]; then
                    echo -e "${RED}❌ VPC_ID env var required for environment: ${ENVIRONMENT}${NC}"
                    echo -e "${YELLOW}Usage: VPC_ID=vpc-0abc123 $0 ${ENVIRONMENT} ${DEPLOY_TYPE}${NC}"
                    exit 1
                fi
                ;;
        esac
    fi
    # Check if parameter already exists with the correct value
    EXISTING_VPC_ID=$(aws ssm get-parameter --name "/${ENVIRONMENT}/infrastructure/vpc-id" --query "Parameter.Value" --output text --profile ${AWS_PROFILE} --region ${AWS_REGION} 2>/dev/null || echo "")
    if [ -z "$EXISTING_VPC_ID" ] || [ "$EXISTING_VPC_ID" == "None" ]; then
        aws ssm put-parameter \
            --name "/${ENVIRONMENT}/infrastructure/vpc-id" \
            --value "${RESOLVED_VPC_ID}" \
            --type String \
            --description "VPC ID for ${ENVIRONMENT} environment" \
            --profile ${AWS_PROFILE} \
            --region ${AWS_REGION} 2>/dev/null
        echo -e "${GREEN}✅ VPC SSM parameter created: /${ENVIRONMENT}/infrastructure/vpc-id = ${RESOLVED_VPC_ID}${NC}"
    elif [ "$EXISTING_VPC_ID" != "$RESOLVED_VPC_ID" ] && [ -n "${VPC_ID:-}" ]; then
        aws ssm put-parameter \
            --name "/${ENVIRONMENT}/infrastructure/vpc-id" \
            --value "${RESOLVED_VPC_ID}" \
            --type String \
            --description "VPC ID for ${ENVIRONMENT} environment" \
            --overwrite \
            --profile ${AWS_PROFILE} \
            --region ${AWS_REGION} 2>/dev/null
        echo -e "${GREEN}✅ VPC SSM parameter updated: /${ENVIRONMENT}/infrastructure/vpc-id = ${RESOLVED_VPC_ID}${NC}"
    else
        echo -e "${GREEN}✅ VPC SSM parameter already exists: ${EXISTING_VPC_ID}${NC}"
    fi

    # Synthesize CloudFormation
    echo -e "${YELLOW}Synthesizing CloudFormation templates...${NC}"
    cdk synth -c environment=${ENVIRONMENT} --profile ${AWS_PROFILE}

    echo ""

    # Remove bootstrapped SSM parameters before deploying the stacks that create them
    # via CloudFormation. CloudFormation's EarlyValidation::ResourceExistenceCheck rejects
    # changesets that CREATE AWS::SSM::Parameter resources when a parameter with the same
    # name already exists outside CloudFormation. Cached values in cdk.context.json are
    # sufficient for subsequent synths.
    echo -e "${BLUE}Cleaning up bootstrapped SSM parameters for first-time deployment...${NC}"
    if ! aws cloudformation describe-stacks --stack-name HarborMind-${ENVIRONMENT}-Foundation --profile ${AWS_PROFILE} --region ${AWS_REGION} &>/dev/null; then
        echo -e "${YELLOW}Foundation stack not yet deployed — removing bootstrapped shared layer param${NC}"
        aws ssm delete-parameter --name "/${ENVIRONMENT}/lambda/layers/shared/arn" --profile ${AWS_PROFILE} --region ${AWS_REGION} 2>/dev/null || true
    else
        echo -e "${GREEN}✅ Foundation stack already exists — skipping cleanup${NC}"
    fi

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
            # Clear cached shared layer SSM lookup so subsequent deploys pick up the real ARN
            echo -e "${BLUE}Clearing cached shared layer SSM lookup from cdk.context.json...${NC}"
            npx cdk context --reset "ssm:account=${AWS_ACCOUNT_ID}:parameterName=/${ENVIRONMENT}/lambda/layers/shared/arn:region=${AWS_REGION}" --force 2>/dev/null || true
            echo -e "${GREEN}✅ CDK context cache cleared for shared layer ARN${NC}"

            # Remove bootstrapped DynamoDB SSM params before DataStack creates them via CloudFormation
            if ! aws cloudformation describe-stacks --stack-name Data --profile ${AWS_PROFILE} --region ${AWS_REGION} &>/dev/null; then
                echo -e "${YELLOW}Data stack not yet deployed — removing bootstrapped DynamoDB params${NC}"
                aws ssm delete-parameter --name "/${ENVIRONMENT}/dynamodb/tables/tenantusers/name" --profile ${AWS_PROFILE} --region ${AWS_REGION} 2>/dev/null || true
                aws ssm delete-parameter --name "/${ENVIRONMENT}/dynamodb/tables/tenantusers/arn" --profile ${AWS_PROFILE} --region ${AWS_REGION} 2>/dev/null || true
                aws ssm delete-parameter --name "/${ENVIRONMENT}/dynamodb/tables/auditlogs/name" --profile ${AWS_PROFILE} --region ${AWS_REGION} 2>/dev/null || true
            fi

            # Phase 3: Data (creates DynamoDB tables and SSM params needed by later stacks)
            # Note: Assets is deployed after API Gateway Core (Phase 5a) because it imports API Gateway SSM params
            echo -e "${BLUE}Phase 3: Data${NC}"
            if ! cdk deploy Data -c environment=${ENVIRONMENT} --profile ${AWS_PROFILE} ${CDK_OPTIONS}; then
                echo -e "${RED}❌ Phase 3 (Data) deployment failed${NC}"
                DEPLOYMENT_SUCCESS=false
            else
                # Phase 3-Neptune: Deploy independently so failure doesn't block the pipeline
                echo -e "${BLUE}Phase 3: Neptune${NC}"
                echo -e "${YELLOW}Note: Neptune creates graph database for attack path analysis${NC}"
                if ! cdk deploy HarborMind-${ENVIRONMENT}-Neptune -c environment=${ENVIRONMENT} --profile ${AWS_PROFILE} ${CDK_OPTIONS}; then
                    echo -e "${YELLOW}⚠️  Neptune deployment failed — continuing with remaining stacks${NC}"
                fi
                # Phase 3a: Re-deploy Foundation so Cognito Lambda triggers pick up real
                # DynamoDB table names/ARNs now that DataStack has published them to SSM.
                # Without this, the triggers would have placeholder env vars until the
                # next full deployment.
                echo -e "${BLUE}Phase 3a: Re-deploy Foundation (resolve real DynamoDB SSM values)${NC}"

                # Clear cached DynamoDB SSM lookups so cdk synth picks up real values
                echo -e "${BLUE}Clearing cached DynamoDB SSM lookups from cdk.context.json...${NC}"
                npx cdk context --reset "ssm:account=${AWS_ACCOUNT_ID}:parameterName=/${ENVIRONMENT}/dynamodb/tables/tenantusers/name:region=${AWS_REGION}" --force 2>/dev/null || true
                npx cdk context --reset "ssm:account=${AWS_ACCOUNT_ID}:parameterName=/${ENVIRONMENT}/dynamodb/tables/tenantusers/arn:region=${AWS_REGION}" --force 2>/dev/null || true
                npx cdk context --reset "ssm:account=${AWS_ACCOUNT_ID}:parameterName=/${ENVIRONMENT}/dynamodb/tables/auditlogs/name:region=${AWS_REGION}" --force 2>/dev/null || true
                echo -e "${GREEN}✅ CDK context cache cleared for DynamoDB table SSM params${NC}"

                if ! cdk deploy HarborMind-${ENVIRONMENT}-Foundation -c environment=${ENVIRONMENT} --profile ${AWS_PROFILE} ${CDK_OPTIONS}; then
                    echo -e "${RED}❌ Phase 3a (Foundation re-deploy) failed${NC}"
                    DEPLOYMENT_SUCCESS=false
                else

                # Phase 3b: CSPM (depends on Data for scans table stream ARN in SSM)
                echo -e "${BLUE}Phase 3b: CSPM${NC}"
                echo -e "${YELLOW}Note: CSPM creates cspm-findings table and uses scans table stream for check triggering${NC}"
                if ! cdk deploy HarborMind-${ENVIRONMENT}-CSPM -c environment=${ENVIRONMENT} --profile ${AWS_PROFILE} ${CDK_OPTIONS}; then
                    echo -e "${RED}❌ Phase 3b (CSPM) deployment failed${NC}"
                    DEPLOYMENT_SUCCESS=false
                else
                # Phase 3c: Activity (depends on Data for activity monitoring tables)
                echo -e "${BLUE}Phase 3c: Activity${NC}"
                echo -e "${YELLOW}Note: Activity creates activity monitoring infrastructure${NC}"
                if ! cdk deploy HarborMind-${ENVIRONMENT}-Activity -c environment=${ENVIRONMENT} --profile ${AWS_PROFILE} ${CDK_OPTIONS}; then
                    echo -e "${YELLOW}⚠️  Phase 3c (Activity) deployment failed — continuing without activity monitoring${NC}"
                fi
                # NOTE: Shared layer is managed by CDK Foundation stack with Docker bundling
                # This ensures ARM64 Linux binaries are built correctly for Lambda runtime
                # The layer ARN is stored at: /${ENVIRONMENT}/lambda/layers/shared/arn
                echo -e "${GREEN}✅ Using CDK-managed shared layer (Docker-bundled for ARM64)${NC}"
                echo ""

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

                    # Check if WAF is deployed (SecurityInfrastructure from Phase 10)
                    API_GW_CONTEXT_FLAGS="-c environment=${ENVIRONMENT}"
                    if aws ssm get-parameter --name "/${ENVIRONMENT}/security/api-waf/arn" --profile ${AWS_PROFILE} --region ${AWS_REGION} &>/dev/null; then
                        API_GW_CONTEXT_FLAGS="${API_GW_CONTEXT_FLAGS} -c waf-deployed=true"
                        echo -e "${GREEN}  WAF: detected${NC}"
                    fi

                    if ! cdk deploy HarborMind-${ENVIRONMENT}-ApiGatewayCore ${API_GW_CONTEXT_FLAGS} --profile ${AWS_PROFILE} ${CDK_OPTIONS}; then
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

                        # Phase 5a: Assets (depends on API Gateway SSM params from Phase 5 and Data SSM params from Phase 3)
                        echo -e "${BLUE}Phase 5a: Assets${NC}"
                        echo -e "${YELLOW}Note: Assets creates assets table and adds API Gateway routes for asset management${NC}"
                        if ! cdk deploy HarborMind-${ENVIRONMENT}-Assets -c environment=${ENVIRONMENT} --profile ${AWS_PROFILE} ${CDK_OPTIONS}; then
                            echo -e "${RED}❌ Phase 5a (Assets) deployment failed${NC}"
                            DEPLOYMENT_SUCCESS=false
                        else

                        # Phase 5b: Re-deploy Data to pick up Neptune, CSPM, and Assets SSM params
                        # On first deploy, Data omits these integrations because the params don't exist yet.
                        # Now that CSPM (Phase 3b) and Assets (Phase 5a) have deployed, re-deploy to wire them up.
                        echo -e "${BLUE}Phase 5b: Re-deploy Data (wire up Neptune/CSPM/Assets integrations)${NC}"

                        # Detect which optional stacks have deployed by checking SSM params
                        DATA_CONTEXT_FLAGS="-c environment=${ENVIRONMENT}"
                        if aws ssm get-parameter --name "/harbormind/${ENVIRONMENT}/neptune/cluster-endpoint" --profile ${AWS_PROFILE} --region ${AWS_REGION} &>/dev/null; then
                            DATA_CONTEXT_FLAGS="${DATA_CONTEXT_FLAGS} -c neptune-deployed=true"
                            echo -e "${GREEN}  Neptune: detected${NC}"
                        fi
                        if aws ssm get-parameter --name "/${ENVIRONMENT}/dynamodb/tables/resource-metadata/arn" --profile ${AWS_PROFILE} --region ${AWS_REGION} &>/dev/null; then
                            DATA_CONTEXT_FLAGS="${DATA_CONTEXT_FLAGS} -c cspm-deployed=true"
                            echo -e "${GREEN}  CSPM: detected${NC}"
                        fi
                        if aws ssm get-parameter --name "/${ENVIRONMENT}/dynamodb/tables/assets/arn" --profile ${AWS_PROFILE} --region ${AWS_REGION} &>/dev/null; then
                            DATA_CONTEXT_FLAGS="${DATA_CONTEXT_FLAGS} -c assets-deployed=true"
                            echo -e "${GREEN}  Assets: detected${NC}"
                        fi

                        if ! cdk deploy Data ${DATA_CONTEXT_FLAGS} --profile ${AWS_PROFILE} ${CDK_OPTIONS}; then
                            echo -e "${YELLOW}⚠️  Phase 5b (Data re-deploy) failed — stream processors may not be fully wired${NC}"
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
                                    # Configure provisioned concurrency for Neptune-dependent Lambda functions
                                    # to reduce cold start delays that cause connection timeouts
                                    echo -e "${BLUE}Configuring provisioned concurrency for Neptune-dependent Lambdas...${NC}"
                                    configure_provisioned_concurrency "graph-api" 1
                                    configure_provisioned_concurrency "relationship-builder" 1
                                    echo ""

                                    # Phase 8a: M365 (depends on Operations for scan-submit Lambda ARN)
                                    echo -e "${BLUE}Phase 8a: M365${NC}"
                                    echo -e "${YELLOW}Note: M365 creates Microsoft 365 integration and discovery Lambda functions${NC}"
                                    if ! cdk deploy HarborMind-${ENVIRONMENT}-M365 -c environment=${ENVIRONMENT} --profile ${AWS_PROFILE} ${CDK_OPTIONS}; then
                                        echo -e "${YELLOW}⚠️  Phase 8a (M365) deployment failed — continuing without M365 integration${NC}"
                                    else
                                        # Phase 8b: Re-deploy Operations to wire up M365 discover function
                                        echo -e "${BLUE}Phase 8b: Re-deploy Operations (wire up M365 integration)${NC}"
                                        if ! cdk deploy HarborMind-${ENVIRONMENT}-Operations -c environment=${ENVIRONMENT} -c m365-deployed=true --profile ${AWS_PROFILE} ${CDK_OPTIONS}; then
                                            echo -e "${YELLOW}⚠️  Phase 8b (Operations re-deploy) failed — scheduled discovery may not handle M365${NC}"
                                        fi
                                    fi

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

                                        # Update Lambda functions to use the CDK-managed shared layer
                                        # Layer ARN is stored by Foundation stack at: /${ENVIRONMENT}/lambda/layers/shared/arn
                                        echo -e "${BLUE}Updating Lambda functions with CDK-managed shared layer...${NC}"
                                        LAYER_ARN=$(aws ssm get-parameter --name "/${ENVIRONMENT}/lambda/layers/shared/arn" --query "Parameter.Value" --output text --profile ${AWS_PROFILE} --region ${AWS_REGION} 2>/dev/null || echo "")
                                        if [ -n "$LAYER_ARN" ] && [ "$LAYER_ARN" != "None" ]; then
                                            LAYER_VERSION=$(echo "$LAYER_ARN" | grep -oE '[0-9]+$')

                                            # List of Lambda functions that use the shared layer but aren't in CDK stacks
                                            # that already reference the layer (e.g., functions in Data/Operations stacks)
                                            LAMBDA_FUNCTIONS=(
                                                "graph-api"
                                                "relationship-builder"
                                            )

                                            for func in "${LAMBDA_FUNCTIONS[@]}"; do
                                                if aws lambda get-function --function-name ${func} --profile ${AWS_PROFILE} --region ${AWS_REGION} &>/dev/null; then
                                                    aws lambda update-function-configuration \
                                                        --function-name ${func} \
                                                        --layers ${LAYER_ARN} \
                                                        --profile ${AWS_PROFILE} \
                                                        --region ${AWS_REGION} >/dev/null 2>&1
                                                    echo -e "${GREEN}  ✅ Updated ${func} to layer v${LAYER_VERSION}${NC}"
                                                fi
                                            done
                                        else
                                            echo -e "${YELLOW}⚠️  Could not find CDK-managed shared layer ARN, skipping Lambda updates${NC}"
                                        fi
                                        echo ""

                                        # Phase 10: SecurityInfrastructure
                                        echo -e "${BLUE}Phase 10: SecurityInfrastructure${NC}"
                                        if ! cdk deploy HarborMind-${ENVIRONMENT}-SecurityInfrastructure -c environment=${ENVIRONMENT} --profile ${AWS_PROFILE} ${CDK_OPTIONS}; then
                                            echo -e "${RED}❌ Phase 10 deployment failed${NC}"
                                            DEPLOYMENT_SUCCESS=false
                                        else
                                            # Phase 10a: Re-deploy API Gateway Core to associate WAF
                                            echo -e "${BLUE}Phase 10a: Re-deploy API Gateway Core (associate WAF)${NC}"
                                            if ! cdk deploy HarborMind-${ENVIRONMENT}-ApiGatewayCore -c environment=${ENVIRONMENT} -c waf-deployed=true --profile ${AWS_PROFILE} ${CDK_OPTIONS}; then
                                                echo -e "${YELLOW}⚠️  Phase 10a (API Gateway WAF association) failed${NC}"
                                            fi

                                            # Phase 11: Frontend
                                            echo -e "${BLUE}Phase 11: Frontend${NC}"
                                            if ! cdk deploy HarborMind-${ENVIRONMENT}-Frontend -c environment=${ENVIRONMENT} --profile ${AWS_PROFILE} ${CDK_OPTIONS}; then
                                                echo -e "${RED}❌ Phase 11 deployment failed${NC}"
                                                DEPLOYMENT_SUCCESS=false
                                            else
                                                # Phase 12: CICD (optional - only if CodeConnection is available)
                                                if [ -n "${CODE_CONNECTION_ID}" ]; then
                                                    echo -e "${BLUE}Phase 12: CICD${NC}"
                                                    echo -e "${YELLOW}Note: CICD creates CodeBuild projects for automated deployments${NC}"
                                                    if ! cdk deploy HarborMind-${ENVIRONMENT}-CICD -c environment=${ENVIRONMENT} -c code-connection-id=${CODE_CONNECTION_ID} --profile ${AWS_PROFILE} ${CDK_OPTIONS}; then
                                                        echo -e "${YELLOW}⚠️  Phase 12 (CICD) deployment failed — continuing without CI/CD infrastructure${NC}"
                                                    else
                                                        echo -e "${GREEN}✅ CICD stack deployed successfully${NC}"
                                                        echo -e "${YELLOW}Note: CodeBuild webhooks must be configured manually:${NC}"
                                                        echo -e "${YELLOW}  1. Go to CodeBuild console${NC}"
                                                        echo -e "${YELLOW}  2. For each project, click 'Update webhook settings'${NC}"
                                                        echo -e "${YELLOW}  3. Enable webhook and select 'PUSH' and 'PULL_REQUEST_MERGED' events${NC}"
                                                    fi
                                                else
                                                    echo -e "${YELLOW}⚠️  Skipping CICD stack deployment (no CodeConnection provided)${NC}"
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
            fi
        fi
    fi
fi

if [[ "$DEPLOY_TYPE" == "platform" || "$DEPLOY_TYPE" == "both" ]]; then
    echo -e "${YELLOW}🏢 Deploying Platform Admin CDK...${NC}"
    if ! deploy_cdk "$PLATFORM_CDK_DIR" "HarborMind-${ENVIRONMENT}-PlatformAdmin" "Platform Admin Infrastructure"; then
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