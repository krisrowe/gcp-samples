#!/bin/bash
# ------------------------------------------------------------------------------
# Private Service Connect (PSC) E2E Validation Script
#
# This script:
# 1. Reads core outputs from the Stage 2 (Consumer) Terraform state.
# 2. Ephemerally provisions test infrastructure using gcloud CLI:
#    - A test client VM (in the Consumer VPC, strictly private).
#    - A mock backend VM (in the Producer VPC running a Python HTTP daemon).
#    - An Unmanaged Instance Group to link the mock backend to the ILB.
#    - Temporary developer IAP SSH firewall rules for both VPCs.
# 3. Polls the GCP Load Balancer health check API until the backend is HEALTHY.
# 4. Executes a curl command from the client VM via IAP to test the PSC tunnel.
# 5. Automatically cleans up all temporary resources via trap, ensuring zero pollution!
# ------------------------------------------------------------------------------

set -euo pipefail

# Color definitions
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0;49;39m' # No Color

echo -e "${BLUE}======================================================================${NC}"
echo -e "${BLUE}        Private Service Connect (PSC) End-to-End Validator            ${NC}"
echo -e "${BLUE}======================================================================${NC}"

# Path to the Stage 2 Terraform directory
CONSUMER_TF_DIR=${1:-"../stage-2-consumer"}

if [ ! -d "$CONSUMER_TF_DIR" ]; then
    echo -e "${RED}Error: Consumer Terraform directory '$CONSUMER_TF_DIR' does not exist.${NC}"
    exit 1
fi

echo -e "${YELLOW}Reading core Terraform outputs from: ${CONSUMER_TF_DIR}...${NC}"

# Extract outputs from Terraform state
cd "$CONSUMER_TF_DIR"
if ! terraform output >/dev/null 2>&1; then
    echo -e "${RED}Error: No Terraform outputs found. Have you run 'terraform apply' in stage-2-consumer?${NC}"
    exit 1
fi

# Core production resources
PSC_IP=$(terraform output -raw psc_endpoint_ip)
PROJECT_ID=$(terraform output -raw consumer_project_id)
REGION="us-central1"

# Temporary resource names
BACKEND_VM="psc-backend-test-temp"
CLIENT_VM="psc-client-test-temp"
BACKEND_GROUP="psc-backend-group-temp"
PRODUCER_VPC="psc-producer-vpc"
CONSUMER_VPC="psc-consumer-vpc"
PRODUCER_SUBNET="psc-producer-subnet"
CONSUMER_SUBNET="psc-consumer-subnet"

echo -e "${GREEN}Successfully extracted outputs:${NC}"
echo -e "  - PSC Endpoint IP : ${YELLOW}${PSC_IP}${NC}"
echo -e "  - GCP Project ID  : ${YELLOW}${PROJECT_ID}${NC}"
echo

# ------------------------------------------------------------------------------
# Cleanup Function (Registered on exit to guarantee cleanup!)
# ------------------------------------------------------------------------------
cleanup() {
    echo -e "\n${YELLOW}Cleaning up ephemeral test resources...${NC}"
    
    # Delete client VM
    echo -e "Deleting temporary client VM..."
    gcloud compute instances delete "$CLIENT_VM" --project="$PROJECT_ID" --zone="${REGION}-f" --quiet || true
    
    # Remove backend from Backend Service
    echo -e "Detaching temporary backend from load balancer..."
    gcloud compute backend-services remove-backend psc-producer-backend-service \
        --project="$PROJECT_ID" \
        --region="$REGION" \
        --instance-group="$BACKEND_GROUP" \
        --instance-group-zone="${REGION}-c" \
        --quiet >/dev/null 2>&1 || true
        
    # Delete unmanaged instance group
    echo -e "Deleting temporary instance group..."
    gcloud compute instance-groups unmanaged delete "$BACKEND_GROUP" --project="$PROJECT_ID" --zone="${REGION}-c" --quiet || true
    
    # Delete mock backend VM
    echo -e "Deleting temporary backend VM..."
    gcloud compute instances delete "$BACKEND_VM" --project="$PROJECT_ID" --zone="${REGION}-c" --quiet || true
    
    # Delete temporary firewall rules
    echo -e "Deleting temporary IAP SSH firewall rules..."
    gcloud compute firewall-rules delete psc-producer-allow-iap-ssh-temp --project="$PROJECT_ID" --quiet >/dev/null 2>&1 || true
    gcloud compute firewall-rules delete psc-consumer-allow-iap-ssh-temp --project="$PROJECT_ID" --quiet >/dev/null 2>&1 || true
    
    # Delete temporary startup script file if it exists
    if [ -n "${STARTUP_SCRIPT_FILE:-}" ] && [ -f "$STARTUP_SCRIPT_FILE" ]; then
        rm -f "$STARTUP_SCRIPT_FILE"
    fi
    
    echo -e "${GREEN}Cleanup complete! Project restored to pristine state.${NC}"
}

