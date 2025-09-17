#!/bin/bash
set -euo pipefail

# === Config ===
POOL_FILE="/tmp/spot_pool.json"
LT_ID="lt-0483cb4e15796b9bf"          # Spot Launch Template ID
LT_VERSION=5
POOL_SIZE=5
REGION="ap-south-1"

echo "[]" > "$POOL_FILE"

for i in $(seq 1 $POOL_SIZE); do
  echo "[INFO] Launching Spot $i/$POOL_SIZE..."
  
  SPOT_JSON=$(aws ec2 run-instances \
      --launch-template LaunchTemplateId=$LT_ID,Version=$LT_VERSION \
      --instance-market-options "MarketType=spot" \
      --count 1 --region $REGION)

  INSTANCE_ID=$(echo "$SPOT_JSON" | jq -r '.Instances[0].InstanceId')
  aws ec2 wait instance-running --instance-ids "$INSTANCE_ID" --region $REGION

  IP=$(aws ec2 describe-instances --instance-ids "$INSTANCE_ID" \
      --query 'Reservations[0].Instances[0].PublicIpAddress' --output text --region $REGION)

  # Add to pool
jq ". + [{\"id\":\"$INSTANCE_ID\", \"ip\":\"$IP\", \"type\":\"spot\"}]" "$POOL_FILE" > "$POOL_FILE.tmp" \
    && mv "$POOL_FILE.tmp" "$POOL_FILE"
done

echo "[INFO] Pool initialized with $POOL_SIZE Spot instances in $REGION."

