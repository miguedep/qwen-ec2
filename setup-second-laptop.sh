#!/usr/bin/env bash
# Set up a second laptop to drive the existing qwen-ec2 stack.
#
#   ./setup-second-laptop.sh
#
# Expects: the qwen-ec2 repo (this script lives in it), the AWS CLI with
# credentials for the same account, and Node + npm. Does everything else:
# writes the config, installs the client, verifies the AWS side.
#
# After it finishes, in this order:
#   1. make sure ~/.ssh/id_ed25519 exists here (see the note it prints),
#   2. qwen-ec2 start && qwen-ec2 tunnel-bg     (or qwen-ec2 tunnel-ssm, no key needed)
#   3. qwen-ec2 code
set -euo pipefail
cd "$(dirname "$0")"

die()  { printf '\033[31merror:\033[0m %s\n' "$*" >&2; exit 1; }
info() { printf '\033[36m==>\033[0m %s\n' "$*"; }
ok()   { printf '\033[32m ok\033[0m %s\n' "$*"; }

# Values provision.sh wrote on the original laptop, 2026-08-25.
NAME="qwen3-inference"
AWS_REGION="eu-north-1"
INSTANCE_ID="i-05a1f2e133e38722d"
HOURLY_USD="1.974"
REPO_URL="git@github.com:miguedep/qwen-ec2.git"

# ------------------------------------------------------------- prerequisites
for cmd in aws node npm unzip ssh; do
  command -v "$cmd" >/dev/null || die "$cmd not found; install it first"
done
ok "prerequisites present"

# ------------------------------------------------- clone the repo if needed
if [ ! -f ./provision.sh ]; then
  info "cloning $REPO_URL"
  REPO_DIR="$(mktemp -d)/qwen-ec2"
  git clone "$REPO_URL" "$REPO_DIR" || die "git clone failed; is the repo reachable?"
  cd "$REPO_DIR" || exit 1
  exec ./setup-second-laptop.sh
fi

# --------------------------------------------------------------------- config
CONFIG_DIR="$HOME/.config/qwen-ec2"
CONFIG="$CONFIG_DIR/config.env"
mkdir -p "$CONFIG_DIR"
if [ -f "$CONFIG" ] && grep -q "INSTANCE_ID=\"$INSTANCE_ID\"" "$CONFIG"; then
  info "existing $CONFIG already points at $INSTANCE_ID; leaving it"
else
  if [ -f "$CONFIG" ]; then
    mv "$CONFIG" "$CONFIG.bak-$(date +%Y%m%d%H%M%S)"
    info "previous config saved to $CONFIG.bak-*"
  fi
  cat > "$CONFIG" <<EOF
# Written by setup-second-laptop.sh on $(date '+%F %T'). Read by qwen-ec2 and teardown.sh.
NAME="$NAME"
AWS_REGION="$AWS_REGION"
AWS_PROFILE=""
INSTANCE_ID="$INSTANCE_ID"
ALLOCATION_ID=""
ELASTIC_IP=""
SSH_HOST="qwen-gpu"
SSH_KEY="\$HOME/.ssh/id_ed25519"
SSH_USER="ubuntu"
LOCAL_PORT=8000
REMOTE_PORT=8000
HOURLY_USD="$HOURLY_USD"
CHAT_TEMPLATE="\$HOME/.config/qwen-ec2/chat_template.jinja"
EOF
  ok "wrote $CONFIG"
fi

# ----------------------------------------------------------- ssh key on hand
# The public half lives in AWS as key pair $NAME-key; the private half is on
# the original laptop. Without it, `tunnel-ssm` still works (no key, no port 22).
if [ -f "$HOME/.ssh/id_ed25519" ]; then
  ok "~/.ssh/id_ed25519 present (ssh tunnel will work)"
else
  printf '\033[33mnote:\033[0m no ~/.ssh/id_ed25519 here.\n'
  printf '       Either copy it from the original laptop, or use the keyless path:\n'
  printf '         qwen-ec2 start && qwen-ec2 tunnel-ssm\n'
  printf '       (SSM needs no SSH key, no open port 22; only AWS credentials.)\n'
fi

# ------------------------------------------------------------------- client
info "installing the client (qwen-ec2 CLI, ccr, SSM plugin)"
./install-client.sh

# ------------------------------------------------------------------- verify
if ! aws sts get-caller-identity >/dev/null 2>&1; then
  printf '\033[33mnote:\033[0m no valid AWS credentials yet. Run:  aws sso login\n'
else
  ACCOUNT=$(aws sts get-caller-identity --query Account --output text)
  if aws ec2 describe-instances --instance-ids "$INSTANCE_ID" --region "$AWS_REGION" \
       --query 'Reservations[0].Instances[0].State.Name' --output text >/dev/null 2>&1; then
    STATE=$(aws ec2 describe-instances --instance-ids "$INSTANCE_ID" --region "$AWS_REGION" \
            --query 'Reservations[0].Instances[0].State.Name' --output text)
    ok "AWS (account $ACCOUNT) sees $INSTANCE_ID, state: $STATE"
  else
    printf '\033[33mnote:\033[0m account %s cannot see %s in %s. Same account as the original laptop?\n' \
      "$ACCOUNT" "$INSTANCE_ID" "$AWS_REGION"
  fi
fi

printf '\n'
ok "setup complete. Then, in order:"
printf '   qwen-ec2 start && qwen-ec2 tunnel-bg     # supervised ssh tunnel\n'
printf '   qwen-ec2 tunnel-ssm                      # ...or keyless SSM tunnel\n'
printf '   qwen-ec2 code\n'
