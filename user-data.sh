#!/bin/bash
# Provision llama.cpp serving the Coletti Qwen3.8-27B Uncensored Q8_0 GGUF
# on a single L40S (48 GB). Runs once at first boot; safe to re-run.
#
# The chat template is NOT in this script: EC2 user-data is capped at 16 KB
# and froggeric v22.3 is ~26 KB. provision.sh / qwen-ec2 start scp
# chat_template.jinja onto EBS before the server can stay up.
set -euxo pipefail
exec > >(tee -a /var/log/qwen-bootstrap.log) 2>&1

HF_REPO="JonathanColetti/Qwen3.8-27B-Uncensored-GGUF"
GGUF="Qwen3.8-27B-Uncensored-Q8_0.gguf"
MODEL_DIR="/opt/models"

mkdir -p "$MODEL_DIR"
chown ubuntu:ubuntu "$MODEL_DIR"

# The DLAMI base image ships the NVIDIA driver, Docker and the NVIDIA container
# toolkit, so we only need the huggingface CLI for the pre-download.
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y python3-pip jq
pip3 install --break-system-packages -U "huggingface_hub[cli]"

docker pull ghcr.io/ggml-org/llama.cpp:server-cuda

# One 29 GB file onto EBS so later start/stop does not re-download.
# Anonymous HF downloads are rate limited; export HF_TOKEN if this 429s.
hf download "$HF_REPO" "$GGUF" --local-dir "$MODEL_DIR"
chown -R ubuntu:ubuntu "$MODEL_DIR"

# llama-server listens on the host loopback only. Access is via an SSH tunnel,
# so port 8000 is never exposed. There is no API key on the server, which is
# precisely why that matters. mmap is left on: g6e.xlarge has 32 GiB RAM and
# this GGUF is 29 GB, so --no-mmap / --mlock will OOM.
cat >/etc/systemd/system/llama.service <<'UNIT'
[Unit]
Description=llama.cpp OpenAI-compatible server (Qwen3.8-27B Uncensored Q8_0)
After=docker.service network-online.target
Requires=docker.service

[Service]
Restart=always
RestartSec=10
TimeoutStartSec=0
ExecStartPre=-/usr/bin/docker rm -f llama
ExecStart=/usr/bin/docker run --rm --name llama \
  --gpus all \
  -p 127.0.0.1:8000:8000 \
  -v /opt/models:/models \
  ghcr.io/ggml-org/llama.cpp:server-cuda \
  --model /models/Qwen3.8-27B-Uncensored-Q8_0.gguf \
  --alias qwen3.8-27b \
  --host 0.0.0.0 \
  --port 8000 \
  --n-gpu-layers 99 \
  --ctx-size 262144 \
  --cache-type-k q8_0 \
  --cache-type-v q8_0 \
  --flash-attn on \
  --parallel 1 \
  --spec-type draft-mtp \
  --spec-draft-n-max 1 \
  --jinja \
  --chat-template-file /models/chat_template.jinja \
  --reasoning-format deepseek \
  --chat-template-kwargs '{"reasoning_effort":"medium"}' \
  --cache-prompt \
  --cache-reuse 256
ExecStop=/usr/bin/docker stop llama

[Install]
WantedBy=multi-user.target
UNIT

systemctl daemon-reload
systemctl enable --now llama.service

# Marker the start script polls to know provisioning finished.
touch /var/lib/cloud/qwen-bootstrap-done
echo "BOOTSTRAP COMPLETE"
