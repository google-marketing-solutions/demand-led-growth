import argparse
import json
import hashlib
import re
import uuid
from tadau import Tadau

def format_customer_ids(customer_ids: str) -> str:
    """Format up to seven comma-separated customer IDs for Tadau."""
    formatted_ids = []

    for customer_id in customer_ids.split(","):
        customer_id = customer_id.strip()
        if re.fullmatch(r"[0-9]{10}", customer_id):
            customer_id = (
                f"{customer_id[:3]}-{customer_id[3:6]}-{customer_id[6:]}"
            )
        elif not re.fullmatch(r"[0-9]{3}-[0-9]{3}-[0-9]{4}", customer_id):
            continue

        formatted_ids.append(customer_id)
        if len(formatted_ids) == 7:
            break

    return ",".join(formatted_ids)


def main() -> None:
    """Tracks account processing using Tadau.
    """
    parser = argparse.ArgumentParser(description="Process Customer IDs.")
    parser.add_argument(
        "--customer_ids",
        help="Comma-separated customer IDs (first 7 used; 10-digit IDs are "
        "formatted as xxx-xxx-xxxx)",
    )
    parser.add_argument("--project_id", help="Project ID")
    
    args = parser.parse_args()
    project_id = args.project_id

    if args.customer_ids:
        args.customer_ids = format_customer_ids(args.customer_ids)

    tadau = Tadau(
        api_secret="S7toNnNZQPWzViq44q_8gg",
        measurement_id="G-Z2TKLQZ79K",
        opt_in=True,
        fixed_dimensions={
            "app": "Demand-Led Growth",
            "is_agent_event": False,
            "user_id": str(uuid.uuid4()),
            "non_personalized_ads": False
        }
    )
    event_id=hashlib.sha256(project_id.encode()).hexdigest()
    tadau.send_events([
        {
            "name": "SOLUTION_USAGE",
            "external_event_id": event_id,
            "th_google_ads_customer_id": args.customer_ids,
        }
    ])

if __name__ == "__main__":
    main()
