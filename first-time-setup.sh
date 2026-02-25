#!/bin/bash

# First-Time Account Setup for HarborMind
# Creates a VPC with private/public subnets and NAT gateway for a new environment.
#
# Usage:
#   ./first-time-setup.sh [environment]
#
# Arguments:
#   environment    - Environment name (e.g., dev1, dev2) (default: dev1)
#
# Environment Variables:
#   AWS_PROFILE    - AWS profile to use (default: default)
#   AWS_REGION     - AWS region (default: us-east-1)
#   VPC_CIDR       - VPC CIDR block (default: 10.1.0.0/16)
#
# Examples:
#   # Setup VPC for dev1
#   AWS_PROFILE=dev1-admin ./first-time-setup.sh dev1
#
#   # Setup with custom CIDR
#   VPC_CIDR=10.2.0.0/16 AWS_PROFILE=dev2-admin ./first-time-setup.sh dev2
#
# After running this script, deploy HarborMind with:
#   VPC_ID=<output-vpc-id> AWS_PROFILE=<profile> ./deploy-cdk.sh <environment> customer

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
ENVIRONMENT=${1:-dev1}
AWS_REGION=${AWS_REGION:-us-east-1}
AWS_PROFILE=${AWS_PROFILE:-default}
VPC_CIDR=${VPC_CIDR:-10.1.0.0/16}

# Derive subnet CIDRs from VPC CIDR (assumes /16)
CIDR_PREFIX=$(echo "$VPC_CIDR" | cut -d'.' -f1-2)
PUBLIC_CIDR="${CIDR_PREFIX}.0.0/24"
PRIVATE_A_CIDR="${CIDR_PREFIX}.1.0/24"
PRIVATE_B_CIDR="${CIDR_PREFIX}.2.0/24"

AZ_A="${AWS_REGION}a"
AZ_B="${AWS_REGION}b"

echo -e "${GREEN}HarborMind First-Time Account Setup${NC}"
echo -e "Environment: ${YELLOW}${ENVIRONMENT}${NC}"
echo -e "AWS Region:  ${YELLOW}${AWS_REGION}${NC}"
echo -e "AWS Profile: ${YELLOW}${AWS_PROFILE}${NC}"
echo -e "VPC CIDR:    ${YELLOW}${VPC_CIDR}${NC}"
echo -e "  Public:    ${YELLOW}${PUBLIC_CIDR}${NC} (${AZ_A})"
echo -e "  Private A: ${YELLOW}${PRIVATE_A_CIDR}${NC} (${AZ_A})"
echo -e "  Private B: ${YELLOW}${PRIVATE_B_CIDR}${NC} (${AZ_B})"
echo ""

# Check AWS credentials
echo -e "${YELLOW}Checking AWS credentials...${NC}"
AWS_ACCOUNT_ID=$(aws sts get-caller-identity --profile ${AWS_PROFILE} --query Account --output text 2>/dev/null)
if [ -z "$AWS_ACCOUNT_ID" ] || [ "$AWS_ACCOUNT_ID" == "None" ]; then
    echo -e "${RED}Unable to authenticate with AWS profile '${AWS_PROFILE}'.${NC}"
    echo -e "${YELLOW}For SSO profiles, run: aws sso login --profile ${AWS_PROFILE}${NC}"
    exit 1
fi
echo -e "${GREEN}AWS Account: ${AWS_ACCOUNT_ID}${NC}"
echo ""

# Confirm
read -p "Create VPC infrastructure in account ${AWS_ACCOUNT_ID}? (y/N): " -n 1 -r
echo ""
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo -e "${YELLOW}Cancelled.${NC}"
    exit 0
fi
echo ""

# 1. Create VPC
echo -e "${BLUE}1/6 Creating VPC...${NC}"
VPC_ID=$(aws ec2 create-vpc \
    --cidr-block $VPC_CIDR \
    --tag-specifications "ResourceType=vpc,Tags=[{Key=Name,Value=harbormind-${ENVIRONMENT}},{Key=Project,Value=HarborMind},{Key=Environment,Value=${ENVIRONMENT}}]" \
    --query 'Vpc.VpcId' --output text \
    --profile $AWS_PROFILE --region $AWS_REGION)
