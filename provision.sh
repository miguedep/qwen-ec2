#!/usr/bin/env bash
# Create the Qwen3.8-27B Uncensored Q8_0 (llama.cpp) inference stack in the
# current AWS account,
# then wire up the local client (ccr + tunnel) so `qwen-ec2 code` just works.
#
#   ./provision.sh                  create everything, using defaults below
#   ./provision.sh --with-eip       also allocate an Elastic IP (~$3.6/mo idle)
#   ./provision.sh --with-opencode  also install opencode, ready to use
#   ./provision.sh --dry-run        print what would happen, touch nothing
#
# Idempotent: every resource is looked up before it is created, so re-running
# after a partial failure resumes instead of duplicating. The one thing it will
# not do twice is launch a second instance; if a live one is tagged with $NAME
# it adopts it.
#
# Costs money. A g6e.xlarge is ~$1.97/h in eu-north-1 and starts billing the
# moment it launches.
set -euo pipefail
cd "$(dirname "$0")"

NAME="${NAME:-qwen3-inference}"
export AWS_REGION="${AWS_REGION:-eu-north-1}"
INSTANCE_TYPE="${INSTANCE_TYPE:-g6e.xlarge}"
VOLUME_GB="${VOLUME_GB:-100}"
# g6e.xlarge EBS cap is ~5 Gbps (~625 MB/s). gp3 baseline is 125 MB/s.
VOLUME_THROUGHPUT="${VOLUME_THROUGHPUT:-625}"
HOURLY_USD="${HOURLY_USD:-1.974}"
SSH_KEY="${SSH_KEY:-$HOME/.ssh/id_ed25519}"
SSH_HOST="${SSH_HOST:-qwen-gpu}"
CONFIG="${QWEN_EC2_CONFIG:-$HOME/.config/qwen-ec2/config.env}"
# g6e.xlarge is 4 vCPUs of the "Running On-Demand G and VR instances" quota.
GPU_QUOTA_CODE="L-DB2E81BA"
VCPUS_NEEDED=4

WITH_EIP=0
DRY_RUN=0
CLIENT_ARGS=()
for arg in "$@"; do
  case "$arg" in
    --with-eip) WITH_EIP=1 ;;
    --with-opencode) CLIENT_ARGS+=("--with-opencode") ;;
    --dry-run)  DRY_RUN=1 ;;
    -h|--help)  sed -n '2,/^set -euo/p' "$0" | sed -E 's/^# ?//;/^set -euo/d'; exit 0 ;;
    *) printf 'unknown option: %s\n' "$arg" >&2; exit 1 ;;
  esac
done

die()  { printf '\033[31merror:\033[0m %s\n' "$*" >&2; exit 1; }
info() { printf '\033[36m==>\033[0m %s\n' "$*"; }
ok()   { printf '\033[32m ok\033[0m %s\n' "$*"; }
skip() { printf '\033[33m  ~\033[0m %s\n' "$*"; }
# The wrapper owns the output redirect. A `>/dev/null` on the call site would
# swallow the "would run" line too, making a dry run claim it did things.
run()  { if [ "$DRY_RUN" = 1 ]; then printf '\033[90m  would run:\033[0m %s\n' "$*"; else "$@" >/dev/null; fi; }

command -v aws >/dev/null || die "aws CLI not found"
aws sts get-caller-identity >/dev/null 2>&1 || die "no valid AWS credentials (try: aws sso login)"
ACCOUNT=$(aws sts get-caller-identity --query Account --output text)
info "account $ACCOUNT, region $AWS_REGION, name prefix $NAME"
[ "$DRY_RUN" = 1 ] && info "DRY RUN: nothing will be created"

# ---------------------------------------------------------------- 0. GPU quota
# Checked first because a fresh account has a quota of zero here, the request
# takes hours to days to approve, and every later step is wasted without it.
info "checking GPU vCPU quota ($GPU_QUOTA_CODE)"
QUOTA=$(aws service-quotas get-service-quota --service-code ec2 \
          --quota-code "$GPU_QUOTA_CODE" --query 'Quota.Value' --output text 2>/dev/null || echo 0)
