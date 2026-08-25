#!/usr/bin/env bash
# Set up the local side: the qwen-ec2 CLI, claude-code-router, the SSM plugin,
# and optionally opencode. Installs nothing that needs root.
#
#   ./install-client.sh                  Claude Code path only (ccr)
#   ./install-client.sh --with-opencode   also install opencode, ready to use
#
# Safe to re-run. Existing configs are backed up rather than overwritten, so
# your own edits are never silently discarded.
set -euo pipefail
cd "$(dirname "$0")"

BIN_DIR="${BIN_DIR:-$HOME/bin}"
CCR_CONFIG="$HOME/.claude-code-router/config.json"
OPENCODE_CONFIG="$HOME/.config/opencode/opencode.json"

WITH_OPENCODE=0
for arg in "$@"; do
  case "$arg" in
    --with-opencode) WITH_OPENCODE=1 ;;
    -h|--help) sed -n '2,/^set -euo/p' "$0" | sed -E 's/^# ?//;/^set -euo/d'; exit 0 ;;
    *) printf 'unknown option: %s\n' "$arg" >&2; exit 1 ;;
  esac
done

die()  { printf '\033[31merror:\033[0m %s\n' "$*" >&2; exit 1; }
info() { printf '\033[36m==>\033[0m %s\n' "$*"; }
ok()   { printf '\033[32m ok\033[0m %s\n' "$*"; }
skip() { printf '\033[33m  ~\033[0m %s\n' "$*"; }

mkdir -p "$BIN_DIR"

# ------------------------------------------------------------ 1. qwen-ec2 CLI
info "installing qwen-ec2 to $BIN_DIR"
install -m 755 ./qwen-ec2 "$BIN_DIR/qwen-ec2"
ln -sfn "$BIN_DIR/qwen-ec2" "$BIN_DIR/qwen3-ec2"
ok "$BIN_DIR/qwen-ec2 (also qwen3-ec2)"

# A second laptop copies ~/.config/qwen-ec2/config.env from the machine that
# ran provision.sh. Rewrite laptop-local paths and keep a copy of the chat
# template next to it so `start` can scp it without the other home directory.
CONFIG_DST="${QWEN_EC2_CONFIG:-$HOME/.config/qwen-ec2/config.env}"
mkdir -p "$(dirname "$CONFIG_DST")"
install -m 644 ./chat_template.jinja "$HOME/.config/qwen-ec2/chat_template.jinja"
if [ ! -f "$CONFIG_DST" ]; then
  printf '\033[33mnote:\033[0m no %s yet — copy it from the laptop that ran provision.sh\n' "$CONFIG_DST"
else
  info "adopting $CONFIG_DST for this machine"
  # shellcheck source=/dev/null
  set +u
  . "$CONFIG_DST"
  set -u
  # Keep a custom key that exists here; otherwise the other laptop's $HOME.
  if [ -z "${SSH_KEY:-}" ] || [ ! -f "$SSH_KEY" ]; then
    SSH_KEY='$HOME/.ssh/id_ed25519'
  fi
  tmp=$(mktemp)
  awk -v key="$SSH_KEY" '
    /^SSH_KEY=/ { printf "SSH_KEY=\"%s\"\n", key; next }
    /^CHAT_TEMPLATE=/ { print "CHAT_TEMPLATE=\"$HOME/.config/qwen-ec2/chat_template.jinja\""; next }
    { print }
  ' "$CONFIG_DST" > "$tmp"
  mv "$tmp" "$CONFIG_DST"
  ok "config localized"
  if [ -n "${INSTANCE_ID:-}" ] && command -v aws >/dev/null; then
    if aws ec2 describe-instances --instance-ids "$INSTANCE_ID" --region "${AWS_REGION:-eu-north-1}" \
         --query 'Reservations[0].Instances[0].InstanceId' --output text >/dev/null 2>&1; then
      ok "AWS can see $INSTANCE_ID"
    else
      printf '\033[33mnote:\033[0m instance %s is not in this AWS account/region. Same credentials as provision.sh?\n' "$INSTANCE_ID"
      printf '       aws sts get-caller-identity\n'
    fi
  fi
fi

# ------------------------------------------------------- 2. claude-code-router
if command -v ccr >/dev/null; then
  skip "ccr present ($(ccr -v 2>&1 | head -1))"
else
  command -v npm >/dev/null || die "npm not found; install Node first"
  info "installing @musistudio/claude-code-router"
  npm install -g @musistudio/claude-code-router >/dev/null 2>&1 \
    || die "npm install claude-code-router failed"
  ok "ccr installed"
fi

