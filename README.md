# Demand Led Growth (DLG)

**Disclaimer: This is not an official Google product.**

Demand Led Growth (DLG) is a scalable, self-hosted budget and target optimization tool for Google Ads. It replaces the previous Sheets-based implementation, designed to meet the needs of large-scale advertisers and agencies.

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

## Getting Started

Detailed deployment instructions will be provided in `DEPLOYMENT.md` (coming soon). The general setup steps involve:

1.  Setting up a GCP project with billing enabled.
2.  Configuring the BigQuery Data Transfer for your Google Ads account(s).
3.  Deploying the BigQuery datasets and SQL views.
4.  Copying the Looker Studio dashboard template and connecting it to your BigQuery views.

## Contributing

Please see [CONTRIBUTING.md](CONTRIBUTING.md) for details on how to contribute to this project.

## License

This project is licensed under the Apache 2.0 License - see the [LICENSE](LICENSE) file for details.
