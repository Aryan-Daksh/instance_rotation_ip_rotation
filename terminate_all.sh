#!/bin/bash
set -euo pipefail

# --- Config ---
POOL_FILE="/tmp/spot_pool.json"
FALLBACK_ID="i-0e23cbcf08c4b1a34"
REGION="ap-south-1"

# --- Terminate all Spot instances in pool ---
if [ -s "$POOL_FILE" ]; then
    IDS=$(jq -r '.[].id' "$POOL_FILE" | xargs)
    if [ -n "$IDS" ]; then
        echo "[INFO] Terminating Spot instances: $IDS"
        aws ec2 terminate-instances --instance-ids $IDS --region $REGION >/dev/null
    fi
    # Empty the pool file
    echo "[]" > "$POOL_FILE"
else
    echo "[INFO] No pool file or empty pool, skipping Spot termination."
fi

# --- Stop fallback instance if running ---
STATE=$(aws ec2 describe-instances --instance-ids "$FALLBACK_ID" \
    --query 'Reservations[0].Instances[0].State.Name' \
    --output text --region $REGION 2>/dev/null || echo "not-found")

if [ "$STATE" == "running" ]; then
    echo "[INFO] Stopping fallback On-Demand $FALLBACK_ID"
    aws ec2 stop-instances --instance-ids "$FALLBACK_ID" --region $REGION >/dev/null
else
    echo "[INFO] Fallback instance is not running (state=$STATE)"
fi