echo -e "${GREEN}  VPC: ${VPC_ID}${NC}"

# Enable DNS hostnames (required for Neptune and VPC endpoints)
aws ec2 modify-vpc-attribute --vpc-id $VPC_ID --enable-dns-hostnames \
    --profile $AWS_PROFILE --region $AWS_REGION
echo -e "${GREEN}  DNS hostnames enabled${NC}"

# 2. Create Internet Gateway
echo -e "${BLUE}2/6 Creating Internet Gateway...${NC}"
IGW_ID=$(aws ec2 create-internet-gateway \
    --tag-specifications "ResourceType=internet-gateway,Tags=[{Key=Name,Value=harbormind-${ENVIRONMENT}-igw},{Key=Project,Value=HarborMind}]" \
    --query 'InternetGateway.InternetGatewayId' --output text \
    --profile $AWS_PROFILE --region $AWS_REGION)
aws ec2 attach-internet-gateway --vpc-id $VPC_ID --internet-gateway-id $IGW_ID \
    --profile $AWS_PROFILE --region $AWS_REGION
echo -e "${GREEN}  IGW: ${IGW_ID}${NC}"

# 3. Create subnets
echo -e "${BLUE}3/6 Creating subnets...${NC}"
PUBLIC_SUBNET=$(aws ec2 create-subnet \
    --vpc-id $VPC_ID --cidr-block $PUBLIC_CIDR --availability-zone $AZ_A \
    --tag-specifications "ResourceType=subnet,Tags=[{Key=Name,Value=harbormind-${ENVIRONMENT}-public-a},{Key=aws-cdk:subnet-type,Value=Public}]" \
    --query 'Subnet.SubnetId' --output text \
    --profile $AWS_PROFILE --region $AWS_REGION)
echo -e "${GREEN}  Public:    ${PUBLIC_SUBNET} (${AZ_A})${NC}"

PRIVATE_SUBNET_A=$(aws ec2 create-subnet \
    --vpc-id $VPC_ID --cidr-block $PRIVATE_A_CIDR --availability-zone $AZ_A \
    --tag-specifications "ResourceType=subnet,Tags=[{Key=Name,Value=harbormind-${ENVIRONMENT}-private-a},{Key=aws-cdk:subnet-type,Value=Private}]" \
    --query 'Subnet.SubnetId' --output text \
    --profile $AWS_PROFILE --region $AWS_REGION)
echo -e "${GREEN}  Private A: ${PRIVATE_SUBNET_A} (${AZ_A})${NC}"

PRIVATE_SUBNET_B=$(aws ec2 create-subnet \
    --vpc-id $VPC_ID --cidr-block $PRIVATE_B_CIDR --availability-zone $AZ_B \
    --tag-specifications "ResourceType=subnet,Tags=[{Key=Name,Value=harbormind-${ENVIRONMENT}-private-b},{Key=aws-cdk:subnet-type,Value=Private}]" \
    --query 'Subnet.SubnetId' --output text \
    --profile $AWS_PROFILE --region $AWS_REGION)
echo -e "${GREEN}  Private B: ${PRIVATE_SUBNET_B} (${AZ_B})${NC}"

# 4. Public route table → Internet Gateway
echo -e "${BLUE}4/6 Creating public route table...${NC}"
PUBLIC_RT=$(aws ec2 create-route-table --vpc-id $VPC_ID \
    --tag-specifications "ResourceType=route-table,Tags=[{Key=Name,Value=harbormind-${ENVIRONMENT}-public-rt}]" \
    --query 'RouteTable.RouteTableId' --output text \
    --profile $AWS_PROFILE --region $AWS_REGION)
aws ec2 create-route --route-table-id $PUBLIC_RT \
    --destination-cidr-block 0.0.0.0/0 --gateway-id $IGW_ID \
    --profile $AWS_PROFILE --region $AWS_REGION > /dev/null