QUOTA=${QUOTA%.*}
if [ "${QUOTA:-0}" -lt "$VCPUS_NEEDED" ]; then
  printf '\033[31merror:\033[0m G-instance vCPU quota is %s, need %s in %s.\n' \
    "${QUOTA:-0}" "$VCPUS_NEEDED" "$AWS_REGION" >&2
  printf '       Request an increase, then re-run:\n' >&2
  printf '         aws service-quotas request-service-quota-increase \\\n' >&2
  printf '           --service-code ec2 --quota-code %s --desired-value %s --region %s\n' \
    "$GPU_QUOTA_CODE" "$VCPUS_NEEDED" "$AWS_REGION" >&2
  exit 1
fi
ok "quota is $QUOTA vCPU"

# ------------------------------------------------------------------ 1. key pair
if aws ec2 describe-key-pairs --key-names "$NAME-key" >/dev/null 2>&1; then
  skip "key pair $NAME-key exists"
elif [ -f "$SSH_KEY.pub" ]; then
  info "importing $SSH_KEY.pub as $NAME-key"
  run aws ec2 import-key-pair --key-name "$NAME-key" \
    --public-key-material "fileb://$SSH_KEY.pub"
  ok "key pair imported (your existing $SSH_KEY keeps working)"
else
  info "no $SSH_KEY.pub; generating a new AWS key pair"
  # Not via run(): this one's stdout IS the private key, and run() sends
  # stdout to /dev/null, which would leave an empty .pem behind.
  if [ "$DRY_RUN" = 1 ]; then
    printf '\033[90m  would run:\033[0m aws ec2 create-key-pair > %s\n' "$HOME/.ssh/$NAME-key.pem"
  else
    aws ec2 create-key-pair --key-name "$NAME-key" --key-type ed25519 \
      --query KeyMaterial --output text > "$HOME/.ssh/$NAME-key.pem"
    chmod 600 "$HOME/.ssh/$NAME-key.pem"
  fi
  SSH_KEY="$HOME/.ssh/$NAME-key.pem"
  ok "created $SSH_KEY"
fi

# ------------------------------------------------------------- 2. network + SG
VPC=$(aws ec2 describe-vpcs --filters Name=isDefault,Values=true \
        --query 'Vpcs[0].VpcId' --output text)
[ "$VPC" != "None" ] || die "no default VPC in $AWS_REGION; set VPC/SUBNET manually"
# Subnets[0] is an arbitrary AZ. g6e capacity is often missing in one AZ
# and present in another, so launch tries every default-VPC subnet.
SUBNETS=$(aws ec2 describe-subnets --filters "Name=vpc-id,Values=$VPC" \
            --query 'sort_by(Subnets,&AvailabilityZone)[].[SubnetId,AvailabilityZone]' \
            --output text)
[ -n "$SUBNETS" ] || die "no subnets in default VPC $VPC"

