#!/usr/bin/env bash
# Delete the whole stack and stop all billing for it.
#
#   ./teardown.sh              prompt, then delete
#   ./teardown.sh --yes        no prompt
#   ./teardown.sh --dry-run    print what would be deleted
#
# Deletes, in order: local tunnel, instance (its root volume goes with it),
# Elastic IP, security group, IAM role/profile, key pair. Ordering matters: the
# security group cannot be deleted until the instance's ENI is released.
#
# This is irreversible. An Elastic IP in particular can never be reclaimed.
# The model weights live only on the instance's volume, so a rebuild
# re-downloads ~29 GB.
set -euo pipefail
cd "$(dirname "$0")"

CONFIG="${QWEN_EC2_CONFIG:-$HOME/.config/qwen-ec2/config.env}"
ASSUME_YES=0
DRY_RUN=0
for arg in "$@"; do
  case "$arg" in
    --yes|-y)  ASSUME_YES=1 ;;
    --dry-run) DRY_RUN=1 ;;
    -h|--help) sed -n '2,/^set -euo/p' "$0" | sed -E 's/^# ?//;/^set -euo/d'; exit 0 ;;
    *) printf 'unknown option: %s\n' "$arg" >&2; exit 1 ;;
  esac
done

die()  { printf '\033[31merror:\033[0m %s\n' "$*" >&2; exit 1; }
info() { printf '\033[36m==>\033[0m %s\n' "$*"; }
ok()   { printf '\033[32m ok\033[0m %s\n' "$*"; }
skip() { printf '\033[33m  ~\033[0m %s\n' "$*"; }
# The wrapper owns the output redirect; see the note in provision.sh.
run()  { if [ "$DRY_RUN" = 1 ]; then printf '\033[90m  would run:\033[0m %s\n' "$*"; else "$@" >/dev/null; fi; }

[ -f "$CONFIG" ] || die "no config at $CONFIG; nothing to tear down (or set QWEN_EC2_CONFIG)"
# shellcheck source=/dev/null
. "$CONFIG"
: "${NAME:=qwen3-inference}"
export AWS_REGION="${AWS_REGION:-eu-north-1}"

ACCOUNT=$(aws sts get-caller-identity --query Account --output text 2>/dev/null) \
  || die "no valid AWS credentials (try: aws sso login)"

printf '\nAbout to delete from account %s in %s:\n' "$ACCOUNT" "$AWS_REGION"
printf '  instance        %s (and its root volume)\n' "${INSTANCE_ID:-none}"
printf '  elastic IP      %s\n' "${ELASTIC_IP:-none}"
printf '  security group  %s-sg\n' "$NAME"
printf '  IAM role        %s-role  (+ %s-profile)\n' "$NAME" "$NAME"
printf '  key pair        %s-key\n\n' "$NAME"

if [ "$ASSUME_YES" != 1 ] && [ "$DRY_RUN" != 1 ]; then
  printf 'Type the instance id to confirm: '
  read -r reply
  [ "$reply" = "${INSTANCE_ID:-}" ] || die "confirmation did not match; nothing deleted"
fi

# --------------------------------------------------------- 1. local tunnel
info "closing the local tunnel"
if command -v qwen-ec2 >/dev/null; then
  run qwen-ec2 tunnel-kill || true
else
  run pkill -f 'supervise-tunnel' || true
  run pkill -f "${LOCAL_PORT:-8000}:127.0.0.1:${REMOTE_PORT:-8000}" || true
fi

# ------------------------------------------------------------- 2. instance
if [ -n "${INSTANCE_ID:-}" ] && aws ec2 describe-instances --instance-ids "$INSTANCE_ID" \
     --query 'Reservations[0].Instances[0].State.Name' --output text >/dev/null 2>&1; then
  info "terminating $INSTANCE_ID"
  run aws ec2 terminate-instances --instance-ids "$INSTANCE_ID"
  # Wait: the ENI must be released before the security group can be deleted.
  info "waiting for termination (releases the ENI)"
  run aws ec2 wait instance-terminated --instance-ids "$INSTANCE_ID"
  ok "terminated (root volume deleted with it)"
else
  skip "instance ${INSTANCE_ID:-none} not found"
fi

# ----------------------------------------------------------- 3. Elastic IP
if [ -n "${ALLOCATION_ID:-}" ]; then
  info "releasing Elastic IP ${ELASTIC_IP:-$ALLOCATION_ID}"
  ASSOC=$(aws ec2 describe-addresses --allocation-ids "$ALLOCATION_ID" \
            --query 'Addresses[0].AssociationId' --output text 2>/dev/null || echo None)
  # release-address fails on an associated address, so disassociate first.
  [ "$ASSOC" = "None" ] || run aws ec2 disassociate-address --association-id "$ASSOC"
  run aws ec2 release-address --allocation-id "$ALLOCATION_ID" \
    && ok "released (this address can never be reclaimed)" \
    || skip "already released"
else
  skip "no Elastic IP recorded"
fi

# -------------------------------------------------------- 4. security group
SG=$(aws ec2 describe-security-groups --filters "Name=group-name,Values=$NAME-sg" \
       --query 'SecurityGroups[0].GroupId' --output text 2>/dev/null || echo None)
if [ "$SG" != "None" ] && [ -n "$SG" ]; then
  info "deleting security group $SG"
  run aws ec2 delete-security-group --group-id "$SG" && ok "deleted" \
    || skip "still in use; retry in a minute"
else
  skip "no security group $NAME-sg"
fi

# --------------------------------------------------------------- 5. IAM
if aws iam get-instance-profile --instance-profile-name "$NAME-profile" >/dev/null 2>&1; then
  info "deleting IAM role and instance profile"
  run aws iam remove-role-from-instance-profile \
    --instance-profile-name "$NAME-profile" --role-name "$NAME-role" || true
  run aws iam delete-instance-profile --instance-profile-name "$NAME-profile" || true
  run aws iam detach-role-policy --role-name "$NAME-role" \
    --policy-arn arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore || true
  run aws iam delete-role --role-name "$NAME-role" || true
  ok "IAM cleaned up"
else
  skip "no instance profile $NAME-profile"
fi

# ----------------------------------------------------------- 6. key pair
if aws ec2 describe-key-pairs --key-names "$NAME-key" >/dev/null 2>&1; then
  info "deleting key pair $NAME-key"
  run aws ec2 delete-key-pair --key-name "$NAME-key"
  ok "deleted (your local $SSH_KEY is untouched)"
else
  skip "no key pair $NAME-key"
fi

# ------------------------------------------------------------ 7. leftovers
info "checking for resources that would keep billing"
STRAY_VOL=$(aws ec2 describe-volumes --filters Name=status,Values=available \
  --query 'Volumes[].VolumeId' --output text 2>/dev/null || true)
[ -z "$STRAY_VOL" ] && ok "no unattached volumes" || printf '  unattached volumes: %s\n' "$STRAY_VOL"
STRAY_EIP=$(aws ec2 describe-addresses --query 'Addresses[?AssociationId==null].PublicIp' \
  --output text 2>/dev/null || true)
[ -z "$STRAY_EIP" ] && ok "no unassociated Elastic IPs" || printf '  unassociated EIPs: %s\n' "$STRAY_EIP"

if [ "$DRY_RUN" != 1 ]; then
  mv "$CONFIG" "$CONFIG.deleted-$(date +%Y%m%d%H%M%S)"
  ok "config archived; run ./provision.sh to build a fresh stack"
fi
