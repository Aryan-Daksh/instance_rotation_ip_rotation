#!/bin/bash
set -euo pipefail

# --- Config ---
POOL_FILE="/tmp/spot_pool.json"
REGION="ap-south-1"

if [ ! -f "$POOL_FILE" ] || [ ! -s "$POOL_FILE" ]; then
    echo "[INFO] Pool file empty or not found. Nothing to terminate."
    exit 0
fi

# --- Terminate Spot instances ---
SPOT_IDS=$(jq -r '.[] | select(.type=="spot") | .id' "$POOL_FILE" | xargs)
if [ -n "$SPOT_IDS" ]; then
    echo "[INFO] Terminating Spot instances: $SPOT_IDS"
    aws ec2 terminate-instances --instance-ids $SPOT_IDS --region $REGION >/dev/null
else
    echo "[INFO] No Spot instances to terminate."
fi

# --- Stop Fallback instances ---
FALLBACK_IDS=$(jq -r '.[] | select(.type=="fallback") | .id' "$POOL_FILE" | xargs)
for FB_ID in $FALLBACK_IDS; do
    STATE=$(aws ec2 describe-instances --instance-ids "$FB_ID" \
        --query 'Reservations[0].Instances[0].State.Name' \
        --output text --region $REGION 2>/dev/null || echo "stopped")
    if [ "$STATE" == "running" ]; then
        echo "[INFO] Stopping fallback instance $FB_ID"
        aws ec2 stop-instances --instance-ids "$FB_ID" --region $REGION >/dev/null
    else
        echo "[INFO] Fallback instance $FB_ID is already stopped (state=$STATE)"
    fi
done

# --- Clear the pool file ---
echo "[]" > "$POOL_FILE"
echo "[INFO] Pool cleared."

