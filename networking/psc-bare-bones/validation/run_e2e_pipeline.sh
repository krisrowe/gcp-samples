#!/bin/bash
# ------------------------------------------------------------------------------
# Private Service Connect (PSC) E2E Pipeline Automation
#
# This script automates the entire end-to-end PSC lifecycle:
# 1. Deploys Stage 1 (Producer) and extracts the Service Attachment URI.
# 2. Deploys Stage 2 (Consumer), passing the Service Attachment URI as a variable.
# 3. Runs the E2E validator script to verify client-to-backend connectivity.
# 4. Prompts the user to automatically tear down all resources in the correct order.
# ------------------------------------------------------------------------------

set -euo pipefail

# Color definitions
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0;49;39m' # No Color

echo -e "${BLUE}======================================================================${NC}"
echo -e "${BLUE}        Private Service Connect (PSC) E2E Pipeline Automator          ${NC}"
echo -e "${BLUE}======================================================================${NC}"

# Get GCP Project ID
DEFAULT_PROJECT=$(gcloud config get-value project 2>/dev/null || echo "")
read -p "Enter GCP Project ID [$DEFAULT_PROJECT]: " PROJECT_ID
PROJECT_ID=${PROJECT_ID:-$DEFAULT_PROJECT}

if [ -z "$PROJECT_ID" ]; then
    echo -e "${RED}Error: GCP Project ID is required.${NC}"
    exit 1
fi

# Locate directories relative to script location
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STAGE1_DIR="$SCRIPT_DIR/../stage-1-producer"
STAGE2_DIR="$SCRIPT_DIR/../stage-2-consumer"
VALIDATE_SCRIPT="$SCRIPT_DIR/validate.sh"

# ------------------------------------------------------------------------------
# Stage 1: Deploy Producer
# ------------------------------------------------------------------------------
echo -e "\n${BLUE}--- [STAGE 1] Deploying Service Producer ---${NC}"
cd "$STAGE1_DIR"

echo -e "${YELLOW}Initializing Terraform in stage-1-producer...${NC}"
terraform init -input=false

echo -e "${YELLOW}Applying Terraform configuration...${NC}"
terraform apply -var="project_id=$PROJECT_ID" -input=false -auto-approve

echo -e "${YELLOW}Extracting Service Attachment URI...${NC}"
SERVICE_ATTACHMENT_URI=$(terraform output -raw service_attachment_uri)

if [ -z "$SERVICE_ATTACHMENT_URI" ]; then
    echo -e "${RED}Error: Failed to extract service_attachment_uri from Stage 1 outputs.${NC}"
    exit 1
fi

echo -e "${GREEN}Service Attachment Published successfully:${NC}"
echo -e "  ${YELLOW}$SERVICE_ATTACHMENT_URI${NC}"

# ------------------------------------------------------------------------------
# Stage 2: Deploy Consumer
# ------------------------------------------------------------------------------
echo -e "\n${BLUE}--- [STAGE 2] Deploying Service Consumer ---${NC}"
cd "$STAGE2_DIR"

echo -e "${YELLOW}Initializing Terraform in stage-2-consumer...${NC}"
terraform init -input=false

echo -e "${YELLOW}Applying Terraform configuration (binding to Service Attachment)...${NC}"
terraform apply -var="project_id=$PROJECT_ID" -var="service_attachment_uri=$SERVICE_ATTACHMENT_URI" -input=false -auto-approve

# ------------------------------------------------------------------------------
# Stage 3: Validate Connectivity
# ------------------------------------------------------------------------------
echo -e "\n${BLUE}--- [STAGE 3] Running End-to-End Connectivity Validation ---${NC}"
set +e
"$VALIDATE_SCRIPT" "$STAGE2_DIR"
VALIDATION_EXIT_CODE=$?
set -e

# ------------------------------------------------------------------------------
# Stage 4: Teardown Prompt
# ------------------------------------------------------------------------------
echo -e "\n${BLUE}======================================================================${NC}"
echo -e "${YELLOW}                      Teardown & Cleanup                              ${NC}"
echo -e "${BLUE}======================================================================${NC}"
echo -e "To prevent ongoing GCP resource charges, we recommend tearing down the POC."
echo -e "Note: We must destroy the Consumer stage first to release the network attachment."
echo

read -p "Do you want to destroy all deployed GCP resources now? (y/n) [y]: " DESTROY_CONFIRM
DESTROY_CONFIRM=${DESTROY_CONFIRM:-"y"}

if [[ "$DESTROY_CONFIRM" =~ ^[Yy]$ ]]; then
    # Destroy Stage 2 (Consumer) First
    echo -e "\n${YELLOW}Destroying Stage 2 (Consumer) resources...${NC}"
    cd "$STAGE2_DIR"
    terraform destroy -var="project_id=$PROJECT_ID" -var="service_attachment_uri=$SERVICE_ATTACHMENT_URI" -input=false -auto-approve

    # Destroy Stage 1 (Producer) Second
    echo -e "\n${YELLOW}Destroying Stage 1 (Producer) resources...${NC}"
    cd "$STAGE1_DIR"
    terraform destroy -var="project_id=$PROJECT_ID" -input=false -auto-approve

    echo -e "\n${GREEN}Cleanup complete! All GCP resources have been successfully destroyed.${NC}"
else
    echo -e "\n${YELLOW}Resources kept alive. You can destroy them later by running:${NC}"
    echo -e "  1. In stage-2-consumer : ${BLUE}terraform destroy -var=\"project_id=$PROJECT_ID\" -var=\"service_attachment_uri=$SERVICE_ATTACHMENT_URI\"${NC}"
    echo -e "  2. In stage-1-producer : ${BLUE}terraform destroy -var=\"project_id=$PROJECT_ID\"${NC}"
fi

exit $VALIDATION_EXIT_CODE
