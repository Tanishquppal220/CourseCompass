#!/usr/bin/env bash
# ==============================================================================
# CourseCompass - Automated AWS EC2 Launcher
# Provisions Ubuntu 24.04 LTS on t3.micro in ap-south-1
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AWS_REGION="${AWS_REGION:-ap-south-1}"
INSTANCE_TYPE="t3.micro"
INSTANCE_NAME="coursecompass-demo"
KEY_NAME="onion-grading-key"
KEY_FILE="${SCRIPT_DIR}/coursecompass-key.pem"
SG_NAME="onion-micro-sg"
ROOT_VOLUME_SIZE=15

echo "=================================================================="
echo "  🚀 Launching CourseCompass on AWS EC2 (${AWS_REGION})"
echo "=================================================================="

# Check AWS CLI
if ! command -v aws >/dev/null 2>&1; then
  echo "Error: aws CLI is not installed or not in PATH."
  exit 1
fi

# Verify AWS credentials
echo "Checking AWS credentials..."
CALLER_ARN=$(aws sts get-caller-identity --query 'Arn' --output text)
echo "Authenticated as: ${CALLER_ARN}"

# Verify Key File
if [[ ! -f "$KEY_FILE" ]]; then
  echo "Error: Key file $KEY_FILE not found."
  exit 1
fi
chmod 400 "$KEY_FILE"

# Verify Security Group
echo "Checking Security Group: ${SG_NAME} in ${AWS_REGION}..."
SG_ID=$(aws ec2 describe-security-groups \
  --region "${AWS_REGION}" \
  --group-names "${SG_NAME}" \
  --query 'SecurityGroups[0].GroupId' \
  --output text 2>/dev/null || true)

if [[ -z "${SG_ID}" || "${SG_ID}" == "None" ]]; then
  echo "Security group ${SG_NAME} not found. Creating it..."
  VPC_ID=$(aws ec2 describe-vpcs --region "${AWS_REGION}" --filter Name=isDefault,Values=true --query 'Vpcs[0].VpcId' --output text)
  SG_ID=$(aws ec2 create-security-group \
    --region "${AWS_REGION}" \
    --group-name "${SG_NAME}" \
    --description "Security group for micro EC2 deployments" \
    --vpc-id "${VPC_ID}" \
    --query 'GroupId' --output text)
  aws ec2 authorize-security-group-ingress \
    --region "${AWS_REGION}" \
    --group-id "${SG_ID}" \
    --protocol tcp --port 22 --cidr 0.0.0.0/0
fi
echo "Using Security Group: ${SG_ID}"

# Locate latest Ubuntu 24.04 LTS AMI
echo "Resolving Ubuntu 24.04 LTS AMI..."
AMI_ID=$(aws ec2 describe-images \
  --region "${AWS_REGION}" \
  --owners 099720109477 \
  --filters "Name=name,Values=ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-*" \
            "Name=state,Values=available" \
  --query 'reverse(sort_by(Images, &CreationDate))[0].ImageId' \
  --output text)

if [[ -z "${AMI_ID}" || "${AMI_ID}" == "None" ]]; then
  echo "Error: Could not locate Ubuntu 24.04 LTS AMI in ${AWS_REGION}"
  exit 1
fi
echo "Using AMI: ${AMI_ID}"

# Prepare User Data with injected environment variables
BOOTSTRAP_FILE="${SCRIPT_DIR}/cloud_init_bootstrap.sh"
LOCAL_ENV_FILE="${SCRIPT_DIR}/../backend/.env"

if [[ ! -f "$BOOTSTRAP_FILE" ]]; then
  echo "Error: Bootstrap file not found at $BOOTSTRAP_FILE"
  exit 1
fi

TEMP_USER_DATA=$(mktemp)
trap 'rm -f "$TEMP_USER_DATA"' EXIT

if [[ -f "$LOCAL_ENV_FILE" ]]; then
  echo "Injecting local backend/.env configuration into EC2 user-data payload..."
  ENV_B64=$(base64 -w 0 "$LOCAL_ENV_FILE")
  cat << EOF > "$TEMP_USER_DATA"
#!/usr/bin/env bash
mkdir -p /home/ubuntu
echo "${ENV_B64}" | base64 -d > /home/ubuntu/.app_env
chown ubuntu:ubuntu /home/ubuntu/.app_env
chmod 600 /home/ubuntu/.app_env
EOF
  tail -n +2 "$BOOTSTRAP_FILE" >> "$TEMP_USER_DATA"
else
  cp "$BOOTSTRAP_FILE" "$TEMP_USER_DATA"
fi

echo "Launching ${INSTANCE_TYPE} instance (${ROOT_VOLUME_SIZE}GB gp3)..."
BLOCK_DEVICE_MAPPING="[{\"DeviceName\":\"/dev/sda1\",\"Ebs\":{\"VolumeSize\":${ROOT_VOLUME_SIZE},\"VolumeType\":\"gp3\",\"DeleteOnTermination\":true}}]"

INSTANCE_ID=$(aws ec2 run-instances \
  --region "${AWS_REGION}" \
  --image-id "${AMI_ID}" \
  --instance-type "${INSTANCE_TYPE}" \
  --key-name "${KEY_NAME}" \
  --security-group-ids "${SG_ID}" \
  --block-device-mappings "${BLOCK_DEVICE_MAPPING}" \
  --user-data "file://${TEMP_USER_DATA}" \
  --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=${INSTANCE_NAME}},{Key=Project,Value=CourseCompass}]" \
  --query 'Instances[0].InstanceId' \
  --output text)

echo "✓ Instance launched: ${INSTANCE_ID}"

# Save metadata
cat << EOF > "${SCRIPT_DIR}/.ec2_instance_info.env"
INSTANCE_ID="${INSTANCE_ID}"
REGION="${AWS_REGION}"
KEY_NAME="${KEY_NAME}"
KEY_FILE="${KEY_FILE}"
INSTANCE_TYPE="${INSTANCE_TYPE}"
EOF

echo "Waiting for instance to enter running state..."
aws ec2 wait instance-running --region "${AWS_REGION}" --instance-ids "${INSTANCE_ID}"

PUBLIC_IP=$(aws ec2 describe-instances \
  --region "${AWS_REGION}" \
  --instance-ids "${INSTANCE_ID}" \
  --query 'Reservations[0].Instances[0].PublicIpAddress' \
  --output text)

echo "PUBLIC_IP=\"${PUBLIC_IP}\"" >> "${SCRIPT_DIR}/.ec2_instance_info.env"

echo "=================================================================="
echo "  🎉 Instance is running at Public IP: ${PUBLIC_IP}"
echo "  Instance ID: ${INSTANCE_ID}"
echo "=================================================================="
echo ""
echo "Bootstrap is running in background (usually takes ~3-4 minutes)."
echo "You can check status at any time with:"
echo "  ./deploy/manage_ec2.sh status"
echo "  ./deploy/manage_ec2.sh url"
