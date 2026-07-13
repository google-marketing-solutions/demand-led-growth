#!/bin/bash
BOLD='\033[1m'
CYAN='\033[1;36m'
RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

echo -e "${GREEN}=================================================="
echo "🎉 Demand Led Growth - Setup Starting..."
echo "==================================================${NC}"

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

# ==========================================
# TRACKING VERIFICATION
# ==========================================
read -p "$(printf "${CYAN}${BOLD}To help with development and get usage stats, do you consent to sending an anonymous tracking ping to our server to say you are installing the tool? (y/n):${NC} ")" confirm

case "$confirm" in 
  ([yY] | [yY][eE][sS] ) 
    echo "Thank you! This will help us continue to develop these solutions!"
    ;;
  (*)
    echo "No worries, we will not send any tracking pixels during your deployment."
    ;;
esac

# ==========================================
# SETUP QUESTIONS FOR THE USER
# ==========================================
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

  echo -e "\n${CYAN}${BOLD}Confirm this setup is correct?${NC}"
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

echo -e "${GREEN}--- Starting automated FX Pipeline setup for project: ${PROJECT_ID}...{$NC}"

case "$confirm" in 
  ([yY] | [yY][eE][sS])
    python3 -m pip install --upgrade pip --quiet --no-warn-script-location
    python3 -m pip install absl-py tadau --quiet --no-warn-script-location
    python3 "$TRACKER_FILE" --customer_ids "$ID_LIST" --project_id "$PROJECT_ID"
    ;;
esac

# ==========================================
# ENABLE APIs
# ==========================================

echo -e "${GREEN}--- Enabling required Google Cloud APIs...${NC}"
gcloud services enable artifactregistry.googleapis.com cloudfunctions.googleapis.com run.googleapis.com eventarc.googleapis.com cloudbuild.googleapis.com cloudscheduler.googleapis.com bigquery.googleapis.com --project="${PROJECT_ID}"

# ==========================================
# CREATE THE DATASET
# ==========================================
if bq show "$DATASET" > /dev/null 2>&1; then
    echo -e "${GREEN}Dataset '$DATASET' already exists. Skipping creation...${NC}"
else
    echo -e "${GREEN}Creating dataset '$DATASET'...${NC}"
    bq mk --dataset --location="$LOCATION" "$PROJECT_ID:$DATASET"
fi

# ==========================================
# SETUP BQ CONNECTORS FOR EACH ACCOUNT
# ==========================================
IFS=',' read -ra AD_IDS <<< "$ID_LIST"
AD_IDS=("${AD_IDS[@]// /}")
for CID in "${AD_IDS[@]}"; do
    echo -e "${GREEN}--- Setting up Connectors for: $CID ---${NC}"

    START_TIME=$(date -u -d "31 days ago" +"%Y-%m-%dT%H:%M:%SZ")
    END_TIME=$(date -u -d "yesterday" +"%Y-%m-%dT%H:%M:%SZ")

    echo "- Creating Standard Report Connector..."
    STANDARD_OUTPUT=$(bq mk --transfer_config \
        --project_id="$PROJECT_ID" \
        --data_source=google_ads \
        --target_dataset="$DATASET" \
        --display_name="Standard_DLG_$CID" \
        --time_zone="$USER_TIMEZONE" \
        --schedule="every day 03:00" \
        --refresh_window_days=30 \
        --params="{
            \"customer_id\": \"$CID\",
            \"table_filter\": \"Customer,Campaign,Budget,CampaignBasicStats\"
        }")

    STANDARD_CONFIG=$(echo "$STANDARD_OUTPUT" | grep -o "projects/[^']*")

    echo "- Triggering 30-day manual backfill for Standard Connector..."
    bq mk --transfer_run \
        --start_time="$START_TIME" \
        --end_time="$END_TIME" \
        "$STANDARD_CONFIG"

    echo "- Creating Custom Report Connector..."
    CUSTOM_OUTPUT=$(bq mk --transfer_config \
        --project_id="$PROJECT_ID" \
        --data_source=google_ads \
        --target_dataset="$DATASET" \
        --display_name="Custom_DLG_$CID" \
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
                \"SELECT recommendation.resource_name, recommendation.type, recommendation.campaign, recommendation.campaigns, recommendation.campaign_budget_recommendation, recommendation.marginal_roi_campaign_budget_recommendation, recommendation.forecasting_campaign_budget_recommendation, recommendation.move_unused_budget_recommendation, recommendation.raise_target_cpa_recommendation, recommendation.lower_target_roas_recommendation, recommendation.impact FROM recommendation\",
                \"SELECT segments.date, bidding_strategy.id, bidding_strategy.name, bidding_strategy.type, bidding_strategy.target_cpa.target_cpa_micros, bidding_strategy.target_roas.target_roas, bidding_strategy.maximize_conversions.target_cpa_micros, bidding_strategy.maximize_conversion_value.target_roas FROM bidding_strategy\",
                \"SELECT segments.date, accessible_bidding_strategy.id, accessible_bidding_strategy.name, accessible_bidding_strategy.type, accessible_bidding_strategy.owner_customer_id, accessible_bidding_strategy.target_cpa.target_cpa_micros, accessible_bidding_strategy.target_roas.target_roas, accessible_bidding_strategy.maximize_conversions.target_cpa_micros, accessible_bidding_strategy.maximize_conversion_value.target_roas FROM accessible_bidding_strategy\",
                \"SELECT segments.date, campaign.id, campaign.target_cpa.target_cpa_micros, campaign.target_roas.target_roas, campaign.maximize_conversions.target_cpa_micros, campaign.maximize_conversion_value.target_roas, metrics.average_target_cpa_micros, metrics.average_target_roas, metrics.search_rank_lost_impression_share, metrics.search_budget_lost_impression_share, metrics.video_trueview_views FROM campaign\",
                \"SELECT campaign.id, campaign.ai_max_setting.enable_ai_max, campaign.asset_automation_settings FROM campaign\",
                \"SELECT campaign_budget.id, campaign_budget.period FROM campaign_budget\"
            ]
        }")

    CUSTOM_CONFIG=$(echo "$CUSTOM_OUTPUT" | grep -o "projects/[^']*")

    echo "- Triggering 30-day manual backfill for Custom Connector..."
    bq mk --transfer_run \
        --start_time="$START_TIME" \
        --end_time="$END_TIME" \
        "$CUSTOM_CONFIG"
