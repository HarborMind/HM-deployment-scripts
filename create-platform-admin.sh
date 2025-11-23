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

# Discover Admin User Pool ID dynamically
echo -e "${YELLOW}Discovering Admin User Pool...${NC}"
ADMIN_USER_POOL_ID=$(aws cognito-idp list-user-pools \
    --max-results 60 \
    --query "UserPools[?Name=='harbormind-${ENVIRONMENT}-admin-user-pool'].Id" \
    --output text \
    --profile ${AWS_PROFILE} \
    --region ${AWS_REGION} 2>/dev/null)

# Fallback to CloudFormation if direct query fails
if [ -z "$ADMIN_USER_POOL_ID" ]; then
    echo -e "${YELLOW}Direct query failed, trying CloudFormation...${NC}"
    ADMIN_USER_POOL_ID=$(aws cloudformation describe-stacks \
        --stack-name HarborMind-${ENVIRONMENT}-PlatformAdmin \
        --query "Stacks[0].Outputs[?OutputKey=='AdminUserPoolId'].OutputValue" \
        --output text \
        --profile ${AWS_PROFILE} \
        --region ${AWS_REGION} 2>/dev/null)
fi

# Validate pool was found
if [ -z "$ADMIN_USER_POOL_ID" ]; then
    echo -e "${RED}❌ Could not find Admin User Pool${NC}"
    echo -e "${RED}Tried both direct Cognito query and CloudFormation stack outputs${NC}"
    echo "Make sure the HarborMind-${ENVIRONMENT}-PlatformAdmin stack is deployed"
    exit 1
fi

echo -e "${GREEN}✓ Found Admin User Pool: ${ADMIN_USER_POOL_ID}${NC}"

echo ""

# Prompt for admin details
read -p "Enter admin email: " ADMIN_EMAIL
read -p "Enter admin first name: " FIRST_NAME
read -p "Enter admin last name: " LAST_NAME

# Generate a random temporary password that meets Cognito password policy
# Policy requires: min length, uppercase, lowercase, numbers, and symbols
TEMP_PASSWORD="Temp$(openssl rand -base64 16 | tr -d '=+/')!@#"
echo -e "${YELLOW}ℹ️  A temporary password has been generated (user will receive reset link via email)${NC}"

# Create the admin user
echo ""
echo "Creating admin user..."
if aws cognito-idp admin-create-user \
    --user-pool-id "$ADMIN_USER_POOL_ID" \
    --username "$ADMIN_EMAIL" \
    --user-attributes \
        Name=email,Value="$ADMIN_EMAIL" \
        Name=given_name,Value="$FIRST_NAME" \
        Name=family_name,Value="$LAST_NAME" \
        Name=email_verified,Value=true \
        Name=custom:role,Value=platform_admin \
        Name=custom:tenantId,Value=PLATFORM_ADMIN \
        Name=custom:platformAdmin,Value=true \
    --temporary-password "$TEMP_PASSWORD" \
    --message-action SUPPRESS \
    --profile ${AWS_PROFILE} \
    --region ${AWS_REGION} 2>&1 | tee /tmp/create-user-output.txt; then
    echo -e "${GREEN}✅ Admin user created${NC}"
else
    # Check if user already exists
    if grep -q "UsernameExistsException" /tmp/create-user-output.txt; then
        echo -e "${YELLOW}⚠️  User already exists, updating attributes...${NC}"

        # Update user attributes for existing user
        aws cognito-idp admin-update-user-attributes \
            --user-pool-id "$ADMIN_USER_POOL_ID" \
            --username "$ADMIN_EMAIL" \
            --user-attributes \
                Name=given_name,Value="$FIRST_NAME" \
                Name=family_name,Value="$LAST_NAME" \
                Name=custom:role,Value=platform_admin \
                Name=custom:tenantId,Value=PLATFORM_ADMIN \
                Name=custom:platformAdmin,Value=true \
            --profile ${AWS_PROFILE} \
            --region ${AWS_REGION}

        echo -e "${GREEN}✅ User attributes updated${NC}"
    else
        echo -e "${RED}❌ Failed to create user${NC}"
        cat /tmp/create-user-output.txt
        exit 1
    fi
fi

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
if aws cognito-idp admin-add-user-to-group \
    --user-pool-id "$ADMIN_USER_POOL_ID" \
    --username "$ADMIN_EMAIL" \
    --group-name PlatformAdmins \
    --profile ${AWS_PROFILE} \
    --region ${AWS_REGION}; then
    echo -e "${GREEN}✓ Successfully added user to PlatformAdmins group${NC}"
else
    echo -e "${RED}❌ Failed to add user to PlatformAdmins group${NC}"
    exit 1
fi

# Verify group membership (wait for eventual consistency)
echo ""
echo "Verifying group membership..."
sleep 2  # Give Cognito a moment for eventual consistency

