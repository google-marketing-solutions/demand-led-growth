import argparse
import json
import hashlib
from tadau import Tadau


def main() -> None:
    """Tracks account processing using Tadau.
    """
    parser = argparse.ArgumentParser(description="Process Customer IDs.")
    parser.add_argument("--customer_ids", help="Comma-separated list of customer IDs")
    parser.add_argument("--project_id", help="Project ID")
    
    args = parser.parse_args()
    project_id = args.project_id

    tadau = Tadau(
        api_secret="S7toNnNZQPWzViq44q_8gg",
        measurement_id="G-Z2TKLQZ79K",
        opt_in=True,
        fixed_dimensions={
            "app": "test_solution",
            "is_agent_event": False,
            "user_id": "3f8a9c2b-7e1d-4b0a-9f5c-8d3e2b1a0f9d",
            "non_personalized_ads": False
        }
    )
    event_id=hashlib.sha256(project_id.encode()).hexdigest()
    tadau.send_events([
        {
            "name": "DEPLOYMENT",
            "external_event_id": event_id,
            "th_google_ads_customer_id": args.customer_ids,
        }
    ])

if __name__ == "__main__":
    main()