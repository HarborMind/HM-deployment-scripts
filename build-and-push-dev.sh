#!/bin/bash
#
# Build and push orchestrator, postgres, and lighthouse containers to AWS ECR
# Usage: ./build-and-push-dev.sh
#
# This script builds from the HarborMind monorepo root and pushes to dev ECR
#

set -euo pipefail

# Configuration
AWS_PROFILE="dev-sso"
AWS_REGION="us-east-1"
AWS_ACCOUNT_ID="202906169770"
IMAGE_TAG="dev"

ECR_REGISTRY="${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com"
REPO_PREFIX="harbormind"

# Repository names (matching existing CloudFormation templates)
ORCHESTRATOR_REPO="${REPO_PREFIX}/orchestrator-ecs"
POSTGRES_REPO="${REPO_PREFIX}/postgres-ecs"
LIGHTHOUSE_REPO="${REPO_PREFIX}/lighthouse"

# Local model path (relative to HarborMind root)
LIGHTHOUSE_MODEL_PATH="models/lighthouse-models/qwen2.5-7b-instruct-q4_k_m.gguf"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Find the HarborMind root directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HARBORMIND_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

log_info "HarborMind root: ${HARBORMIND_ROOT}"
log_info "AWS Profile: ${AWS_PROFILE}"
log_info "ECR Registry: ${ECR_REGISTRY}"
log_info "Image Tag: ${IMAGE_TAG}"

# Verify AWS SSO session is active
log_info "Checking AWS SSO session..."
if ! aws sts get-caller-identity --profile "${AWS_PROFILE}" &>/dev/null; then
    log_warn "AWS SSO session may have expired. Attempting to login..."
    aws sso login --profile "${AWS_PROFILE}"
fi

# Display account info
ACCOUNT_INFO=$(aws sts get-caller-identity --profile "${AWS_PROFILE}" --output json)
log_info "Authenticated as: $(echo "${ACCOUNT_INFO}" | jq -r '.Arn')"

# Login to ECR
log_info "Logging into ECR..."
aws ecr get-login-password --region "${AWS_REGION}" --profile "${AWS_PROFILE}" | \
    docker login --username AWS --password-stdin "${ECR_REGISTRY}"

# Change to HarborMind root for builds
cd "${HARBORMIND_ROOT}"

# Verify model file exists for Lighthouse build
if [[ ! -f "${LIGHTHOUSE_MODEL_PATH}" ]]; then
    log_error "Model file not found: ${HARBORMIND_ROOT}/${LIGHTHOUSE_MODEL_PATH}"
    log_error "Please ensure the model file exists before running this script."
    exit 1
fi
log_info "Found model file: ${LIGHTHOUSE_MODEL_PATH}"

# Build and push Orchestrator (sidecar mode - no embedded PostgreSQL)
log_info "Building orchestrator..."
docker build \
    -f orchestrator/Dockerfile.orchestrator \
    -t "${ECR_REGISTRY}/${ORCHESTRATOR_REPO}:${IMAGE_TAG}" \
    orchestrator/

log_info "Pushing orchestrator to ECR..."
docker push "${ECR_REGISTRY}/${ORCHESTRATOR_REPO}:${IMAGE_TAG}"

# Build and push PostgreSQL (STIG-compliant)
log_info "Building postgres..."
docker build \
    -t "${ECR_REGISTRY}/${POSTGRES_REPO}:${IMAGE_TAG}" \
    postgres/

log_info "Pushing postgres to ECR..."
docker push "${ECR_REGISTRY}/${POSTGRES_REPO}:${IMAGE_TAG}"

# Build and push Lighthouse (with local model baked in)
log_info "Building lighthouse (with local model baked in)..."
docker build \
    --target runtime-local-model \
    --build-arg LOCAL_MODEL_PATH="${LIGHTHOUSE_MODEL_PATH}" \
    -f lighthouse/Dockerfile \
    -t "${ECR_REGISTRY}/${LIGHTHOUSE_REPO}:${IMAGE_TAG}" \
    .

log_info "Pushing lighthouse to ECR..."
docker push "${ECR_REGISTRY}/${LIGHTHOUSE_REPO}:${IMAGE_TAG}"

# Summary
echo ""
log_info "============================================"
log_info "Build and push complete!"
log_info "============================================"
echo ""
echo "Images pushed:"
echo "  - ${ECR_REGISTRY}/${ORCHESTRATOR_REPO}:${IMAGE_TAG}"
echo "  - ${ECR_REGISTRY}/${POSTGRES_REPO}:${IMAGE_TAG}"
echo "  - ${ECR_REGISTRY}/${LIGHTHOUSE_REPO}:${IMAGE_TAG}"
echo ""