# Register the cleanup trap
trap cleanup EXIT

# ------------------------------------------------------------------------------
# Deploy Temporary Test Infrastructure
# ------------------------------------------------------------------------------
echo -e "${BLUE}--- Deploying Ephemeral Test Infrastructure ---${NC}"

# 1. Create temporary IAP SSH firewall rules
echo -e "Creating temporary developer IAP SSH firewall rules..."
gcloud compute firewall-rules create psc-producer-allow-iap-ssh-temp \
    --project="$PROJECT_ID" \
    --network="$PRODUCER_VPC" \
    --allow=tcp:22 \
    --source-ranges="35.235.240.0/20" \
    --description="Temporary IAP SSH firewall rule for PSC validation" \
    --quiet >/dev/null

gcloud compute firewall-rules create psc-consumer-allow-iap-ssh-temp \
    --project="$PROJECT_ID" \
    --network="$CONSUMER_VPC" \
    --allow=tcp:22 \
    --source-ranges="35.235.240.0/20" \
    --description="Temporary IAP SSH firewall rule for PSC validation" \
    --quiet >/dev/null

# 2. Create temporary startup script file to prevent any bash escaping bugs
STARTUP_SCRIPT_FILE=$(mktemp)
cat <<'EOF' > "$STARTUP_SCRIPT_FILE"
#!/bin/bash
mkdir -p /var/www
echo '{"status": "success", "message": "Hello from the bare-bones PSC backend!"}' > /var/www/index.html
python3 -m http.server 80 >/dev/null 2>&1 </dev/null &
EOF

# 3. Create mock backend VM running Python HTTP daemon using the script file
echo -e "Creating temporary mock backend VM (${BACKEND_VM})..."
gcloud compute instances create "$BACKEND_VM" \
    --project="$PROJECT_ID" \
    --zone="${REGION}-c" \
    --machine-type="e2-micro" \
    --subnet="$PRODUCER_SUBNET" \
    --tags="psc-backend" \
    --metadata-from-file startup-script="$STARTUP_SCRIPT_FILE" \
    --quiet

# 3. Create Unmanaged Instance Group and add backend VM
echo -e "Creating temporary instance group and registering backend..."
gcloud compute instance-groups unmanaged create "$BACKEND_GROUP" \
    --project="$PROJECT_ID" \
    --zone="${REGION}-c" \
    --quiet >/dev/null

gcloud compute instance-groups unmanaged add-instances "$BACKEND_GROUP" \
    --project="$PROJECT_ID" \
    --zone="${REGION}-c" \
    --instances="$BACKEND_VM" \
    --quiet

# 4. Attach the group to the production Backend Service
echo -e "Attaching backend group to production load balancer..."
gcloud compute backend-services add-backend psc-producer-backend-service \
    --project="$PROJECT_ID" \
    --region="$REGION" \
    --instance-group="$BACKEND_GROUP" \
    --instance-group-zone="${REGION}-c" \
    --quiet

# 5. Create client VM in Consumer VPC (strictly private)
echo -e "Creating temporary client VM (${CLIENT_VM})..."
gcloud compute instances create "$CLIENT_VM" \
    --project="$PROJECT_ID" \
    --zone="${REGION}-f" \
    --machine-type="e2-micro" \
    --subnet="$CONSUMER_SUBNET" \
    --no-address \
    --quiet

# ------------------------------------------------------------------------------
# Poll Health Checks
# ------------------------------------------------------------------------------
echo -e "\n${BLUE}--- Waiting for Load Balancer Health Check ---${NC}"
echo -e "Polling backend health status (this can take 30-60 seconds)..."