MY_IP=$(curl -fsS https://checkip.amazonaws.com | tr -d '[:space:]')
[ -n "$MY_IP" ] || die "could not detect your public IP"

SG=$(aws ec2 describe-security-groups --filters "Name=group-name,Values=$NAME-sg" \
       --query 'SecurityGroups[0].GroupId' --output text 2>/dev/null || echo None)
if [ "$SG" != "None" ] && [ -n "$SG" ]; then
  skip "security group $NAME-sg exists ($SG)"
else
  info "creating security group $NAME-sg"
  if [ "$DRY_RUN" = 1 ]; then
    SG="sg-DRYRUN"
    run aws ec2 create-security-group --group-name "$NAME-sg" --vpc-id "$VPC"
  else
    SG=$(aws ec2 create-security-group --group-name "$NAME-sg" \
          --description "Qwen3.8 llama.cpp inference host - SSH from operator IP only" \
          --vpc-id "$VPC" --query GroupId --output text)
  fi
  ok "created $SG"
fi
# Port 8000 is deliberately never opened: llama-server has no auth, and the
# only access path is the SSH tunnel.
if [ "$DRY_RUN" != 1 ] && ! aws ec2 describe-security-groups --group-ids "$SG" \
     --query "SecurityGroups[0].IpPermissions[?FromPort==\`22\`].IpRanges[].CidrIp" \
     --output text | grep -q "$MY_IP/32"; then
  info "authorising SSH from $MY_IP/32"
  aws ec2 authorize-security-group-ingress --group-id "$SG" \
    --ip-permissions "IpProtocol=tcp,FromPort=22,ToPort=22,IpRanges=[{CidrIp=$MY_IP/32,Description='qwen-ec2 managed'}]" \
    >/dev/null 2>&1 || skip "rule already present"
fi

# ------------------------------------------------------------------ 3. IAM role
# AmazonSSMManagedInstanceCore is what makes `qwen-ec2 tunnel-ssm` work with no
# public IP, no open port 22 and no SSH key.
if aws iam get-instance-profile --instance-profile-name "$NAME-profile" >/dev/null 2>&1; then
  skip "instance profile $NAME-profile exists"
else
  info "creating IAM role and instance profile"
  run aws iam create-role --role-name "$NAME-role" --assume-role-policy-document \
    '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"ec2.amazonaws.com"},"Action":"sts:AssumeRole"}]}'
  run aws iam attach-role-policy --role-name "$NAME-role" \
    --policy-arn arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore
  run aws iam create-instance-profile --instance-profile-name "$NAME-profile"
  run aws iam add-role-to-instance-profile --instance-profile-name "$NAME-profile" \
    --role-name "$NAME-role"
  # IAM is eventually consistent; RunInstances fails if the profile is not yet
  # visible, and the error does not say why.
  info "waiting 10s for IAM propagation"
  run sleep 10
  ok "IAM ready"
fi

# -------------------------------------------------------------------- 4. launch
EXISTING=$(aws ec2 describe-instances \
  --filters "Name=tag:Name,Values=$NAME" \
            "Name=instance-state-name,Values=pending,running,stopping,stopped" \
  --query 'Reservations[0].Instances[0].InstanceId' --output text 2>/dev/null || echo None)

if [ "$EXISTING" != "None" ] && [ -n "$EXISTING" ]; then
  skip "adopting existing instance $EXISTING"
  INSTANCE_ID="$EXISTING"
else
  # Resolve the AMI by name: IDs are region- and release-specific, so a
  # hardcoded one is wrong the moment you change region.
  info "resolving latest Deep Learning Base OSS Nvidia Driver GPU AMI (Ubuntu 24.04)"
  AMI=$(aws ec2 describe-images --owners 898082745236 \
    --filters 'Name=name,Values=Deep Learning Base OSS Nvidia Driver GPU AMI (Ubuntu 24.04)*' \
              'Name=state,Values=available' \
    --query 'sort_by(Images,&CreationDate)[-1].ImageId' --output text)
  [ "$AMI" != "None" ] || die "no matching AMI in $AWS_REGION"
  ok "AMI $AMI"

  info "launching $INSTANCE_TYPE (billing starts now, ~\$$HOURLY_USD/h)"
  if [ "$DRY_RUN" = 1 ]; then
    run aws ec2 run-instances --image-id "$AMI" --instance-type "$INSTANCE_TYPE"
    INSTANCE_ID="i-DRYRUN"
  else
    # /dev/sda1 is the root device for this Ubuntu DLAMI. Using /dev/xvda
    # silently creates a second, unused volume.
    INSTANCE_ID=""
    while read -r SUBNET AZ; do
      [ -n "$SUBNET" ] || continue
      info "trying $AZ ($SUBNET)"
      if out=$(aws ec2 run-instances \
        --image-id "$AMI" \
        --instance-type "$INSTANCE_TYPE" \
        --key-name "$NAME-key" \
        --security-group-ids "$SG" \
        --subnet-id "$SUBNET" \
        --associate-public-ip-address \
        --iam-instance-profile "Name=$NAME-profile" \
        --metadata-options 'HttpTokens=required,HttpPutResponseHopLimit=2,HttpEndpoint=enabled' \
        --block-device-mappings "[{\"DeviceName\":\"/dev/sda1\",\"Ebs\":{\"VolumeSize\":$VOLUME_GB,\"VolumeType\":\"gp3\",\"Throughput\":$VOLUME_THROUGHPUT,\"Encrypted\":true,\"DeleteOnTermination\":true}}]" \
        --user-data "file://user-data.sh" \
        --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=$NAME},{Key=Owner,Value=${OWNER:-$USER}},{Key=Purpose,Value=qwen3.8-27b-q8-gguf}]" \
        --query 'Instances[0].InstanceId' --output text 2>&1); then
        INSTANCE_ID="$out"
        break
      fi
      if printf '%s\n' "$out" | grep -q InsufficientInstanceCapacity; then
        skip "no $INSTANCE_TYPE capacity in $AZ"
        continue
      fi
      die "$out"
    done <<< "$SUBNETS"
    [ -n "$INSTANCE_ID" ] || die "no $INSTANCE_TYPE capacity in any AZ of $AWS_REGION"
    ok "launched $INSTANCE_ID"
    aws ec2 wait instance-running --instance-ids "$INSTANCE_ID"
  fi
