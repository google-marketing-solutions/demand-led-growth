#!/bin/bash
echo "=================================================="
echo "🎉 Demand Led Growth - Setup Starting..."
echo "=================================================="
BOLD='\033[1m'
CYAN='\033[1;36m'
RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

PROJECT_ID=$(gcloud config get-value project)
CRON_SCHEDULE="0 2 * * *"
SQL_FILE="dlg_script.sql"
TRACKER_FILE="tracker.py"
USER_TIMEZONE=$(timedatectl show --property=Timezone --value 2>/dev/null || cat /etc/timezone 2>/dev/null || echo "UTC")

# Add a safety check in case no project is set
if [ -z "$PROJECT_ID" ]; then
    echo "Error: No Google Cloud project is set. Please run 'gcloud config set project [PROJECT_ID]' first."
    exit 1
fi

RAW_REGION=$(gcloud config get-value compute/region 2>/dev/null)

if [ "${#RAW_REGION}" -eq 2 ]; then
    LOCATION="$RAW_REGION"
    echo "DEBUG: Valid 2-character region found: '$LOCATION'"
else
    LOCATION="EU"
    echo "DEBUG: Region '$RAW_REGION' is invalid or unset. Defaulting to: '$LOCATION'"
fi

read -p "$(printf "${GREEN}${BOLD}To help with development and get usage stats, do you consent to sending an annonymouse tracking ping to our server to say you are installing the tool? (y/n):${NC} ")" confirm

case "$confirm" in 
  ([yY] | [yY][eE][sS] ) 
    echo "Thank you! This will help us continue to develop these solutions!"
    ;;
  (*)
    echo "No worries, we will not send any tracking pixels during your deployment."
    ;;
esac

while true; do
  read -p "$(printf "${CYAN}${BOLD}Enter an instance name (default: main): ${NC}")" INSTANCE_INPUT
  INSTANCE=${INSTANCE_INPUT:-main}
  DATASET="dlg_data_${INSTANCE}"
  FX_TABLE_NAME="historical_fx_rates_${INSTANCE}"
  FUNCTION_NAME="fetch-and-load-fx-rates_${INSTANCE}"
  JOB_NAME="daily-fx-rate-sync_${INSTANCE}"
  FX_TARGET_TABLE="${PROJECT_ID}.${DATASET}.${FX_TABLE_NAME}"

  while true; do
    echo -e "${CYAN}${BOLD}Select a region to deploy the solution into:${NC}"
    echo "1) europe-west1 (best for Europe and the UK)"
    echo "2) us-central1 (best for North and South America)"
    echo "3) asia-northeast1 (best for Asia and Australia)"
    read -p "Enter choice [1-3]: " region_choice

    case $region_choice in
      1) REGION="europe-west1"; break ;;
      2) REGION="us-central1"; break ;;
      3) REGION="asia-northeast1"; break ;;
      *)
        echo -e "${RED}Invalid selection. Please enter a valid choice [1-3].${NC}"
        ;;
    esac
  done

  while true; do
    echo -e "${CYAN}${BOLD}Select a global currency for aggregated overviews:${NC}"
    echo "1) EUR"
    echo "2) USD"
    echo "3) GBP"
    read -p "Enter choice [1-3]: " currency_choice

    case $currency_choice in
      1) TARGET_CURRENCY="EUR"; break ;;
      2) TARGET_CURRENCY="USD"; break ;;
      3) TARGET_CURRENCY="GBP"; break ;;
      *)
        echo -e "${RED}Invalid selection. Please enter a valid choice [1-3].${NC}"
        ;;
    esac
  done

  read -p "$(printf "${CYAN}${BOLD}Enter comma-separated Customer IDs:${NC} ")" ID_LIST

  echo -e "\n${GREEN}${BOLD}Confirm this setup is correct?${NC}"
  echo "Instance Name: ${INSTANCE}"
  echo "Project ID: ${PROJECT_ID}"
  echo "Location: ${LOCATION}"
  echo "Region: ${REGION}"
  echo "Dataset: ${DATASET}"
  echo "Target Currency: ${TARGET_CURRENCY}"
  echo "Customer IDs: ${ID_LIST}"
  echo "=================================================="

  read -p "$(printf "${CYAN}${BOLD}Proceed with this configuration? (y/n):${NC} ")" confirm_setup
  case "$confirm_setup" in 
    ([yY] | [yY][eE][sS] ) 
      break 
      ;;
    (*)
      echo -e "${RED}Restarting configuration...${NC}\n"
      ;;
  esac
done

echo "--- Starting automated FX Pipeline setup for project: ${PROJECT_ID}..."