done

# ==========================================
# CREATE THE BIGQUERY SCHEMA FOR FX DATA
# ==========================================
echo -e "${GREEN}--- Checking and creating BigQuery table for FX data: ${FX_TARGET_TABLE}...${NC}"

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
  echo -e "${RED}- Error: Missing local deployment source files (main.py or requirements.txt).${NC}"
  exit 1
fi

# ==========================================
# PREPARE THE STAGING DIRECTORY FOR FX SCRIPT
# ==========================================
echo -e "${GREEN}--- Preparing deployment asset container folder...${NC}"
mkdir -p ./fx_tmp_deploy_dir

# Copy your local standalone scripts into the isolated deployment target folder
cp requirements.txt ./fx_tmp_deploy_dir/
cp main.py ./fx_tmp_deploy_dir/  # Renamed natively to match entry requirements

cd ./fx_tmp_deploy_dir

# ==========================================
# CREATE PIPELINE IDENTITY & ROLES
# ==========================================
echo -e "${GREEN}--- Setting up dedicated service account for FX pipeline...${NC}"
SA_NAME="bq-fx-pipeline-sa"
FX_SA_EMAIL="${SA_NAME}@${PROJECT_ID}.iam.gserviceaccount.com"

if ! gcloud iam service-accounts describe "${FX_SA_EMAIL}" --project="${PROJECT_ID}" &>/dev/null; then
  gcloud iam service-accounts create "${SA_NAME}" \
    --project="${PROJECT_ID}" \
    --display-name="BigQuery Daily FX Pipeline Service Account" \
    --quiet
  echo "- Custom service account created."
else
  echo "- Service account already exists. Skipping creation...."
fi

echo "- Adding required roles to Service Account..."
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

echo -e "${GREEN}--- Service account roles added...${NC}"

# ==========================================
# DEPLOY THE CLOUD FUNCTION FOR FX DATA RUNS
# ==========================================
echo -e "${GREEN}--- Deploying 2nd-Gen Cloud Function (this may take 1-2 minutes)...${NC}"

gcloud functions deploy "${FUNCTION_NAME}" \
  --project="${PROJECT_ID}" \
  --region="${REGION}" \
  --gen2 \
  --runtime=python312 \
  --trigger-http \
  --entry-point=fetch_and_load_fx \
  --service-account="${FX_SA_EMAIL}" \
  --no-allow-unauthenticated \
  --set-env-vars=FX_TARGET_TABLE="${FX_TARGET_TABLE}",TARGET_CURRENCY="${TARGET_CURRENCY}" \
  --source=.

# ==========================================
# FETCH THE ACCURATE FUNCTION URL
# ==========================================
echo -e "${GREEN}--- Retrieving function endpoint URL...${NC}"
FUNCTION_URL=$(gcloud functions describe "${FUNCTION_NAME}" \
  --project="${PROJECT_ID}" \
  --region="${REGION}" \
  --gen2 \
  --format="value(serviceConfig.uri)")

if [ -z "${FUNCTION_URL}" ]; then
  echo -e "${RED}Error: Failed to extract Cloud Function URL. Cannot proceed with Scheduler setup!${NC}"
  exit 1
fi

echo "- Found URL: ${FUNCTION_URL}"

cd ..
rm -rf ./fx_tmp_deploy_dir

# ==========================================
# CREATE AUTOMATED CLOUD SCHEDULER JOB FOR DAILY FX FETCH
# ==========================================
echo -e "${GREEN}--- Setting up Cloud Scheduler Job for FX sync...${NC}"

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

