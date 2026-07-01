# Demand Led Growth (DLG)

**Disclaimer: This is not an official Google product.**

Demand Led Growth (DLG) is a scalable, self-hosted budget and target optimization tool for Google Ads. It replaces the previous [Sheets-based implementation of `dlg-tool`](https://github.com/google-marketing-solutions/dlg-tool), designed to meet the needs of large-scale advertisers and agencies.

## Overview

AI-powered bidding strategies require budget flexibility to perform optimally. When campaigns are "Limited by Budget" or "Limited by Target", they can miss valuable conversion opportunities. DLG helps you identify these constraints and estimates the potential uplift in conversions and conversion value if they are resolved.

By leveraging Google Cloud Platform (GCP), DLG can handle large data volumes across many accounts without the execution timeouts or storage limits associated with spreadsheet-based solutions.

## Key Features

*   **Scalability:** Built to handle data from hundreds of Google Ads accounts and millions of rows of performance data.
*   **Multi-MCC & Multi-Account Support:** Aggregate and filter your data across multiple MCC IDs and individual accounts within a single dashboard.
*   **Multi-Currency Aggregation:** Automatically convert and aggregate financial metrics (spend, potential cost increase) from different currencies into a single reference currency of your choice, using exchange rates in BigQuery.
*   **Actionable Visualizations:** A Looker Studio dashboard featuring:
    *   "Limited by Budget" campaigns with estimated weekly uplift (conversions, conversion value).
    *   Spend vs. Budget comparison.
    *   Budget reallocation opportunities (moving unused budget to constrained campaigns).
    *   Target CPA/ROAS adjustment recommendations.

## Architecture

The solution runs entirely within your own Google Cloud Platform (GCP) project, ensuring you maintain full control and ownership of your data:

1.  **Data Ingestion:** BigQuery Data Transfer Service (BQDT) for Google Ads automatically imports your daily reports.
2.  **Storage & Processing:** BigQuery stores the data and runs SQL views to aggregate and process it (including currency conversion).
3.  **Visualization:** Looker Studio connects directly to your BigQuery views to display the interactive dashboard.


## Prerequisites

Before deploying the solution, ensure you have:

1.  **A Google Cloud Project** with billing enabled. The user deploying the solution should have **Owner** (`roles/owner`) permissions on this project.
2.  **Google Ads Access:** The Google account running the deployment must have at least **Standard** access to the Google Ads MCC or individual accounts you want to analyze.
3.  **Looker Studio Template Access:** Request access to the dashboard template by joining the [demand-led-growth-template-readers](https://groups.google.com/g/demand-led-growth-template-readers) Google Group. **You must be a member of this group to copy the dashboard.**

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
        
6.  Upon successful completion, the script will output a customized **Looker Studio Linking API URL**.
7.  Open the link in your browser. Looker Studio will open with the data sources already mapped to your BigQuery project. Click **Create Report** (or **Save**) in the top right to save the dashboard to your own account.

> [!NOTE]
> The initial BigQuery Data Transfer might take up to 24 hours to populate. Your Looker Studio dashboard may display configuration or missing table errors until the first data transfer completes.

## Contributing

Please see [CONTRIBUTING.md](CONTRIBUTING.md) for details on how to contribute to this project.

## License

This project is licensed under the Apache 2.0 License - see the [LICENSE](LICENSE) file for details.