case "$confirm" in 
  ([yY] | [yY][eE][sS])
    python3 -m pip install --upgrade pip --quiet --no-warn-script-location
    python3 -m pip install absl-py tadau --quiet --no-warn-script-location
    python3 "$TRACKER_FILE" --customer_ids "$ID_LIST" --project_id "$PROJECT_ID"
    ;;
esac

# ==========================================
# Enable APIs
# ==========================================

echo "--- Enabling required Google Cloud APIs..."
if gcloud services list --enabled --filter="NAME:cloudfunctions.googleapis.com" --format="value(name)" &>/dev/null; then
  echo "- APIs are already active. Skipping..."
else
  echo "- Turning on missing platform APIs..."
  gcloud services enable artifactregistry.googleapis.com cloudfunctions.googleapis.com run.googleapis.com eventarc.googleapis.com cloudbuild.googleapis.com cloudscheduler.googleapis.com bigquery.googleapis.com --project="${PROJECT_ID}"
fi

if bq show "$DATASET" > /dev/null 2>&1; then
    echo "Dataset '$DATASET' already exists. Skipping creation..."
else
    echo "Creating dataset '$DATASET'..."
    bq mk --dataset --location="$LOCATION" "$PROJECT_ID:$DATASET"
fi

IFS=',' read -ra AD_IDS <<< "$ID_LIST"

for CID in "${AD_IDS[@]}"; do
    echo "--- Setting up Connectors for: $CID ---"

    echo "Creating Standard Report Connector..."
    START_TIME=$(date -u -d "31 days ago" +"%Y-%m-%dT%H:%M:%SZ")
    END_TIME=$(date -u -d "yesterday" +"%Y-%m-%dT%H:%M:%SZ")

    # 2. Standard Connector
    echo "Creating Standard Report Connector..."
    STANDARD_OUTPUT=$(bq mk --transfer_config \
        --project_id="$PROJECT_ID" \
        --data_source=google_ads \
        --target_dataset="$DATASET" \
        --display_name="Standard_DLB_$CID" \
        --time_zone="$USER_TIMEZONE" \
        --schedule="every day 03:00" \
        --refresh_window_days=30 \
        --params="{
            \"customer_id\": \"$CID\",
            \"table_filter\": \"Customer,Campaign,Budget,CampaignBasicStats\"
        }")

    # Extract the config resource name from the output
    # Expected output format: Transfer configuration 'projects/.../transferConfigs/...' successfully created.
    STANDARD_CONFIG=$(echo "$STANDARD_OUTPUT" | grep -o "projects/[^']*")

    echo "Triggering 30-day manual backfill for Standard Connector..."
    bq mk --transfer_run \
        --start_time="$START_TIME" \
        --end_time="$END_TIME" \
        "$STANDARD_CONFIG"

    # 3. Custom Connector
    echo "Creating Custom Report Connector..."
    CUSTOM_OUTPUT=$(bq mk --transfer_config \
        --project_id="$PROJECT_ID" \
        --data_source=google_ads \
        --target_dataset="$DATASET" \
        --display_name="Custom_DLB_$CID" \
        --time_zone="$USER_TIMEZONE" \
        --schedule="every day 03:00" \
        --refresh_window_days=30 \
        --params="{
            \"customer_id\": \"$CID\",
            \"custom_report_table_names\": [
                \"CustomRecommendations\",
                \"CustomBiddingStrategies\",
                \"CustomAccessibleBiddingStrategies\",
                \"CustomCampaignMetrics\",
                \"CustomCampaignSettings\",
                \"CustomBudgetSettings\"
            ],
            \"custom_report_queries\": [
                \"SELECT recommendation.resource_name, recommendation.type, recommendation.campaign, recommendation.campaigns, recommendation.campaign_budget_recommendation, recommendation.move_unused_budget_recommendation, recommendation.raise_target_cpa_recommendation, recommendation.lower_target_roas_recommendation, recommendation.impact FROM recommendation\",
                \"SELECT segments.date, bidding_strategy.id, bidding_strategy.name, bidding_strategy.type, bidding_strategy.target_cpa.target_cpa_micros, bidding_strategy.target_roas.target_roas, bidding_strategy.maximize_conversions.target_cpa_micros, bidding_strategy.maximize_conversion_value.target_roas FROM bidding_strategy\",
                \"SELECT segments.date, accessible_bidding_strategy.id, accessible_bidding_strategy.name, accessible_bidding_strategy.type, accessible_bidding_strategy.owner_customer_id, accessible_bidding_strategy.target_cpa.target_cpa_micros, accessible_bidding_strategy.target_roas.target_roas, accessible_bidding_strategy.maximize_conversions.target_cpa_micros, accessible_bidding_strategy.maximize_conversion_value.target_roas FROM accessible_bidding_strategy\",
                \"SELECT segments.date, campaign.id, campaign.target_cpa.target_cpa_micros, campaign.target_roas.target_roas, campaign.maximize_conversions.target_cpa_micros, campaign.maximize_conversion_value.target_roas, metrics.average_target_cpa_micros, metrics.average_target_roas, metrics.search_rank_lost_impression_share, metrics.search_budget_lost_impression_share, metrics.video_trueview_views FROM campaign\",
                \"SELECT campaign.id, campaign.ai_max_setting.enable_ai_max, campaign.asset_automation_settings FROM campaign\",
                \"SELECT campaign_budget.id, campaign_budget.period FROM campaign_budget\"
            ]
        }")

    CUSTOM_CONFIG=$(echo "$CUSTOM_OUTPUT" | grep -o "projects/[^']*")

    echo "Triggering 30-day manual backfill for Custom Connector..."
    bq mk --transfer_run \
        --start_time="$START_TIME" \
        --end_time="$END_TIME" \
        "$CUSTOM_CONFIG"