fi

# --------------------------------------------------------------- 5. Elastic IP
ALLOCATION_ID=""
ELASTIC_IP=""
if [ "$WITH_EIP" = 1 ]; then
  if [ "$DRY_RUN" = 1 ]; then
    run aws ec2 allocate-address --domain vpc
  else
    info "allocating Elastic IP"
    ALLOCATION_ID=$(aws ec2 allocate-address --domain vpc \
      --tag-specifications "ResourceType=elastic-ip,Tags=[{Key=Name,Value=$NAME-eip},{Key=Owner,Value=${OWNER:-$USER}}]" \
      --query AllocationId --output text)
    aws ec2 associate-address --instance-id "$INSTANCE_ID" \
      --allocation-id "$ALLOCATION_ID" >/dev/null
    ELASTIC_IP=$(aws ec2 describe-addresses --allocation-ids "$ALLOCATION_ID" \
      --query 'Addresses[0].PublicIp' --output text)
    ok "Elastic IP $ELASTIC_IP (remember to release it at teardown)"
  fi
else
  info "no Elastic IP: the public address will change on every stop/start"
fi

# ------------------------------------------------------------------ 6. config
info "writing $CONFIG"
if [ "$DRY_RUN" = 1 ]; then
  run mkdir -p "$(dirname "$CONFIG")"
else
  mkdir -p "$(dirname "$CONFIG")"
  # Paths under $HOME are written as $HOME/... so a second laptop can copy
  # this file without inheriting the provision machine's username.
  home_rel() {
    case "$1" in
      "$HOME"/*) printf '%s' "\$HOME/${1#"$HOME"/}" ;;
      *)         printf '%s' "$1" ;;
    esac
  }
  install -m 644 ./chat_template.jinja "$HOME/.config/qwen-ec2/chat_template.jinja"
  cat > "$CONFIG" <<EOF
# Written by provision.sh on $(date '+%F %T'). Read by qwen-ec2 and teardown.sh.
NAME="$NAME"
AWS_REGION="$AWS_REGION"
AWS_PROFILE="${AWS_PROFILE:-}"
INSTANCE_ID="$INSTANCE_ID"
ALLOCATION_ID="$ALLOCATION_ID"
ELASTIC_IP="$ELASTIC_IP"
SSH_HOST="$SSH_HOST"
SSH_KEY="$(home_rel "$SSH_KEY")"
SSH_USER="ubuntu"
LOCAL_PORT=8000
REMOTE_PORT=8000
HOURLY_USD="$HOURLY_USD"
CHAT_TEMPLATE="\$HOME/.config/qwen-ec2/chat_template.jinja"
EOF
  ok "config written"
fi

# ------------------------------------------------------- 7. client + readiness
if [ "$DRY_RUN" = 1 ]; then
  info "would run ./install-client.sh ${CLIENT_ARGS[*]:-}, then qwen-ec2 start && qwen-ec2 tunnel-bg"
  exit 0
fi

# ${arr[@]:+...} so an empty array does not expand to an empty string arg
# under `set -u`.
./install-client.sh ${CLIENT_ARGS[@]:+"${CLIENT_ARGS[@]}"}

info "waiting for first boot (downloads ~29 GB GGUF, allow ~20 min)"
qwen-ec2 start
qwen-ec2 tunnel-bg
qwen-ec2 status

printf '\n'
ok "ready. Launch Claude Code against it with:  qwen-ec2 code"
info "stop paying for the GPU when idle with:  qwen-ec2 down"