aws ec2 associate-route-table --route-table-id $PUBLIC_RT --subnet-id $PUBLIC_SUBNET \
    --profile $AWS_PROFILE --region $AWS_REGION > /dev/null
echo -e "${GREEN}  Route table: ${PUBLIC_RT} → ${IGW_ID}${NC}"

# 5. NAT Gateway (in public subnet)
echo -e "${BLUE}5/6 Creating NAT Gateway (this takes 1-2 minutes)...${NC}"
EIP_ALLOC=$(aws ec2 allocate-address --domain vpc \
    --tag-specifications "ResourceType=elastic-ip,Tags=[{Key=Name,Value=harbormind-${ENVIRONMENT}-nat-eip},{Key=Project,Value=HarborMind}]" \
    --query 'AllocationId' --output text \
    --profile $AWS_PROFILE --region $AWS_REGION)
NAT_GW=$(aws ec2 create-nat-gateway --subnet-id $PUBLIC_SUBNET --allocation-id $EIP_ALLOC \
    --tag-specifications "ResourceType=natgateway,Tags=[{Key=Name,Value=harbormind-${ENVIRONMENT}-nat},{Key=Project,Value=HarborMind}]" \
    --query 'NatGateway.NatGatewayId' --output text \
    --profile $AWS_PROFILE --region $AWS_REGION)
echo -e "${YELLOW}  NAT Gateway: ${NAT_GW} (waiting for available state...)${NC}"
aws ec2 wait nat-gateway-available --nat-gateway-ids $NAT_GW \
    --profile $AWS_PROFILE --region $AWS_REGION
echo -e "${GREEN}  NAT Gateway: ${NAT_GW} (available)${NC}"

# 6. Private route table → NAT Gateway
echo -e "${BLUE}6/6 Creating private route table...${NC}"
PRIVATE_RT=$(aws ec2 create-route-table --vpc-id $VPC_ID \
    --tag-specifications "ResourceType=route-table,Tags=[{Key=Name,Value=harbormind-${ENVIRONMENT}-private-rt}]" \
    --query 'RouteTable.RouteTableId' --output text \
    --profile $AWS_PROFILE --region $AWS_REGION)
aws ec2 create-route --route-table-id $PRIVATE_RT \
    --destination-cidr-block 0.0.0.0/0 --nat-gateway-id $NAT_GW \
    --profile $AWS_PROFILE --region $AWS_REGION > /dev/null
aws ec2 associate-route-table --route-table-id $PRIVATE_RT --subnet-id $PRIVATE_SUBNET_A \
    --profile $AWS_PROFILE --region $AWS_REGION > /dev/null
aws ec2 associate-route-table --route-table-id $PRIVATE_RT --subnet-id $PRIVATE_SUBNET_B \
    --profile $AWS_PROFILE --region $AWS_REGION > /dev/null
echo -e "${GREEN}  Route table: ${PRIVATE_RT} → ${NAT_GW}${NC}"

# VPC done
echo ""
echo -e "${GREEN}VPC setup complete!${NC}"
echo -e "  VPC:            ${GREEN}${VPC_ID}${NC}"
echo -e "  Public Subnet:  ${GREEN}${PUBLIC_SUBNET}${NC}"
echo -e "  Private Subnet: ${GREEN}${PRIVATE_SUBNET_A}${NC}"
echo -e "  Private Subnet: ${GREEN}${PRIVATE_SUBNET_B}${NC}"
echo -e "  NAT Gateway:    ${GREEN}${NAT_GW}${NC}"
echo ""

# 7. Bootstrap CDK
echo -e "${BLUE}7/9 Bootstrapping CDK...${NC}"
if ! aws cloudformation describe-stacks --stack-name CDKToolkit --profile ${AWS_PROFILE} --region ${AWS_REGION} &>/dev/null; then
    cdk bootstrap aws://${AWS_ACCOUNT_ID}/${AWS_REGION} --profile ${AWS_PROFILE}
    echo -e "${GREEN}  CDK bootstrapped${NC}"
else
    echo -e "${GREEN}  CDK already bootstrapped${NC}"
fi

