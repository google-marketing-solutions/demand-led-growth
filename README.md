# Demand Led Growth (DLG) - Enterprise V2

**Disclaimer: This is not an official Google product.**

---
### ⚠️ Version Selection Notice (Which version should you deploy?)

- **Enterprise (V2) THIS VERSION:** Upgraded specifically to support larger accounts and multi-MCC enterprise use cases (handling thousands of accounts and multi-currency aggregation). Requires Google Cloud Platform (GCP). [Github](https://github.com/google-marketing-solutions/demand-led-growth)
- **Light (V1):** Choose this if your customer prefers a lighter deployment without GCP requirements (runs via Apps Script). [Github](https://github.com/google-marketing-solutions/dlg-tool)

### 🚀 Key Benefits of the Enterprise (V2) option

1. **Enterprise Scaling:** Bypasses script limits by using BigQuery Connectors to process millions of rows daily across 1,000+ accounts.
2. **Multi-MCC Support:** Aggregates and filters data from multiple MCC IDs and individual accounts into a single dashboard.
3. **Multi-Currency Aggregation:** Automatically converts varying account currencies into a single reference currency using daily-refreshed exchange rates.
---

Demand Led Growth (DLG) is a scalable, self-hosted budget and target optimization tool for Google Ads. It replaces the previous [Sheets-based implementation of `dlg-tool`](https://github.com/google-marketing-solutions/dlg-tool), designed to meet the needs of large-scale advertisers and agencies.

## Overview

AI-powered bidding strategies require budget flexibility to perform optimally. When campaigns are "Limited by Budget" or "Limited by Target", they can miss valuable conversion opportunities. DLG helps you identify these constraints and estimates the potential uplift in conversions and conversion value if they are resolved.

By leveraging Google Cloud Platform (GCP), DLG can handle large data volumes across many accounts without the execution timeouts or storage limits associated with spreadsheet-based solutions.

## Key Features

*   **Scalability:** Built to handle data from hundreds of Google Ads accounts and millions of rows of performance data.
*   **Multi-MCC & Multi-Account Support:** Aggregate and filter your data across multiple MCC IDs and individual accounts within a single dashboard.
*   **Multi-Currency Aggregation:** Automatically convert and aggregate financial metrics (spend, potential cost increase) from different currencies into a single reference currency of your choice, using exchange rates in BigQuery.
*   **Actionable Visualizations:** A Data Studio dashboard featuring:
    *   "Limited by Budget" campaigns with estimated weekly uplift (conversions, conversion value).
    *   Spend vs. Budget comparison.
    *   Budget reallocation opportunities (moving unused budget to constrained campaigns).
    *   Target CPA/ROAS adjustment recommendations.

## Architecture

The solution runs entirely within your own Google Cloud Platform (GCP) project, ensuring you maintain full control and ownership of your data:

1.  **Data Ingestion:** BigQuery Data Transfer Service (BQDT) for Google Ads automatically imports your daily reports.
2.  **Storage & Processing:** BigQuery stores the data and runs SQL views to aggregate and process it (including currency conversion).
3.  **Visualization:** Data Studio connects directly to your BigQuery views to display the interactive dashboard.


## Prerequisites

Before deploying the solution, ensure you have:

1.  **A Google Cloud Project** with billing enabled. The user deploying the solution should have **Owner** (`roles/owner`) permissions on this project.
2.  **Google Ads Access:** The Google account running the deployment must have at least **Standard** access to the Google Ads MCC or individual accounts you want to analyze.
3.  **Data Studio Template Access:** Request access to the dashboard template by joining the [demand-led-growth-template-readers](https://groups.google.com/g/demand-led-growth-template-readers) Google Group. **You must be a member of this group to copy the dashboard.**

## Deployment

We recommend deploying the solution using **Google Cloud Shell**.

1.  Open the [Google Cloud Console](https://console.cloud.google.com/) and select your target project.
2.  Activate **Cloud Shell** by clicking the terminal icon in the top-right toolbar.
3.  In the Cloud Shell terminal, run the following command:
     ```bash
    gcloud auth login
    ```
    Then following the link, sign in and copy the code to the terminal to finish this process. This is what will provide your GCP project with access to the Google Ads account data.

4.  In the Cloud Shell terminal, run the following commands:

    ```bash
    git clone https://github.com/google-marketing-solutions/demand-led-growth.git
    cd demand-led-growth
    chmod +x install.sh
    ./install.sh
    ```

5.  The interactive script will guide you through the setup:
    *   Selecting your deployment location, your global currency and providing the MCC/Customer IDs you wish to add to your dashboard.
    *   The script will then automatically:
        1. Enable the required APIs.
        2. Configuring the Google Ads BigQuery Data Transfer Service.
        3. Create a scheduled fetch of the latest exchange rates.
        4. Create the SQL views that process the data.
        5. Schedule everything to run daily.
        
6.  Upon successful completion, the script will output a customized **Data Studio Linking API URL**.
7.  Open the link in your browser. Data Studio will open with the data sources already mapped to your BigQuery project. Click **Create Report** (or **Save**) in the top right to save the dashboard to your own account.

> [!NOTE]
> The initial BigQuery Data Transfer might take up to 24 hours to populate. Your Data Studio dashboard may display configuration or missing table errors until the first data transfer completes.

## Frequently Asked Questions (FAQ)

### General

#### Q: What is the difference between dlg-tool (aka v1) and DLG (aka v2)?
**A:** Dlg-tool (available in the [dlg-tool repository](https://github.com/google-marketing-solutions/dlg-tool)) was a Google Sheets-based solution powered by Google Ads Scripts. It was easy to set up but faced scalability limits (e.g., the 30-minute script execution limit and Sheet cell limits) when handling large accounts or multiple MCCs. 

Demand Led Growth (v2) is a **GCP-based, self-hosted solution**. By moving the data pipeline to BigQuery and using the BigQuery Data Transfer Service (BQDT), it can scale to handle hundreds of accounts and millions of rows of data without timeouts.

#### Q: Does this tool make changes to my Google Ads campaigns?
**A:** **No.** DLG is a reporting-only tool. It identifies budget and target constraints and estimates potential uplifts, but it does not make any changes to your Google Ads settings.

#### Q: How is my data protected?
**A:** Because DLG v2 is **self-hosted**, all your Google Ads data is ingested, stored, and processed within your own Google Cloud Platform (GCP) project. You retain full ownership and control over your data and access permissions via GCP IAM.

---

### Cost & Performance

#### Q: How much does it cost to run DLG v2 on GCP?
**A:** DLG v2 runs entirely within your own GCP project. While you may be billed for Google Cloud services (specifically BigQuery storage and query usage), the data volume for most advertisers is small enough that **costs often fall within the GCP Free Tier** (which includes 10 GB of free storage and 1 TB of free query data processing per month). 

For more details, see the [GCP Free Tier limits](https://cloud.google.com/free).

#### Q: Can I customize the Data Studio dashboard?
**A:** **Yes.** Once you copy the Data Studio template and connect it to your BigQuery views, you have full edit rights to customize the visualizations, add new charts, or change the branding.

---

### Features

#### Q: How does multi-currency support work?
**A:** DLG v2 automatically handles campaigns running in different currencies. During the BigQuery setup, you can define a single reference currency. The SQL views will automatically convert all cost and spend metrics into this reference currency using daily exchange rates.

---

## Troubleshooting

### Data Ingestion (BigQuery Data Transfer Service)

#### Issue: BQDT transfer fails or shows "Permission Denied"
*   **Cause:** The user who configured the BQDT transfer does not have sufficient permissions.
*   **Resolution:** Ensure the configuring user has:
    1.  `Admin` or `Standard` access to the target Google Ads MCC or accounts.
    2.  `BigQuery Admin` and `BigQuery Data Transfer Service Admin` roles in the GCP project.

#### Issue: The transfer completed, but BigQuery tables are empty
*   **Cause:** It can take some time for the initial backfill to complete, or the selected Google Ads accounts may not have had active campaigns during the backfill period.
*   **Resolution:** Check the BQDT run history in the GCP Console to ensure the run succeeded. You can also trigger a manual backfill for a specific date range if needed.

---

### Dashboard (Data Studio)

#### Issue: Dashboard shows "Data Set Configuration Error" or "System Error"
*   **Cause:** Data Studio cannot access the underlying BigQuery views, or the views were not created correctly.
*   **Resolution:**
    1.  Verify that the BigQuery tables (e.g., `dlg_recommendations_dashboard`) exist in your BigQuery dataset.
    2.  Ensure the credentials used in the Data Studio data source have at least `BigQuery Data Viewer` and `BigQuery Job User` roles on the GCP project.
    3.  Try editing the data source in Data Studio and clicking **Reconnect**.

#### Issue: Dashboard data seems outdated compared to the Google Ads UI
*   **Cause:** BQDT updates data once per day. There may be up to a 24-hour lag. Additionally, conversion data in Google Ads can be subject to conversion delay.
*   **Resolution:** Check the "Last Updated" timestamp in your BQDT run history. Expect minor discrepancies between the dashboard and the live UI due to this daily refresh cycle.

#### Issue: Dashboard pages are slow to load
*   **Cause:** Data Studio might be querying raw BQDT tables instead of the optimized SQL views.
*   **Resolution:** Ensure that your Data Studio report is connected to the **SQL Views** provided in the deployment package, and not directly to the raw tables (which start with `p_`).


## Contributing

Please see [CONTRIBUTING.md](CONTRIBUTING.md) for details on how to contribute to this project.

## License

This project is licensed under the Apache 2.0 License - see the [LICENSE](LICENSE) file for details.
