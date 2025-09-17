#!/bin/bash
set -euo pipefail

# --- Config ---
POOL_FILE="/tmp/spot_pool.json"
LT_ID="lt-0483cb4e15796b9bf"         # Spot Launch Template
LT_VERSION=5
FALLBACK_IDS=("i-0e23cbcf08c4b1a34" "i-0abcdef1234567890") # Array of on-demand fallbacks
REGION="ap-south-1"                  # Force region

ACTION="${1:-start}"   # default action is start

case "$ACTION" in
  start)
    INSTANCE_ID=$(jq -r '.[0].id // empty' "$POOL_FILE" 2>/dev/null || echo "")
    IP=$(jq -r '.[0].ip // empty' "$POOL_FILE" 2>/dev/null || echo "")

    if [ -n "$INSTANCE_ID" ] && [ "$INSTANCE_ID" != "null" ]; then
        >&2 echo "[INFO] $(date '+%T') Using instance $INSTANCE_ID ($IP)"
        echo "$IP"

        echo "$INSTANCE_ID" > /tmp/current_instance_id
        echo "$(jq -r '.[0].type' "$POOL_FILE")" > /tmp/current_instance_type

        # Remove from pool
        jq '.[1:]' "$POOL_FILE" > "$POOL_FILE.tmp" && mv "$POOL_FILE.tmp" "$POOL_FILE"

        # Refill pool in background
        (
            SPOT_JSON=$(aws ec2 run-instances \
                --launch-template LaunchTemplateId=$LT_ID,Version=$LT_VERSION \
                --instance-market-options "MarketType=spot" \
                --count 1 --region $REGION 2>/dev/null || true)

            NEW_ID=$(echo "$SPOT_JSON" | jq -r '.Instances[0].InstanceId')
            if [ -n "$NEW_ID" ] && [ "$NEW_ID" != "null" ]; then
                aws ec2 wait instance-running --instance-ids "$NEW_ID" --region $REGION
                NEW_IP=$(aws ec2 describe-instances --instance-ids "$NEW_ID" \
                    --query 'Reservations[0].Instances[0].PublicIpAddress' \
                    --output text --region $REGION)
                jq ". + [{\"id\":\"$NEW_ID\", \"ip\":\"$NEW_IP\", \"type\":\"spot\"}]" "$POOL_FILE" > "$POOL_FILE.tmp" \
                    && mv "$POOL_FILE.tmp" "$POOL_FILE"
                >&2 echo "[INFO]  $(date '+%T') Refilled Spot $NEW_ID ($NEW_IP)"
            else
                >&2 echo "[WARN] Spot refill failed, starting fallback..."
                for FB_ID in "${FALLBACK_IDS[@]}"; do
                    STATE=$(aws ec2 describe-instances --instance-ids "$FB_ID" \
                        --query 'Reservations[0].Instances[0].State.Name' --output text --region $REGION 2>/dev/null || echo "stopped")
                    if [ "$STATE" != "running" ]; then
                        aws ec2 start-instances --instance-ids "$FB_ID" --region $REGION >/dev/null
                        aws ec2 wait instance-running --instance-ids "$FB_ID" --region $REGION
                    fi
                    NEW_IP=$(aws ec2 describe-instances --instance-ids "$FB_ID" \
                        --query 'Reservations[0].Instances[0].PublicIpAddress' --output text --region $REGION)
                    jq ". + [{\"id\":\"$FB_ID\", \"ip\":\"$NEW_IP\", \"type\":\"fallback\"}]" "$POOL_FILE" > "$POOL_FILE.tmp" \
                        && mv "$POOL_FILE.tmp" "$POOL_FILE"
                    >&2 echo "[INFO] Added Fallback $FB_ID ($NEW_IP) to pool"
                done
            fi
        ) &
        exit 0
    fi

    >&2 echo "[ERROR] No pool entries available yet. Try again soon."
    exit 1
    ;;

  stop)
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

        rm -f /tmp/current_instance_id /tmp/current_instance_type
    else
        >&2 echo "[WARN] No active instance found to stop."
    fi
    ;;

  *)
    echo "Usage: $0 {start|stop}" >&2
    exit 1
    ;;
esac

