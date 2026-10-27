#!/usr/bin/env bash
# ==============================================================================
# CourseCompass - EC2 Lifecycle & Management CLI
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/.ec2_instance_info.env"

if [[ ! -f "$ENV_FILE" ]]; then
  echo "Error: ${ENV_FILE} not found. Please launch the instance first via ./launch_instance.sh"
  exit 1
fi

source "$ENV_FILE"

ACTION="${1:-status}"

get_ip() {
  aws ec2 describe-instances \
    --region "${REGION}" \
    --instance-ids "${INSTANCE_ID}" \
    --query 'Reservations[0].Instances[0].PublicIpAddress' \
    --output text 2>/dev/null || echo "Unknown"
}

case "$ACTION" in
  status)
    STATE=$(aws ec2 describe-instances \
      --region "${REGION}" \
      --instance-ids "${INSTANCE_ID}" \
      --query 'Reservations[0].Instances[0].State.Name' \
      --output text 2>/dev/null || echo "Unknown")
    CURRENT_IP=$(get_ip)
    
    echo "=================================================================="
    echo "  📊 CourseCompass EC2 Status"
    echo "=================================================================="
    echo "  Instance ID:   ${INSTANCE_ID}"
    echo "  State:         ${STATE}"
    echo "  Region:        ${REGION}"
    echo "  Instance Type: ${INSTANCE_TYPE}"
    echo "  Public IP:     ${CURRENT_IP}"
    
    if [[ "$STATE" == "running" ]]; then
      echo ""
      echo "Checking bootstrap & tunnel status..."
      BOOTSTRAP=$(ssh -i "$KEY_FILE" -o StrictHostKeyChecking=no -o ConnectTimeout=5 ubuntu@"$CURRENT_IP" \
        "if [[ -f /home/ubuntu/BOOTSTRAP_COMPLETE ]]; then echo 'Completed'; else echo 'In Progress'; fi" 2>/dev/null || echo "Connecting...")
      echo "  Bootstrap:     ${BOOTSTRAP}"
      
      TUNNEL=$(ssh -i "$KEY_FILE" -o StrictHostKeyChecking=no -o ConnectTimeout=5 ubuntu@"$CURRENT_IP" \
        "cat /home/ubuntu/TUNNEL_URL.txt 2>/dev/null || grep -o 'https://[-a-zA-Z0-9.]*\.trycloudflare\.com' /var/log/cloudflared.log 2>/dev/null | tail -n 1" 2>/dev/null || echo "N/A")
      echo "  Public URL:    ${TUNNEL}"
    fi
    echo "=================================================================="
    ;;

  url)
    CURRENT_IP=$(get_ip)
    echo "Querying live tunnel URL from instance..."
    TUNNEL=$(ssh -i "$KEY_FILE" -o StrictHostKeyChecking=no -o ConnectTimeout=5 ubuntu@"$CURRENT_IP" \
      "cat /home/ubuntu/TUNNEL_URL.txt 2>/dev/null || grep -o 'https://[-a-zA-Z0-9.]*\.trycloudflare\.com' /var/log/cloudflared.log 2>/dev/null | tail -n 1" 2>/dev/null || true)
    
    if [[ -n "$TUNNEL" ]]; then
      echo ""
      echo "  📱 LIVE HTTPS URL: ${TUNNEL}"
      echo ""
    else
      echo "Tunnel URL not ready yet. Bootstrap may still be running. Run: ./manage_ec2.sh logs"
    fi
    ;;

  ssh)
    CURRENT_IP=$(get_ip)
    echo "Connecting to ubuntu@${CURRENT_IP}..."
    ssh -i "$KEY_FILE" -o StrictHostKeyChecking=no ubuntu@"${CURRENT_IP}"
    ;;

  logs)
    CURRENT_IP=$(get_ip)
    echo "Streaming bootstrap / app logs..."
    ssh -i "$KEY_FILE" -o StrictHostKeyChecking=no ubuntu@"${CURRENT_IP}" \
      "if [[ -f /var/log/app_bootstrap.log ]]; then tail -f /var/log/app_bootstrap.log; else journalctl -u coursecompass-app.service -f; fi"
    ;;

  restart-backend)
    CURRENT_IP=$(get_ip)
    echo "Restarting CourseCompass backend service..."
    ssh -i "$KEY_FILE" -o StrictHostKeyChecking=no ubuntu@"${CURRENT_IP}" \
      "sudo systemctl restart coursecompass-app.service && sudo systemctl status coursecompass-app.service --no-pager"
    echo "✓ Backend restarted. Public tunnel URL is unchanged."
    ;;

  stop)
    echo "Stopping instance ${INSTANCE_ID}..."
    aws ec2 stop-instances --region "${REGION}" --instance-ids "${INSTANCE_ID}"
    echo "✓ Instance stopping. Compute billing is paused ($0.00/hr)."
    ;;

  start)
    echo "Starting instance ${INSTANCE_ID}..."
    aws ec2 start-instances --region "${REGION}" --instance-ids "${INSTANCE_ID}"
    echo "Waiting for instance to run..."
    aws ec2 wait instance-running --region "${REGION}" --instance-ids "${INSTANCE_ID}"
    NEW_IP=$(get_ip)
    sed -i "s/^PUBLIC_IP=.*/PUBLIC_IP=\"${NEW_IP}\"/" "$ENV_FILE"
    echo "✓ Instance is running at Public IP: ${NEW_IP}"
    ;;

  terminate)
    read -p "Are you sure you want to PERMANENTLY terminate ${INSTANCE_ID}? (y/N): " -r CONFIRM
    if [[ "$CONFIRM" =~ ^[Yy]$ ]]; then
      echo "Terminating ${INSTANCE_ID}..."
      aws ec2 terminate-instances --region "${REGION}" --instance-ids "${INSTANCE_ID}"
      rm -f "$ENV_FILE"
      echo "✓ Instance terminated and local state cleaned up."
    else
      echo "Aborted."
    fi
    ;;

  *)
    echo "Usage: $0 {status|url|ssh|logs|restart-backend|stop|start|terminate}"
    exit 1
    ;;
esac
