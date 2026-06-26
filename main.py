import requests
from google.cloud import bigquery
from datetime import datetime, timedelta
import os


def fetch_and_load_fx(request):
    table_id = os.environ.get("FX_TARGET_TABLE")
    target_currency = os.environ.get("TARGET_CURRENCY")

    if not table_id:
        raise ValueError("The FX_TARGET_TABLE environment variable is not set!")

    client = bigquery.Client()
    # 1. Calculate lookback window
    try:
        check_query = f"SELECT COUNT(*) as row_count FROM `{table_id}`"
        query_job = client.query(check_query)
        result = query_job.result()
        row_count = next(result).get("row_count", 0)
    except Exception as check_error:
        print(f"Warning: Could not check table count ({check_error}). Defaulting to 3 days.")
        row_count = 1

    if row_count == 0:
        lookback_days = 30
        print("🎉 Table is EMPTY! Commencing automated 30-day historical backfill...")
    else:
        lookback_days = 3
        print(f"ℹ️ Table contains {row_count} rows. Proceeding with standard 3-day window.")

    start_date = (datetime.utcnow() - timedelta(days=lookback_days)).strftime('%Y-%m-%d')
    
    # EXACT ENDPOINT: Fetches all global currencies relative to currency baseline
    url = f"https://api.frankfurter.dev/v2/rates?base={target_currency}&from={start_date}"
    
    try:
        response = requests.get(url, timeout=10)
        response.raise_for_status()
        data = response.json()
    except Exception as e:
        return f"Error fetching from Frankfurter v2: {e}", 500

    rows_to_insert = []
    
    # 2. Iterate directly over the flat list array objects exactly as you pasted them
    for item in data:
        date_str = item.get("date")
        local_currency = item.get("quote")
        rate_val = item.get("rate")
        
        if rate_val:
            rows_to_insert.append({
                "date": date_str,
                "base_currency": local_currency,
                "target_currency": target_currency,
                "rate": float(rate_val)
            })

    # Append a 1.0 multiplier baseline for 1-to-1 rows across the distinct dates found
    distinct_dates = set([r["date"] for r in rows_to_insert])
    for d in distinct_dates:
        rows_to_insert.append({
            "date": d,
            "base_currency": target_currency,
            "target_currency": target_currency,
            "rate": 1.0
        })

    if not rows_to_insert:
        return "No rows parsed from the API.", 200

    # 3. Stream data and clean up using a TRUE single MERGE query (Array-Constructed)
    # Natively convert the Python dictionaries into explicit BigQuery STRUCT syntax rows
    struct_rows = []
    for row in rows_to_insert:
        struct_expr = f"STRUCT(DATE('{row['date']}') as date, '{row['base_currency']}' as base_currency, '{row['target_currency']}' as target_currency, {row['rate']} as rate)"
        struct_rows.append(struct_expr)
    
    # Combine into a single in-memory array representation string
    array_data_string = "[\n      " + ",\n      ".join(struct_rows) + "\n    ]"

    # TRUE SINGLE QUERY: Reads virtual rows, updates duplicates, and purges old records in one pass
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
        # Executes the single database transaction pass cleanly with zero configuration parameters
        query_job = client.query(single_merge_query)
        query_job.result()  
        return "Success", 200

    except Exception as bq_error:
        print(f"CRITICAL PIPELINE FAILURE: {bq_error}")
        return f"BigQuery Single Query Pipeline Error: {bq_error}", 500
