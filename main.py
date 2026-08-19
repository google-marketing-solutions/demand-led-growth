from datetime import datetime, timedelta
import os
from google.cloud import bigquery
import requests


def fetch_and_load_fx(request):
  table_id = os.environ.get("FX_TARGET_TABLE")
  target_currency = os.environ.get("TARGET_CURRENCY")

  if not table_id:
    raise ValueError("The FX_TARGET_TABLE environment variable is not set!")
  if not target_currency:
    raise ValueError("The TARGET_CURRENCY environment variable is not set!")

  client = bigquery.Client()

  # 1. Calculate lookback window based on table state
  try:
    check_query = f"SELECT COUNT(*) as row_count FROM `{table_id}`"
    query_job = client.query(check_query)
    result = query_job.result()
    row_count = next(result).get("row_count", 0)
  except Exception as check_error:
    print(
        f"Warning: Could not check table count ({check_error}). Defaulting to 3"
        " days."
    )
    row_count = 1

  if row_count == 0:
    lookback_days = 30
    print("🎉 Table is EMPTY! Commencing automated 30-day historical backfill...")
  else:
    lookback_days = 3
    print(
        f"ℹ️ Table contains {row_count} rows. Proceeding with standard 3-day"
        " window."
    )

  start_date = (datetime.utcnow() - timedelta(days=lookback_days)).strftime(
      "%Y-%m-%d"
  )

  # Fetch all rates relative to base currency
  url = f"https://api.frankfurter.dev/v2/rates?base={target_currency}&from={start_date}"

  try:
    response = requests.get(url, timeout=15)
    response.raise_for_status()
    data = response.json()
  except Exception as e:
    return f"Error fetching from Frankfurter v2: {e}", 500

  # 2. Store rows in a dict keyed by (date, base_currency) to prevent duplicate merge keys
  rates_by_key = {}

  for item in data:
    date_str = item.get("date")
    local_currency = item.get("quote")
    rate_val = item.get("rate")

    if date_str and local_currency and rate_val is not None:
      rates_by_key[(date_str, local_currency)] = {
          "date": date_str,
          "base_currency": local_currency,
          "target_currency": target_currency,
          "rate": float(rate_val),
      }

  # Append/overwrite baseline (1.0) for every distinct date returned
  distinct_dates = {k[0] for k in rates_by_key.keys()}
  for d in distinct_dates:
    rates_by_key[(d, target_currency)] = {
        "date": d,
        "base_currency": target_currency,
        "target_currency": target_currency,
        "rate": 1.0,
    }

  rows_to_insert = list(rates_by_key.values())

  if not rows_to_insert:
    return "No rows parsed from the API.", 200

  # 3. Construct BigQuery STRUCT array
  struct_rows = [
      f"STRUCT(DATE('{r['date']}') as date, '{r['base_currency']}' as"
      f" base_currency, '{r['target_currency']}' as target_currency,"
      f" {r['rate']} as rate)"
      for r in rows_to_insert
  ]

  array_data_string = "[\n      " + ",\n      ".join(struct_rows) + "\n    ]"

  # Atomic merge: updates existing rows, inserts new rows, and purges records older than 30 days
  single_merge_query = f"""
    MERGE `{table_id}` T
    USING (
      SELECT r.date, r.base_currency, r.target_currency, r.rate
      FROM UNNEST({array_data_string}) r
    ) S
    ON T.date = S.date AND T.base_currency = S.base_currency
    WHEN MATCHED THEN
      UPDATE SET rate = S.rate
    WHEN NOT MATCHED THEN
      INSERT (date, base_currency, target_currency, rate)
      VALUES (S.date, S.base_currency, S.target_currency, S.rate)
    WHEN NOT MATCHED BY SOURCE AND T.date < DATE_SUB(CURRENT_DATE(), INTERVAL 30 DAY) THEN
      DELETE;
    """

  try:
    query_job = client.query(single_merge_query)
    query_job.result()
    return "Success", 200

  except Exception as bq_error:
    print(f"CRITICAL PIPELINE FAILURE: {bq_error}")
    return f"BigQuery Single Query Pipeline Error: {bq_error}", 500