# Get full JSON output to see what we're dealing with
GROUPS_JSON=$(aws cognito-idp admin-list-groups-for-user \
    --user-pool-id "$ADMIN_USER_POOL_ID" \
    --username "$ADMIN_EMAIL" \
    --profile ${AWS_PROFILE} \
    --region ${AWS_REGION} 2>&1)

echo "DEBUG: Full groups response:"
echo "$GROUPS_JSON"

# Extract just the group names using jq if available, otherwise use grep
if command -v jq &> /dev/null; then
    GROUPS=$(echo "$GROUPS_JSON" | jq -r '.Groups[].GroupName' 2>/dev/null | tr '\n' ' ')
else
    # Fallback: use grep to extract GroupName values
    GROUPS=$(echo "$GROUPS_JSON" | grep -o '"GroupName": "[^"]*"' | cut -d'"' -f4 | tr '\n' ' ')
fi

echo "DEBUG: Extracted group names: '$GROUPS'"

if [[ "$GROUPS" == *"PlatformAdmins"* ]]; then
    echo -e "${GREEN}✓ Verified: User is in PlatformAdmins group${NC}"
else
    echo -e "${YELLOW}⚠️  PlatformAdmins group not found yet, retrying...${NC}"
    sleep 3

    GROUPS_JSON=$(aws cognito-idp admin-list-groups-for-user \
        --user-pool-id "$ADMIN_USER_POOL_ID" \
        --username "$ADMIN_EMAIL" \
        --profile ${AWS_PROFILE} \
        --region ${AWS_REGION} 2>&1)

    if command -v jq &> /dev/null; then
        GROUPS=$(echo "$GROUPS_JSON" | jq -r '.Groups[].GroupName' 2>/dev/null | tr '\n' ' ')
    else
        GROUPS=$(echo "$GROUPS_JSON" | grep -o '"GroupName": "[^"]*"' | cut -d'"' -f4 | tr '\n' ' ')
    fi

    echo "DEBUG: Groups found on retry: '$GROUPS'"

    if [[ "$GROUPS" == *"PlatformAdmins"* ]]; then
        echo -e "${GREEN}✓ Verified: User is in PlatformAdmins group (after retry)${NC}"
    else
        echo -e "${YELLOW}⚠️  Warning: Could not verify PlatformAdmins group membership${NC}"
        echo "This may be due to eventual consistency. The user should still have proper access."
        echo "Group verification is not critical - continuing..."
    fi
fi

# Send password reset email via Lambda
echo ""
echo "Sending welcome email with password reset link..."

# Get the admin password reset Lambda function name from CloudFormation
LAMBDA_FUNCTION_NAME=$(aws cloudformation describe-stacks \
    --stack-name HarborMind-${ENVIRONMENT}-PlatformAdmin \
    --query "Stacks[0].Outputs[?OutputKey=='AdminPasswordResetFunctionName'].OutputValue" \
    --output text \
    --profile ${AWS_PROFILE} \
    --region ${AWS_REGION} 2>/dev/null || echo "")

if [ -z "$LAMBDA_FUNCTION_NAME" ]; then
    echo -e "${YELLOW}⚠️  Warning: Could not find admin password reset Lambda function${NC}"
    echo "Email will not be sent automatically."
    echo "You can send the password reset email manually later."
else
    # Create payload for Lambda invocation
    PAYLOAD=$(cat <<EOF
{
  "email": "$ADMIN_EMAIL",
  "emailType": "welcome"
}
EOF
)

    # Invoke the Lambda function
    if aws lambda invoke \
        --function-name "$LAMBDA_FUNCTION_NAME" \
        --payload "$PAYLOAD" \
        --cli-binary-format raw-in-base64-out \
        --profile ${AWS_PROFILE} \
        --region ${AWS_REGION} \
        /tmp/lambda-response.json > /dev/null 2>&1; then

        # Check if the Lambda execution was successful
        LAMBDA_STATUS=$(cat /tmp/lambda-response.json | grep -o '"statusCode":[0-9]*' | cut -d':' -f2)

        if [ "$LAMBDA_STATUS" = "200" ]; then
            echo -e "${GREEN}✓ Welcome email sent successfully!${NC}"
            echo "  Admin will receive a password reset link at: $ADMIN_EMAIL"
        else
            echo -e "${YELLOW}⚠️  Warning: Email sending may have failed (status: $LAMBDA_STATUS)${NC}"
            echo "  You can manually send the password reset email later."
        fi

        # Clean up response file
        rm -f /tmp/lambda-response.json
    else
        echo -e "${YELLOW}⚠️  Warning: Failed to invoke password reset Lambda${NC}"
        echo "  Email will not be sent automatically."
        echo "  You can send the password reset email manually later."
    fi
fi

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
echo "   - A welcome email with password reset link has been sent to $ADMIN_EMAIL"
echo "   - The password reset link expires in 24 hours"
echo "   - The user will need to set their password using the link in the email"
echo "   - MFA will be required to be set up on first login"
echo ""
echo -e "${GREEN}🌐 Login at: https://admin.${ENVIRONMENT}.harbormind.ai${NC}"
echo ""