done

# ==========================================
# CREATE THE BIGQUERY SCHEMA
# ==========================================
echo "--- Checking and creating BigQuery table for FX data: ${FX_TARGET_TABLE}..."

# Check if table already exists, if not, create it
if ! bq show --project_id="${PROJECT_ID}" "${DATASET}.${FX_TABLE_NAME}" &>/dev/null; then
  bq mk --project_id="${PROJECT_ID}" \
    --table \
    --description "Daily FX multipliers to convert local currencies to USD" \
    "${DATASET}.${FX_TABLE_NAME}" \
    "date:DATE,base_currency:STRING,target_currency:STRING,rate:FLOAT"
  echo "- BigQuery FX table created successfully."
else
  echo "- BigQuery FX table already exists. Skipping creation."
fi

if [ ! -f "main.py" ] || [ ! -f "requirements.txt" ]; then
  echo "- Error: Missing local deployment source files (main.py or requirements.txt)."
  exit 1
fi

# ==========================================
# PREPARE THE STAGING DIRECTORY
# ==========================================
echo "--- Preparing deployment asset container folder..."
mkdir -p ./fx_tmp_deploy_dir

# Copy your local standalone scripts into the isolated deployment target folder
cp requirements.txt ./fx_tmp_deploy_dir/
cp main.py ./fx_tmp_deploy_dir/  # Renamed natively to match entry requirements

cd ./fx_tmp_deploy_dir

# ==========================================
# CREATE PIPELINE IDENTITY & ROLES
# ==========================================
echo "--- Setting up dedicated service account for FX pipeline..."
SA_NAME="bq-fx-pipeline-sa"
FX_SA_EMAIL="${SA_NAME}@${PROJECT_ID}.iam.gserviceaccount.com"

# Create the Service Account if it doesn't exist (Move to root briefly to run SA commands safely)
if ! gcloud iam service-accounts describe "${FX_SA_EMAIL}" --project="${PROJECT_ID}" &>/dev/null; then
  gcloud iam service-accounts create "${SA_NAME}" \
    --project="${PROJECT_ID}" \
    --display-name="BigQuery Daily FX Pipeline Service Account" \
    --quiet
  echo "- Custom service account created."
else
  echo "- Service account already exists. Skipping creation...."
fi

echo "🛡️ Adding required roles to Service Account..."
gcloud projects add-iam-policy-binding "${PROJECT_ID}" \
  --member="serviceAccount:${FX_SA_EMAIL}" \
  --role="roles/bigquery.dataEditor" \
  --quiet >/dev/null

gcloud projects add-iam-policy-binding "${PROJECT_ID}" \
  --member="serviceAccount:${FX_SA_EMAIL}" \
  --role="roles/bigquery.jobUser" \
  --quiet

gcloud projects add-iam-policy-binding "${PROJECT_ID}" \
  --member="serviceAccount:${FX_SA_EMAIL}" \
  --role="roles/iam.serviceAccountTokenCreator" \
  --quiet >/dev/null

gcloud projects add-iam-policy-binding "${PROJECT_ID}" \
  --member="serviceAccount:${FX_SA_EMAIL}" \
  --role="roles/run.invoker" \
  --quiet >/dev/null

echo "--- Service account roles added."

# ==========================================
# DEPLOY THE CLOUD FUNCTION
# ==========================================
echo "--- Deploying 2nd-Gen Cloud Function (this may take 1-2 minutes)..."

