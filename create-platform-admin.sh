#!/bin/bash

# Create platform admin user in Cognito Admin User Pool
# Run this after deploying the infrastructure

set -e

echo "👤 HarborMind Platform Admin User Creation"
echo "========================================="
echo ""

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Default values
ENVIRONMENT=${1:-dev}
AWS_REGION=${AWS_REGION:-us-east-1}
AWS_PROFILE=${AWS_PROFILE:-default}

echo -e "Environment: ${YELLOW}${ENVIRONMENT}${NC}"
echo -e "AWS Region: ${YELLOW}${AWS_REGION}${NC}"
echo -e "AWS Profile: ${YELLOW}${AWS_PROFILE}${NC}"
echo ""

# Get the Admin User Pool ID from CloudFormation Platform Admin stack
echo "Retrieving Admin User Pool ID..."
ADMIN_USER_POOL_ID=$(aws cloudformation describe-stacks \
    --stack-name HarborMind-${ENVIRONMENT}-PlatformAdmin \
    --query "Stacks[0].Outputs[?OutputKey=='AdminUserPoolId'].OutputValue" \
    --output text \
    --profile ${AWS_PROFILE} \
    --region ${AWS_REGION} 2>/dev/null || echo "")

if [ -z "$ADMIN_USER_POOL_ID" ]; then
    echo -e "${RED}❌ Error: Could not find Admin User Pool ID${NC}"
    echo "Make sure the HarborMind-${ENVIRONMENT}-PlatformAdmin stack is deployed"
    exit 1
fi

echo -e "${GREEN}✓ Found Admin User Pool: ${ADMIN_USER_POOL_ID}${NC}"

echo ""

# Prompt for admin details
read -p "Enter admin email: " ADMIN_EMAIL
read -p "Enter admin first name: " FIRST_NAME
read -p "Enter admin last name: " LAST_NAME
read -sp "Enter temporary password (min 14 chars): " TEMP_PASSWORD
echo ""

# Create the admin user
echo ""
echo "Creating admin user..."
aws cognito-idp admin-create-user \
    --user-pool-id "$ADMIN_USER_POOL_ID" \
    --username "$ADMIN_EMAIL" \
    --user-attributes \
        Name=email,Value="$ADMIN_EMAIL" \
        Name=given_name,Value="$FIRST_NAME" \
        Name=family_name,Value="$LAST_NAME" \
        Name=email_verified,Value=true \
        Name=custom:role,Value=platform_admin \
    --temporary-password "$TEMP_PASSWORD" \
    --message-action SUPPRESS \
    --profile ${AWS_PROFILE} \
    --region ${AWS_REGION}

echo -e "${GREEN}✅ Admin user created${NC}"

# Check if PlatformAdmins group exists, create if not
echo ""
echo "Checking PlatformAdmins group..."
if ! aws cognito-idp get-group \
    --group-name PlatformAdmins \
    --user-pool-id "$ADMIN_USER_POOL_ID" \
    --profile ${AWS_PROFILE} \
    --region ${AWS_REGION} 2>/dev/null; then
    
    echo "Creating PlatformAdmins group..."
    aws cognito-idp create-group \
        --group-name PlatformAdmins \
        --user-pool-id "$ADMIN_USER_POOL_ID" \
        --description "Platform administrators with full access" \
        --precedence 0 \
        --profile ${AWS_PROFILE} \
        --region ${AWS_REGION}
fi

# Add user to PlatformAdmins group
echo ""
echo "Adding user to PlatformAdmins group..."
aws cognito-idp admin-add-user-to-group \
    --user-pool-id "$ADMIN_USER_POOL_ID" \
    --username "$ADMIN_EMAIL" \
    --group-name PlatformAdmins \
    --profile ${AWS_PROFILE} \
    --region ${AWS_REGION}

echo ""
echo -e "${GREEN}✅ Admin user setup complete!${NC}"
echo ""
echo -e "${YELLOW}📋 Summary:${NC}"
echo "   Email: $ADMIN_EMAIL"
echo "   Name: $FIRST_NAME $LAST_NAME"
echo "   Group: PlatformAdmins"
echo "   User Pool: $ADMIN_USER_POOL_ID"
echo ""
echo -e "${YELLOW}⚠️  Important:${NC}"
echo "   - The user will need to change their password on first login"
echo "   - MFA will be required to be set up on first login"
echo ""
echo -e "${GREEN}🌐 Login at: https://admin.${ENVIRONMENT}.harbormind.ai${NC}"
echo ""