# 8. Bootstrap VPC SSM parameter (needed by CDK stacks at synth time)
echo -e "${BLUE}8/9 Bootstrapping VPC SSM parameter...${NC}"
aws ssm put-parameter \
    --name "/${ENVIRONMENT}/infrastructure/vpc-id" \
    --value "${VPC_ID}" \
    --type String \
    --description "VPC ID for ${ENVIRONMENT} environment" \
    --overwrite \
    --profile ${AWS_PROFILE} \
    --region ${AWS_REGION} 2>/dev/null
echo -e "${GREEN}  /${ENVIRONMENT}/infrastructure/vpc-id = ${VPC_ID}${NC}"

# 9. Deploy DNS stack and setup external DNS records
echo -e "${BLUE}9/9 Deploying DNS stack and configuring certificates...${NC}"
echo ""

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
CUSTOMER_CDK_DIR="${SCRIPT_DIR}/../SaaS-infrastructure/cdk"
DNS_STACK_NAME="HarborMind-${ENVIRONMENT}-DNS"

# Install CDK deps and build
cd "$CUSTOMER_CDK_DIR"
if [ ! -d "node_modules" ]; then
    echo -e "${YELLOW}Installing CDK dependencies...${NC}"
    npm install
fi
echo -e "${YELLOW}Building TypeScript...${NC}"
npm run build

# Bootstrap shared layer SSM placeholder (required for cdk synth)
EXISTING_LAYER_ARN=$(aws ssm get-parameter --name "/${ENVIRONMENT}/lambda/layers/shared/arn" --query "Parameter.Value" --output text --profile ${AWS_PROFILE} --region ${AWS_REGION} 2>/dev/null || echo "")
if [ -z "$EXISTING_LAYER_ARN" ] || [ "$EXISTING_LAYER_ARN" == "None" ]; then
    aws ssm put-parameter \
        --name "/${ENVIRONMENT}/lambda/layers/shared/arn" \
        --value "arn:aws:lambda:${AWS_REGION}:${AWS_ACCOUNT_ID}:layer:shared:1" \
        --type String \
        --description "Shared Lambda layer ARN for ${ENVIRONMENT} (placeholder)" \
        --profile ${AWS_PROFILE} \
        --region ${AWS_REGION} 2>/dev/null
fi

# Synth
echo -e "${YELLOW}Synthesizing CloudFormation...${NC}"
cdk synth -c environment=${ENVIRONMENT} --profile ${AWS_PROFILE} > /dev/null

# Deploy DNS stack in background so we can poll for records
echo -e "${YELLOW}Deploying DNS stack (background)...${NC}"
cdk deploy ${DNS_STACK_NAME} -c environment=${ENVIRONMENT} --profile ${AWS_PROFILE} --require-approval never &
CDK_DNS_PID=$!

# Poll until the hosted zone is created
echo -e "${YELLOW}Waiting for hosted zone...${NC}"
HZ_ID=""
for i in $(seq 1 90); do
    HZ_ID=$(aws route53 list-hosted-zones-by-name --dns-name "${ENVIRONMENT}.harbormind.ai" --max-items 1 \
        --query "HostedZones[?Name=='${ENVIRONMENT}.harbormind.ai.'].Id" --output text \
        --profile ${AWS_PROFILE} --region ${AWS_REGION} 2>/dev/null || echo "")
    if [ -n "$HZ_ID" ] && [ "$HZ_ID" != "None" ]; then
        break
    fi
    sleep 5
done

if [ -z "$HZ_ID" ] || [ "$HZ_ID" == "None" ]; then
    echo -e "${RED}Timed out waiting for hosted zone. Check CloudFormation console.${NC}"
    wait $CDK_DNS_PID 2>/dev/null
    exit 1
fi

# Get NS records
echo ""
echo -e "${GREEN}========================================================${NC}"
echo -e "${GREEN}  Add these DNS records to your provider (e.g. Cloudflare)${NC}"
echo -e "${GREEN}========================================================${NC}"
echo ""
echo -e "${YELLOW}1. NS Records — Delegate ${ENVIRONMENT}.harbormind.ai:${NC}"
echo ""
NS_RECORDS=$(aws route53 list-resource-record-sets --hosted-zone-id "$HZ_ID" \
    --query "ResourceRecordSets[?Type=='NS' && Name=='${ENVIRONMENT}.harbormind.ai.'].ResourceRecords[].Value" \
    --output text --profile ${AWS_PROFILE} --region ${AWS_REGION} 2>/dev/null)