if [ -f "$CCR_CONFIG" ]; then
  if cmp -s ./ccr-config.json "$CCR_CONFIG"; then
    skip "ccr config already matches"
  else
    cp "$CCR_CONFIG" "$CCR_CONFIG.bak"
    cp ./ccr-config.json "$CCR_CONFIG"
    ok "ccr config updated (previous saved to $CCR_CONFIG.bak)"
  fi
else
  mkdir -p "$(dirname "$CCR_CONFIG")"
  cp ./ccr-config.json "$CCR_CONFIG"
  ok "wrote $CCR_CONFIG"
fi

# ccr caches its config at startup, so a running router keeps serving the old
# provider until it is restarted.
if pgrep -f 'claude-code-router/dist/cli.js' >/dev/null 2>&1; then
  info "restarting ccr to pick up the config"
  ccr restart >/dev/null 2>&1 || { ccr stop >/dev/null 2>&1 || true; }
  ok "ccr restarted"
fi

# --------------------------------------------------------- 3. SSM plugin (mac)
# Needed only for `qwen-ec2 tunnel-ssm`, the path that works with no public IP,
# no inbound rule and no SSH key.
if command -v session-manager-plugin >/dev/null; then
  skip "session-manager-plugin present"
elif [ "$(uname -s)" = "Darwin" ]; then
  info "installing session-manager-plugin into $BIN_DIR (no sudo)"
  arch=$(uname -m); case "$arch" in arm64) plat=mac_arm64;; *) plat=mac;; esac
  tmp=$(mktemp -d)
  curl -fsSL -o "$tmp/smp.zip" \
    "https://s3.amazonaws.com/session-manager-downloads/plugin/latest/$plat/sessionmanager-bundle.zip"
  unzip -q "$tmp/smp.zip" -d "$tmp"
  install -m 755 "$tmp/sessionmanager-bundle/bin/session-manager-plugin" "$BIN_DIR/"
  xattr -d com.apple.quarantine "$BIN_DIR/session-manager-plugin" 2>/dev/null || true
  rm -rf "$tmp"
  ok "session-manager-plugin installed"
else
  skip "not macOS; install session-manager-plugin from your package manager"
fi

# ---------------------------------------------------------------- 4. opencode
# opencode talks to llama-server's OpenAI-compatible endpoint directly, so it needs no
# router: point it at the tunnel and it works. `model` is set at the top level
# so a bare `opencode` starts on Qwen with no picker and no further setup.
if [ "$WITH_OPENCODE" = 1 ]; then
  if command -v opencode >/dev/null; then
    skip "opencode present ($(opencode --version 2>&1 | head -1))"
  else
    command -v npm >/dev/null || die "npm not found; install Node first"
    info "installing opencode"
    npm install -g opencode-ai@latest >/dev/null 2>&1 || die "npm install opencode-ai failed"
    ok "opencode installed"
  fi

  write_opencode_config() {
    mkdir -p "$(dirname "$OPENCODE_CONFIG")"
    cat > "$OPENCODE_CONFIG" <<'JSON'
{
  "$schema": "https://opencode.ai/config.json",
  "provider": {
    "qwen-ec2": {
      "npm": "@ai-sdk/openai-compatible",
      "name": "Qwen3.8-27B Uncensored (EC2 L40S)",
      "options": {
        "baseURL": "http://127.0.0.1:8000/v1",
        "apiKey": "not-used"
      },
      "models": {
        "qwen3.8-27b": {
          "name": "Qwen3.8-27B Uncensored Q8_0 (L40S)",
          "tool_call": true,
          "reasoning": true,
          "limit": { "context": 65536, "output": 8192 },
          "options": { "temperature": 1.0, "top_p": 0.95, "top_k": 20 }
        }
      }
    }
  },
  "model": "qwen-ec2/qwen3.8-27b"
}
JSON
  }

  if [ -f "$OPENCODE_CONFIG" ]; then
    if grep -q '"qwen3.8-27b"' "$OPENCODE_CONFIG" 2>/dev/null; then
      skip "opencode config already has qwen3.8-27b"
    else
      cp "$OPENCODE_CONFIG" "$OPENCODE_CONFIG.bak"
      write_opencode_config
      ok "opencode config written (previous saved to $OPENCODE_CONFIG.bak)"
    fi
  else
    write_opencode_config
    ok "wrote $OPENCODE_CONFIG"
  fi
  info "run it with:  qwen-ec2 tunnel-bg && opencode"
else
  skip "opencode not requested (pass --with-opencode)"
fi

printf '\n'
case ":$PATH:" in
  *":$BIN_DIR:"*) ok "client ready" ;;
  *) printf '\033[33mnote:\033[0m add %s to PATH:  echo '"'"'export PATH="%s:$PATH"'"'"' >> ~/.zshrc\n' \
       "$BIN_DIR" "$BIN_DIR" ;;
esac