SLEEP_TIME=20
MAX_ATTEMPTS=10
ATTEMPT=1
echo -e "${GREEN}--- Waiting for Cloud Scheduler job '{$JOB_NAME}' to be ready ---${NC}"

while [ "${ATTEMPT}" -le "${MAX_ATTEMPTS}" ]; do
    JOB_STATE=$(gcloud scheduler jobs describe "${JOB_NAME}" \
        --location="${REGION}" \
        --format="value(state)" \
        2>/dev/null)

    if [ "${JOB_STATE}" == "ENABLED" ]; then
        echo "Success! Job is ENABLED. Triggering manual run..."
        gcloud scheduler jobs run "${JOB_NAME}" --location="${REGION}" --quiet
        echo "Job triggered successfully."
        break
    fi
    
    sleep "${SLEEP_TIME}"
    ((ATTEMPT++))
done

if [ "${ATTEMPT}" -gt "${MAX_ATTEMPTS}" ]; then
    echo -e "${RED}FATAL ERROR: Timed out after 10 attempts waiting for Cloud Scheduler job '${JOB_NAME}' to become ready. Review error logs and try the setup again.${NC}"
    exit 1
fi

# ==========================================
# DATA CHECKS BEFORE CONTINUING TO ENSURE SCRIPT SUCCESS
# ==========================================
TABLE1_PREFIX="p_ads_CustomRecommendations_" #check table exists
TABLE2_ID="${PROJECT_ID}:${DATASET}.historical_fx_rates_${INSTANCE}" #check data exists
ATTEMPT=1
MAX_ATTEMPTS=30
SLEEP_TIME=60

echo -e "${GREEN}--- Waiting for ${TABLE1_ID} to exist and ${TABLE2_ID} to populate ---${NC}"

while [ "${ATTEMPT}" -le "${MAX_ATTEMPTS}" ]; do
  if bq ls "${PROJECT_ID}:${DATASET}" 2>/dev/null | grep -q "${TABLE1_PREFIX}"; then
    ROW_COUNT=$(bq show --format=json "${TABLE2_ID}" 2>/dev/null | jq -r '.numRows')

    if [[ "${ROW_COUNT}" =~ ^[0-9]+$ ]] && [ "${ROW_COUNT}" -gt 0 ]; then
      echo "Success! Table matching ${TABLE1_PREFIX}* exists and Table 2 contains ${ROW_COUNT} rows."
      break
    fi
  fi
  echo "Attempt ${ATTEMPT} of ${MAX_ATTEMPTS}: Tables not ready yet. Waiting ${SLEEP_TIME} seconds..."
  sleep "${SLEEP_TIME}"
  ((ATTEMPT++))
done

if [ "${ATTEMPT}" -gt "${MAX_ATTEMPTS}" ]; then
  echo "ERROR: Timed out waiting for the tables to be ready. Exiting script."
  exit 1
fi

# ==========================================
# COPY SQL QUERY TO SCHEDULE
# ==========================================
export PROJECT_ID="$PROJECT_ID"
export DATASET="$DATASET"
export FX_TABLE_NAME="$FX_TABLE_NAME"
SQL_QUERY=$(envsubst < "$SQL_FILE" | tr '\n' ' ' | sed 's/"/\\"/g' | sed 's/  */ /g')

echo -e "${GREEN}--- Scheduling SQL transformation for Dataset: $DATASET ---${NC}"

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

ATTEMPT=1
MAX_ATTEMPTS=20
SLEEP_TIME=20

echo -e "${GREEN}--- Waiting for dlg_recommendations_dashboard to exist ---${NC}"

while [ "${ATTEMPT}" -le "${MAX_ATTEMPTS}" ]; do
  if bq show "${PROJECT_ID}:${DATASET}.dlg_recommendations_dashboard" >/dev/null 2>&1; then
    echo "Success! Table exists."
    break
  fi

  echo "Attempt ${ATTEMPT} of ${MAX_ATTEMPTS}: Table not found yet. Waiting ${SLEEP_TIME} seconds..."
  sleep "${SLEEP_TIME}"
  ((ATTEMPT++))
done

if [ "${ATTEMPT}" -gt "${MAX_ATTEMPTS}" ]; then
  echo "ERROR: Timed out waiting for the table to be created. Review logs and try again."
  exit 1
fi

# ==========================================
# PROVIDE TEMPLATE LINK
# ==========================================
TEMPLATE_URL="https://datastudio.google.com/c/reporting/create?c.reportId=a92e51b5-7b7f-4f00-a0e7-6fdc8f3e22c8"
PARAMS="&ds.ds0.connector=bigQuery&ds.ds0.projectId=${PROJECT_ID}&ds.ds0.type=TABLE&ds.ds0.datasetId=${DATASET}&ds.ds0.tableId=dlg_recommendations_dashboard"

echo -e "${GREEN}=================================================="
echo "🎉 FINAL STEP: Create a copy of the dashboard!"
echo "=================================================="
echo -e "👉 Click here to make a copy and configure your dashboard:${NC}"
echo "${TEMPLATE_URL}&${PARAMS}"
echo -e "${GREEN}==================================================${NC}"
