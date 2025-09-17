#!/bin/bash
set -euo pipefail

# --- Config ---
POOL_FILE="/tmp/spot_pool.json"
LT_ID="lt-0483cb4e15796b9bf"         # Spot Launch Template
LT_VERSION=5
FALLBACK_IDS=("i-0e23cbcf08c4b1a34" "i-0abcdef1234567890") # Array of on-demand fallbacks
REGION="ap-south-1"                  # AWS Region
SCRAPE_WINDOW="${SCRAPE_WINDOW:-60}" # Seconds, optional env variable

ACTION="${1:-start}"   # default action is start

# --- Helper to remove stale entries ---
cleanup_stale() {
    jq '[.[] | select(.ip != null)]' "$POOL_FILE" > "$POOL_FILE.tmp" && mv "$POOL_FILE.tmp" "$POOL_FILE"
}

# --- Start logic ---
if [ "$ACTION" == "start" ]; then

    cleanup_stale 2>/dev/null || true

    # Loop pool to find first usable IP
    while true; do
        INSTANCE_ID=$(jq -r '.[0].id // empty' "$POOL_FILE" 2>/dev/null || echo "")
        IP=$(jq -r '.[0].ip // empty' "$POOL_FILE" 2>/dev/null || echo "")
        TYPE=$(jq -r '.[0].type // "spot"' "$POOL_FILE" 2>/dev/null || echo "spot")

        if [ -n "$INSTANCE_ID" ] && [ -n "$IP" ] && [ "$IP" != "null" ]; then
            >&2 echo "[INFO] $(date '+%T') Using instance $INSTANCE_ID ($IP)"
            echo "$IP"

            # Save for stop command
            echo "$INSTANCE_ID" > /tmp/current_instance_id
            echo "$TYPE" > /tmp/current_instance_type

            # Remove from pool
            jq '.[1:]' "$POOL_FILE" > "$POOL_FILE.tmp" && mv "$POOL_FILE.tmp" "$POOL_FILE"

            # Refill pool asynchronously
            (
                # Try spot instance first
                SPOT_JSON=$(aws ec2 run-instances \
                    --launch-template LaunchTemplateId=$LT_ID,Version=$LT_VERSION \
                    --instance-market-options "MarketType=spot" \
                    --count 1 --region $REGION 2>/dev/null || true)

                NEW_ID=$(echo "$SPOT_JSON" | jq -r '.Instances[0].InstanceId')
                if [ -n "$NEW_ID" ] && [ "$NEW_ID" != "null" ]; then
                    # Add as pending (IP=null)
                    jq ". + [{\"id\":\"$NEW_ID\", \"ip\":null, \"type\":\"spot\"}]" "$POOL_FILE" > "$POOL_FILE.tmp" \
                        && mv "$POOL_FILE.tmp" "$POOL_FILE"
                    >&2 echo "[INFO] Spot $NEW_ID added to pool (pending IP)"

                    # Wait for instance running, then fetch IP
                    aws ec2 wait instance-running --instance-ids "$NEW_ID" --region $REGION
                    NEW_IP=$(aws ec2 describe-instances --instance-ids "$NEW_ID" \
                        --query 'Reservations[0].Instances[0].PublicIpAddress' --output text --region $REGION)
                    jq "map(if .id==\"$NEW_ID\" then .ip=\"$NEW_IP\" else . end)" "$POOL_FILE" > "$POOL_FILE.tmp" \
                        && mv "$POOL_FILE.tmp" "$POOL_FILE"
                    >&2 echo "[INFO] Spot $NEW_ID is ready ($NEW_IP)"
                else
                    >&2 echo "[WARN] Spot refill failed. Launching fallback instances..."
                    # Try failover instances
                    for FB_ID in "${FALLBACK_IDS[@]}"; do
                        STATE=$(aws ec2 describe-instances --instance-ids "$FB_ID" \
                            --query 'Reservations[0].Instances[0].State.Name' --output text --region $REGION 2>/dev/null || echo "stopped")
                        if [ "$STATE" != "running" ]; then
                            aws ec2 start-instances --instance-ids "$FB_ID" --region $REGION >/dev/null
                        fi
                        # Add to pool as pending
                        jq ". + [{\"id\":\"$FB_ID\", \"ip\":null, \"type\":\"fallback\"}]" "$POOL_FILE" > "$POOL_FILE.tmp" \
                            && mv "$POOL_FILE.tmp" "$POOL_FILE"
                        >&2 echo "[INFO] Failover $FB_ID added to pool (pending IP)"
                    done
                fi
            ) &

            exit 0
        fi

        # No usable IP found in pool
        >&2 echo "[INFO] No ready instance found in pool yet. Waiting 2s..."
        sleep 2
    done
fi

# --- Stop logic ---
if [ "$ACTION" == "stop" ]; then
    if [ -f /tmp/current_instance_id ]; then
        INSTANCE_ID=$(cat /tmp/current_instance_id)
        TYPE=$(cat /tmp/current_instance_type)

        if [ "$TYPE" == "spot" ]; then
            >&2 echo "[INFO] Terminating Spot $INSTANCE_ID"
            aws ec2 terminate-instances --instance-ids "$INSTANCE_ID" --region $REGION >/dev/null
        else
            >&2 echo "[INFO] Stopping On-Demand $INSTANCE_ID"
            aws ec2 stop-instances --instance-ids "$INSTANCE_ID" --region $REGION >/dev/null
        fi

        # Remove stale entry from pool if exists
        jq "map(select(.id!=\"$INSTANCE_ID\"))" "$POOL_FILE" > "$POOL_FILE.tmp" && mv "$POOL_FILE.tmp" "$POOL_FILE"

        rm -f /tmp/current_instance_id /tmp/current_instance_type
    else
        >&2 echo "[WARN] No active instance found to stop."
    fi
    exit 0
fi

echo "Usage: $0 {start|stop}" >&2
exit 1