echo -e "   ${BLUE}Type:${NC}  NS"
echo -e "   ${BLUE}Name:${NC}  ${ENVIRONMENT}"
for NS in $NS_RECORDS; do
    echo -e "   ${BLUE}Value:${NC} ${GREEN}${NS}${NC}"
done

# Poll for ACM validation CNAME records from CloudFormation events
echo ""
echo -e "${YELLOW}Waiting for certificate validation records...${NC}"
VALIDATION_RECORDS=""
for i in $(seq 1 90); do
    VALIDATION_RECORDS=$(aws cloudformation describe-stack-events \
        --stack-name ${DNS_STACK_NAME} \
        --profile ${AWS_PROFILE} --region ${AWS_REGION} \
        --query "StackEvents[?ResourceType=='AWS::CertificateManager::Certificate' && contains(to_string(ResourceStatusReason), 'Content of DNS Record')].ResourceStatusReason" \
        --output text 2>/dev/null || echo "")
    RECORD_COUNT=$(echo "$VALIDATION_RECORDS" | grep -c "Content of DNS Record" 2>/dev/null || echo "0")
    if [ "$RECORD_COUNT" -ge 3 ]; then
        break
    fi
    sleep 5
done

if [ -n "$VALIDATION_RECORDS" ] && [ "$VALIDATION_RECORDS" != "None" ]; then
    echo ""
    echo -e "${YELLOW}2. CNAME Records — Certificate validation (proxy OFF / DNS only):${NC}"
    echo ""
    echo "$VALIDATION_RECORDS" | tr '\t' '\n' | while IFS= read -r line; do
        # macOS-compatible parsing (no grep -P)
        CNAME_NAME=$(echo "$line" | sed -n 's/.*Name: *\([^,]*\),.*/\1/p' | sed 's/\.$//')
        CNAME_VALUE=$(echo "$line" | sed -n 's/.*Value: *\([^}]*\)}.*/\1/p' | sed 's/\.$//')
        if [ -n "$CNAME_NAME" ] && [ -n "$CNAME_VALUE" ]; then
            SHORT_NAME=$(echo "$CNAME_NAME" | sed "s/\.harbormind\.ai$//")
            echo -e "   ${BLUE}CNAME:${NC} ${SHORT_NAME}"
            echo -e "   ${BLUE}Value:${NC} ${GREEN}${CNAME_VALUE}${NC}"
            echo ""
        fi
    done
fi

echo -e "${GREEN}========================================================${NC}"
echo ""
echo -e "${YELLOW}Add the above records to your DNS provider now.${NC}"
echo -e "${YELLOW}Certificates will validate once DNS propagates (usually 1-5 min).${NC}"
echo ""
read -p "Press Enter once you've added the DNS records..." </dev/tty
echo ""

# Wait for DNS stack to finish
echo -e "${YELLOW}Waiting for DNS stack to complete...${NC}"
if wait $CDK_DNS_PID; then
    echo -e "${GREEN}DNS stack deployed successfully!${NC}"
else
    echo -e "${RED}DNS stack deployment failed. You may need to re-run deploy-cdk.sh after DNS propagates.${NC}"
fi

echo ""
echo -e "${GREEN}========================================================${NC}"
echo -e "${GREEN}  First-time setup complete!${NC}"
echo -e "${GREEN}========================================================${NC}"
echo ""
echo -e "${YELLOW}Deploy HarborMind:${NC}"
echo -e "  ${BLUE}VPC_ID=${VPC_ID} AWS_PROFILE=${AWS_PROFILE} ./deploy-cdk.sh ${ENVIRONMENT} customer${NC}"
echo ""
echo -e "${YELLOW}Note: deploy-cdk.sh will skip the DNS stack if it's already deployed.${NC}"