HEALTHY=0
for i in {1..25}; do
    # Fetch health state
    HEALTH_STATE=$(gcloud compute backend-services get-health psc-producer-backend-service \
        --project="$PROJECT_ID" \
        --region="$REGION" \
        --format="value(status.healthStatus[0].healthState)" 2>/dev/null || echo "UNHEALTHY")
        
    if [ "$HEALTH_STATE" = "HEALTHY" ]; then
        echo -e "${GREEN}Success! Backend is reported as HEALTHY.${NC}"
        HEALTHY=1
        break
    fi
    echo -e "Current state: ${YELLOW}${HEALTH_STATE}${NC}. Retrying in 8s... ($i/25)"
    sleep 8
done

if [ $HEALTHY -eq 0 ]; then
    echo -e "${RED}Error: Backend failed to become healthy within the timeout period.${NC}"
    exit 1
fi

# ------------------------------------------------------------------------------
# Execute E2E Connectivity Test
# ------------------------------------------------------------------------------
echo -e "\n${BLUE}--- Running End-to-End Connectivity Validation ---${NC}"
echo -e "Executing curl request from the private client VM to the PSC IP (${PSC_IP}) via IAP..."

set +e
RAW_OUTPUT=$(gcloud compute ssh "$CLIENT_VM" \
  --project="$PROJECT_ID" \
  --zone="${REGION}-f" \
  --tunnel-through-iap \
  --command="curl -s -w '\nHTTP_STATUS:%{http_code}\n' http://$PSC_IP --connect-timeout 10" 2>&1)
SSH_EXIT_CODE=$?
set -e

# Diagnostic output
if [ $SSH_EXIT_CODE -ne 0 ]; then
    echo -e "${RED}Error: SSH tunnel command failed with exit code $SSH_EXIT_CODE.${NC}"
    echo -e "Output was:\n$RAW_OUTPUT"
    exit 1
fi

# Parse the HTTP response and status code
HTTP_STATUS=$(echo "$RAW_OUTPUT" | grep "HTTP_STATUS:" | cut -d':' -f2 || echo "000")
RESPONSE_BODY=$(echo "$RAW_OUTPUT" | grep -v "HTTP_STATUS:" | tr -d '\r' | tr -d '\n' || echo "")

echo -e "${GREEN}Response received successfully!${NC}"
echo -e "----------------------------------------------------------------------"
echo -e "HTTP Status Code : ${YELLOW}${HTTP_STATUS}${NC}"
echo -e "Response Body    : ${YELLOW}${RESPONSE_BODY}${NC}"
echo -e "----------------------------------------------------------------------"

# Assertions
echo -e "${YELLOW}Running assertions...${NC}"
FAILED=0

# 1. Assert HTTP Status is 200
if [ "$HTTP_STATUS" = "200" ]; then
    echo -e "  [PASS] HTTP Status is 200 OK"
else
    echo -e "  [${RED}FAIL${NC}] HTTP Status is $HTTP_STATUS (expected 200)"
    FAILED=1
fi

# 2. Assert Response Body contains the expected mock signature
EXPECTED_SIGNATURE="Hello from the bare-bones PSC backend!"
if [[ "$RESPONSE_BODY" == *"$EXPECTED_SIGNATURE"* ]]; then
    echo -e "  [PASS] Response body contains the expected backend signature"
else
    echo -e "  [${RED}FAIL${NC}] Response body signature mismatch!"
    echo -e "         Expected: *${EXPECTED_SIGNATURE}*"
    echo -e "         Got     : ${RESPONSE_BODY}"
    FAILED=1
fi

# E2E Summary Report
echo
if [ $FAILED -eq 0 ]; then
    echo -e "${GREEN}======================================================================${NC}"
    echo -e "${GREEN}           SUCCESS: PRIVATE SERVICE CONNECT IS WORKING E2E!          ${NC}"
    echo -e "${GREEN}======================================================================${NC}"
    exit 0
else
    echo -e "${RED}======================================================================${NC}"
    echo -e "${RED}           FAILED: Private Service Connect validation failed!        ${NC}"
    echo -e "${RED}======================================================================${NC}"
    exit 1
fi