gcloud functions deploy "${FUNCTION_NAME}" \
  --project="${PROJECT_ID}" \
  --region="${REGION}" \
  --gen2 \
  --runtime=python310 \
  --trigger-http \
  --entry-point=fetch_and_load_fx \
  --service-account="${FX_SA_EMAIL}" \
  --no-allow-unauthenticated \
  --set-env-vars=FX_TARGET_TABLE="${FX_TARGET_TABLE}",TARGET_CURRENCY="${TARGET_CURRENCY}" \
  --source=.

# ------------------------------------------
# FETCH THE ACCURATE FUNCTION URL
# ------------------------------------------
echo "--- Retrieving function endpoint URL..."
FUNCTION_URL=$(gcloud functions describe "${FUNCTION_NAME}" \
  --project="${PROJECT_ID}" \
  --region="${REGION}" \
  --gen2 \
  --format="value(serviceConfig.uri)")

if [ -z "${FUNCTION_URL}" ]; then
  echo "❌ Error: Failed to extract Cloud Function URL. Cannot proceed with Scheduler setup."
  exit 1
fi

echo "- Found URL: ${FUNCTION_URL}"

# Clean up and exit the temporary directory properly
cd ..
rm -rf ./fx_tmp_deploy_dir

# ==========================================
# CREATE AUTOMATED CLOUD SCHEDULER JOB
# ==========================================
echo "--- Setting up Cloud Scheduler Job..."

# Delete the scheduler job if it exists to avoid conflicts on script reruns
gcloud scheduler jobs delete "${JOB_NAME}" --project="${PROJECT_ID}" --location="${REGION}" --quiet &>/dev/null || true

# Create fresh daily cron trigger configuration mapping securely to the custom identity
gcloud scheduler jobs create http "${JOB_NAME}" \
  --project="${PROJECT_ID}" \
  --location="${REGION}" \
  --time-zone="$USER_TIMEZONE" \
  --schedule="${CRON_SCHEDULE}" \
  --uri="${FUNCTION_URL}" \
  --http-method=GET \
  --oidc-service-account-email="${FX_SA_EMAIL}" \
  --oidc-token-audience="${FUNCTION_URL}"

seconds=30
while [ $seconds -gt 0 ]; do
   echo -ne "Waiting for scheduler to propagate... $seconds seconds remaining\r"
   sleep 1
   : $((seconds--))
done

echo "- Triggering initial sync..."
gcloud scheduler jobs run "${JOB_NAME}" --location="${REGION}" --quiet

echo "--- All data sources created. Waiting 30 seconds to ensure everything is created... ---"
seconds=30
while [ $seconds -gt 0 ]; do
   echo -ne "Waiting... $seconds seconds remaining\r"
   sleep 1
   : $((seconds--))
done

# ==========================================
# Copy core query to scheduled queries
# ==========================================
export PROJECT_ID="$PROJECT_ID"
export DATASET="$DATASET"
export FX_TABLE_NAME="$FX_TABLE_NAME"
SQL_QUERY=$(envsubst < "$SQL_FILE" | tr '\n' ' ' | sed 's/"/\\"/g' | sed 's/  */ /g')

echo "--- Scheduling SQL transformation for Dataset: $DATASET ---"

bq mk --transfer_config \
    --project_id="$PROJECT_ID" \
    --location="$LOCATION" \
    --data_source=scheduled_query \
    --display_name="DLG_Daily_SQL_${INSTANCE}" \
    --time_zone="$USER_TIMEZONE" \
    --schedule="every day 05:00" \
    --params="{
        \"query\": \"$SQL_QUERY\"
    }"

echo "=================================================="
echo "🎉 PIPELINE SUCCESS: Infrastructure setup complete!"
echo "=================================================="
echo "🎯 BigQuery Target:  ${FX_TARGET_TABLE}"
echo "🌐 Function Endpoint: ${FUNCTION_URL}"
echo "📅 Sync Schedule:     ${CRON_SCHEDULE} UTC daily"
echo "=================================================="

# Example of dynamically generating the link in your script
TEMPLATE_URL="https://datastudio.google.com/c/reporting/a92e51b5-7b7f-4f00-a0e7-6fdc8f3e22c8/page/ICP2F/"
PARAMS="params=%7B%22ds0.projectid%22%3A%22${PROJECT_ID}%22%2C%22ds0.datasetid%22%3A%22${DATASET}%22%7D"

echo "=================================================="
echo "🎉 FINAL STEP: Create a copy of the dashboard!"
echo "=================================================="
echo "👉 Click here to make a copy and configure your dashboard:"
echo "${TEMPLATE_URL}?${PARAMS}"
echo "=================================================="