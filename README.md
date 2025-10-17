# HarborMind Deployment Scripts

This directory contains deployment scripts for the HarborMind platform. These scripts automate the deployment of infrastructure (CDK), frontend applications, and platform administration tasks.

## Overview

| Script | Purpose | Description |
|--------|---------|-------------|
| `deploy-cdk.sh` | Infrastructure deployment | Deploys AWS CDK stacks for platform admin and/or customer app |
| `deploy-frontend-split.sh` | Frontend deployment | Builds and deploys frontend applications to S3/CloudFront |
| `create-platform-admin.sh` | Admin user creation | Creates platform admin users in Cognito |

## Prerequisites

Before using any of these scripts, ensure you have:

1. **AWS CLI** installed and configured
2. **Node.js** and **npm** installed (v18+ recommended)
3. **AWS CDK** installed (`npm install -g aws-cdk`)
4. **jq** installed for JSON parsing
5. **AWS Profile** configured with appropriate permissions

### AWS Profile Setup

```bash
# Configure a new AWS profile
aws configure --profile your-profile-name

# List available profiles
aws configure list-profiles

# Verify profile access
aws sts get-caller-identity --profile your-profile-name
```

## Script Usage

### 1. deploy-cdk.sh - Infrastructure Deployment

Deploys AWS CDK stacks for the HarborMind platform infrastructure.

#### Usage
```bash
./deploy-cdk.sh [environment] [deploy_type] [options]
```

#### Arguments
- `environment`: Target environment (`dev`, `staging`, or `prod`) - default: `dev`
- `deploy_type`: What to deploy (`platform`, `customer`, or `both`) - default: `both`
- `options`: Additional CDK options (e.g., `--require-approval never`)

#### Environment Variables
- `AWS_PROFILE`: AWS profile to use (default: `default`)
- `AWS_REGION`: AWS region (default: `us-east-1`)

#### Examples
```bash
# Deploy both platform admin and customer app to dev
./deploy-cdk.sh dev both

# Deploy only platform admin to production without approval prompts
./deploy-cdk.sh prod platform --require-approval never

# Deploy customer app to staging with specific AWS profile
AWS_PROFILE=staging-profile ./deploy-cdk.sh staging customer

# Deploy with a different AWS region
AWS_REGION=us-west-2 ./deploy-cdk.sh dev both
```

#### What It Does
1. Validates environment and deploy type
2. Checks AWS credentials and prerequisites
3. Installs npm dependencies if needed
4. Builds TypeScript code
5. Bootstraps CDK if required
6. Synthesizes CloudFormation templates
7. Deploys the specified stacks
8. Lists deployed stacks and provides next steps

#### Stack Locations
- **Platform Admin CDK**: `/platform-admin/`
- **Customer App CDK**: `/infrastructure/cdk/`

---

### 2. deploy-frontend-split.sh - Frontend Deployment

Builds and deploys frontend applications to S3 buckets with CloudFront distribution.

#### Usage
```bash
./deploy-frontend-split.sh [environment] [deploy_type]
```

#### Arguments
- `environment`: Target environment (`dev`, `staging`, or `prod`) - default: `dev`
- `deploy_type`: What to deploy (`app`, `admin`, or `both`) - default: `both`

#### Environment Variables
- `AWS_PROFILE`: AWS profile to use (default: `default`)
- `AWS_REGION`: AWS region (default: `us-east-1`)
- `BASE_DOMAIN`: Base domain for URLs (default: `harbormind.ai`)
- `AUTO_CONFIGURE`: Auto-gather config from stacks (default: `true`)
- `CUSTOM_API_URL`: Override API URL
- `CUSTOM_ADMIN_API_URL`: Override Admin API URL
- `CUSTOM_APP_URL`: Override App URL
- `CUSTOM_ADMIN_URL`: Override Admin URL

#### Examples
```bash
# Deploy both frontend apps to dev
./deploy-frontend-split.sh dev both

# Deploy only customer app to staging
./deploy-frontend-split.sh staging app

# Deploy admin portal to production with custom domain
BASE_DOMAIN=mycompany.com ./deploy-frontend-split.sh prod admin

# Deploy with specific AWS profile
AWS_PROFILE=prod-profile ./deploy-frontend-split.sh prod both

# Deploy with custom API URLs
CUSTOM_API_URL=https://api.custom.com ./deploy-frontend-split.sh dev app
```

#### What It Does
1. Validates AWS credentials and environment
2. Checks that required CDK stacks are deployed
3. Gathers configuration from CloudFormation outputs:
   - User Pool IDs and Client IDs
   - API Gateway URLs
   - S3 bucket names
   - CloudFront distribution IDs
4. Creates environment configuration files (`.env.{environment}`)
5. Builds frontend applications
6. Syncs built files to S3
7. Creates CloudFront invalidations
8. Displays deployed URLs

#### Required Stacks
The script requires these CDK stacks to be deployed first:
- `HarborMind-{env}-Foundation` (customer user pool)
- `HarborMind-{env}-PlatformAdmin` (admin user pool and S3 bucket)
- `HarborMind-{env}-ApiGateway` (API endpoints)
- `HarborMind-{env}-Frontend` (customer S3 bucket)

---

### 3. create-platform-admin.sh - Admin User Creation

Creates platform administrator users in the Cognito user pool.

#### Usage
```bash
./create-platform-admin.sh [environment]
```

#### Arguments
- `environment`: Target environment (`dev`, `staging`, or `prod`) - default: `dev`

#### Environment Variables
- `AWS_PROFILE`: AWS profile to use (default: `default`)
- `AWS_REGION`: AWS region (default: `us-east-1`)

#### Examples
```bash
# Create admin user in dev environment
./create-platform-admin.sh dev

# Create admin user in production with specific profile
AWS_PROFILE=prod-profile ./create-platform-admin.sh prod
```

#### What It Does
1. Validates environment and AWS credentials
2. Retrieves Admin User Pool ID from CloudFormation
3. Prompts for admin user details:
   - Email address
   - First name
   - Last name
4. Creates user in Cognito with temporary password
5. Adds user to `platform-admins` group
6. Displays login URL and instructions

## Typical Deployment Workflow

### Initial Setup (First Time)

1. **Deploy Infrastructure**
   ```bash
   # Deploy all CDK stacks
   ./deploy-cdk.sh dev both
   ```

2. **Deploy Frontend Applications**
   ```bash
   # Deploy both frontend apps
   ./deploy-frontend-split.sh dev both
   ```

3. **Create Platform Admin**
   ```bash
   # Create your first admin user
   ./create-platform-admin.sh dev
   ```

### Updating Existing Deployment

1. **Update Infrastructure (if needed)**
   ```bash
   # Deploy infrastructure changes
   ./deploy-cdk.sh dev both --require-approval never
   ```

2. **Update Frontend**
   ```bash
   # Deploy frontend changes
   ./deploy-frontend-split.sh dev both
   ```

### Environment-Specific Deployments

#### Development
```bash
./deploy-cdk.sh dev both
./deploy-frontend-split.sh dev both
./create-platform-admin.sh dev
```

#### Staging
```bash
AWS_PROFILE=staging ./deploy-cdk.sh staging both
AWS_PROFILE=staging ./deploy-frontend-split.sh staging both
AWS_PROFILE=staging ./create-platform-admin.sh staging
```

#### Production
```bash
AWS_PROFILE=production ./deploy-cdk.sh prod both --require-approval never
AWS_PROFILE=production ./deploy-frontend-split.sh prod both
AWS_PROFILE=production ./create-platform-admin.sh prod
```

## URL Structure

Based on the environment, the deployed applications will be available at:

### Development
- Customer App: `https://app.dev.harbormind.ai`
- Admin Portal: `https://admin.dev.harbormind.ai`
- Customer API: `https://api.dev.harbormind.ai`
- Admin API: `https://api-admin.dev.harbormind.ai`

### Staging
- Customer App: `https://app.staging.harbormind.ai`
- Admin Portal: `https://admin.staging.harbormind.ai`
- Customer API: `https://api.staging.harbormind.ai`
- Admin API: `https://api-admin.staging.harbormind.ai`

### Production
- Customer App: `https://app.harbormind.ai`
- Admin Portal: `https://admin.harbormind.ai`
- Customer API: `https://api.harbormind.ai`
- Admin API: `https://api-admin.harbormind.ai`

## Troubleshooting

### Common Issues

1. **"AWS Profile not configured"**
   ```bash
   # Configure the profile
   aws configure --profile your-profile-name
   ```

2. **"CDK not found"**
   ```bash
   # Install CDK globally
   npm install -g aws-cdk
   ```

3. **"Stack not found" errors**
   ```bash
   # Deploy the required infrastructure first
   ./deploy-cdk.sh dev both
   ```

4. **"Access Denied" errors**
   - Ensure your AWS profile has necessary permissions
   - Check IAM policies for CDK deployment permissions

5. **Frontend deployment fails**
   - Ensure CDK stacks are deployed first
   - Check that S3 buckets and CloudFront distributions exist
   - Verify npm dependencies are installed

### Debug Mode

To see more detailed output:
```bash
# Enable bash debug mode
bash -x ./deploy-cdk.sh dev both

# Check AWS CLI configuration
aws configure list --profile your-profile

# Verify stack outputs
aws cloudformation describe-stacks --stack-name HarborMind-dev-Foundation
```

## Security Notes

- Never commit AWS credentials to version control
- Use appropriate IAM roles and policies
- Rotate access keys regularly
- Use MFA for production deployments
- Review security groups and network ACLs

## Support

For issues or questions:
1. Check the troubleshooting section above
2. Review AWS CloudFormation events for deployment errors
3. Check CloudWatch logs for runtime errors
4. Consult the main project documentation in `/docs/`