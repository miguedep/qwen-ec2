# qwen-ec2

A single-GPU EC2 host serving **Qwen3.8-27B Uncensored Q8_0** (Coletti GGUF)
through llama.cpp's OpenAI-compatible API, reachable only over an SSH tunnel,
driven from Claude Code via
[claude-code-router](https://github.com/musistudio/claude-code-router) (`ccr`).

This is the runbook for rebuilding it from nothing in a different AWS account.
Decisions: [CONTEXT.md](CONTEXT.md), [ADR 0001](docs/adr/0001-gguf-llamacpp-instead-of-vllm.md),
[ADR 0002](docs/adr/0002-patched-chat-template.md).

## Contents

| File | What it is |
|---|---|
| `README.md` | This runbook |
| `provision.sh` | **Creates the whole stack**, then wires up the client. Idempotent, has `--dry-run`. |
| `teardown.sh` | Deletes everything and stops all billing. Has `--dry-run`. |
| `install-client.sh` | Local side only: `qwen-ec2` CLI, ccr, SSM plugin, optional opencode |
| `user-data.sh` | First-boot: download the GGUF, write and start `llama.service` |
| `llama.service` | The systemd unit (also embedded in user-data) |
| `chat_template.jinja` | Pinned froggeric v22.3 template; scp'd on `qwen-ec2 start` (user-data is 16 KB) |
| `ccr-config.json` | Client-side router config template |
| `qwen-ec2` | The operator CLI (installed to `~/bin/qwen-ec2`) |

## Quick start

```sh
aws sso login                     # or whatever gets you credentials
./provision.sh --dry-run          # see what it would create, touch nothing
./provision.sh                    # create it all (~20 min: 29 GB GGUF)
# On a second laptop, same AWS account as provision.sh:
#   git pull && ./install-client.sh
#   copy ~/.config/qwen-ec2/config.env from the provision machine, then
#   re-run ./install-client.sh (rewrites the other laptop's $HOME paths).
# The command is qwen-ec2; qwen3-ec2 is the same binary.
qwen-ec2 code                     # Claude Code against the model
qwen-ec2 down                     # stop paying for the GPU
./teardown.sh                     # delete everything
```

Add `--with-eip` to `provision.sh` if you want a stable address across
stop/start, at ~$3.6/mo. Without it the public IP changes on every start and
`qwen-ec2 start` re-syncs `~/.ssh/config` for you.

### Using opencode instead of Claude Code

```sh
./provision.sh --with-opencode      # or: ./install-client.sh --with-opencode
qwen-ec2 tunnel-bg && opencode      # starts on Qwen, no picker, no setup
```

This installs `opencode-ai` and writes `~/.config/opencode/opencode.json` with
`model` set at the top level, so a bare `opencode` comes up on
`qwen-ec2/qwen3.8-27b` with the tunnel as its endpoint. It needs no router:
opencode speaks to llama-server's OpenAI-compatible API directly via
`@ai-sdk/openai-compatible`, so `ccr` is only for the Claude Code path. Both
clients can share one tunnel.

Re-running is safe. An existing config keeps its place if it already has
`qwen3.8-27b`, and is backed up to `.bak` before being replaced if not.

`provision.sh` writes `~/.config/qwen-ec2/config.env` (instance id, region,
allocation id, ssh host/key). `qwen-ec2` and `teardown.sh` both read it, which
is why there are no account-specific values left in the scripts. Override the
path with `QWEN_EC2_CONFIG` to run more than one stack. Tunable via env:
`NAME`, `AWS_REGION`, `INSTANCE_TYPE`, `VOLUME_GB`, `VOLUME_THROUGHPUT`, `SSH_KEY`, `SSH_HOST`,
`OWNER`.

The manual walkthrough below is kept because it explains *why* each resource
looks the way it does; `provision.sh` performs exactly these steps.

## What it cost

| Item | Cost |
|---|---|
| `g6e.xlarge` on-demand, eu-north-1 | **$1.974/h while running** |
| 100 GB gp3 @ 625 MB/s (persists while stopped) | **~$29/mo** ($8.36 storage + $20.90 extra throughput) |
| Idle Elastic IP (only billed when unattached) | ~$3.6/mo |

Compute billing stops on `stop`; the volume and EIP keep billing. Re-verify the
hourly rate for your new region, it varies significantly.

## Architecture

```
Claude Code  ->  ccr (localhost:3456)  ->  ssh tunnel (localhost:8000)
                                              |
                                              v
                              EC2 g6e.xlarge, 1x L40S 48 GB
                              llama.cpp in Docker, bound to 127.0.0.1:8000
                              GGUF on /opt/models (EBS)
```

Two deliberate properties:

- **llama-server never listens on a public interface.** The container publishes
  to `127.0.0.1:8000` on the host, and the only inbound security-group rule is
  SSH from one operator IP. There is no API key on the server, so this matters.
- **Weights live on EBS**, so a stop/start takes a few minutes to serve instead
  of re-downloading 29 GB.

## The as-built resources

Defaults target `eu-north-1`. The first as-built host was in `eu-central-1`
and is torn down; the values below describe the shape of the stack, not IDs
to reuse.

| Resource | Value | Notes for the rebuild |
|---|---|---|
| Instance | `g6e.xlarge`, x86_64 | 4 vCPU, 1x L40S 48 GB. Public IP changes on stop/start; no Elastic IP by default. |
| AMI | "Deep Learning Base OSS Nvidia Driver GPU AMI (Ubuntu 24.04)", owner `898082745236` | **Look it up by name, never reuse an ID** (region- and release-specific). |
| OS / driver / docker | Ubuntu 24.04.4 LTS, NVIDIA 595.91.07, Docker 29.7.2 | All preinstalled by the DLAMI |
| Root volume | 100 GB gp3 (3000 IOPS / **625 MB/s**), **encrypted**, `/dev/sda1` | GGUF is 29 GB. 625 MB/s is the g6e.xlarge EBS cap. |
| VPC / subnet | the default VPC and its default subnets | In `eu-north-1`, `g6e.xlarge` is offered in `eu-north-1a` and `eu-north-1b` only. |
| Security group | `qwen3-inference-sg` | Ingress: TCP 22 from `<operator-ip>/32` only. Egress: all. **Port 8000 is never opened.** |
| Key pair | `qwen3-inference-key`, ed25519 | Private key expected at `~/.ssh/id_ed25519` |
| IAM | role `qwen3-inference-role`, profile `qwen3-inference-profile` | Exactly one managed policy: `AmazonSSMManagedInstanceCore`. Needed for the keyless SSM tunnel path. |
| Elastic IP | none | Address changes on each start unless you re-run `provision.sh --with-eip` |
| IMDS | IMDSv2 required, hop limit 2 | Hop limit 2 so containers can reach IMDS |
| Tags | `Name=qwen3-inference`, `Owner=<you>`, `Purpose=qwen3.8-27b-q8-gguf` | |

## Rebuild in a new account

### 0. Check the GPU quota first

**This is the step that blocks people for days.** New accounts have a zero quota
for G instances, and `g6e.xlarge` needs 4 vCPUs of it.

```sh
aws service-quotas get-service-quota --service-code ec2 \
  --quota-code L-DB2E81BA --region <region>   # Running On-Demand G and VR instances
```

If `Value` is less than 4, request an increase (Service Quotas console, or
`request-service-quota-increase`) and wait for approval before continuing.
Approval is usually hours to days, and is per-region.

### 1. Set your variables

```sh
export AWS_REGION=eu-north-1
export NAME=qwen3-inference
export MY_IP=$(curl -fsS https://checkip.amazonaws.com | tr -d '[:space:]')
```

### 2. Key pair

Either import the existing public key (keeps `~/.ssh/id_ed25519` working):

```sh
aws ec2 import-key-pair --key-name "$NAME-key" \
  --public-key-material "fileb://$HOME/.ssh/id_ed25519.pub"
```

Or create a fresh one and point `SSH_KEY` in `qwen-ec2` at it:

```sh
aws ec2 create-key-pair --key-name "$NAME-key" --key-type ed25519 \
  --query KeyMaterial --output text > ~/.ssh/"$NAME"-key.pem
chmod 600 ~/.ssh/"$NAME"-key.pem
```

### 3. Security group

```sh
VPC=$(aws ec2 describe-vpcs --filters Name=isDefault,Values=true \
  --query 'Vpcs[0].VpcId' --output text)

SG=$(aws ec2 create-security-group --group-name "$NAME-sg" \
  --description "Qwen3.8 llama.cpp inference host - SSH from operator IP only" \
  --vpc-id "$VPC" --query GroupId --output text)

aws ec2 authorize-security-group-ingress --group-id "$SG" \
  --ip-permissions "IpProtocol=tcp,FromPort=22,ToPort=22,IpRanges=[{CidrIp=$MY_IP/32,Description='operator laptop'}]"
```

Do **not** open 8000. The tunnel is the access path.

### 4. IAM role and instance profile

```sh
aws iam create-role --role-name "$NAME-role" --assume-role-policy-document '{
  "Version":"2012-10-17",
  "Statement":[{"Effect":"Allow","Principal":{"Service":"ec2.amazonaws.com"},"Action":"sts:AssumeRole"}]}'

aws iam attach-role-policy --role-name "$NAME-role" \
  --policy-arn arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore

aws iam create-instance-profile --instance-profile-name "$NAME-profile"
aws iam add-role-to-instance-profile --instance-profile-name "$NAME-profile" \
  --role-name "$NAME-role"
```

### 5. Launch

Resolve the AMI by name rather than hardcoding an ID:

```sh
AMI=$(aws ec2 describe-images --owners 898082745236 \
  --filters 'Name=name,Values=Deep Learning Base OSS Nvidia Driver GPU AMI (Ubuntu 24.04)*' \
  --query 'sort_by(Images,&CreationDate)[-1].ImageId' --output text)

SUBNET=$(aws ec2 describe-subnets --filters "Name=vpc-id,Values=$VPC" \
  --query 'Subnets[0].SubnetId' --output text)

aws ec2 run-instances \
  --image-id "$AMI" \
  --instance-type g6e.xlarge \
  --key-name "$NAME-key" \
  --security-group-ids "$SG" \
  --subnet-id "$SUBNET" \
  --associate-public-ip-address \
  --iam-instance-profile Name="$NAME-profile" \
  --metadata-options 'HttpTokens=required,HttpPutResponseHopLimit=2,HttpEndpoint=enabled' \
  --block-device-mappings '[{"DeviceName":"/dev/sda1","Ebs":{"VolumeSize":100,"VolumeType":"gp3","Throughput":625,"Encrypted":true,"DeleteOnTermination":true}}]' \
  --user-data file://user-data.sh \
  --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=$NAME},{Key=Owner,Value=$USER},{Key=Purpose,Value=qwen3.8-27b-q8-gguf}]" \
  --query 'Instances[0].InstanceId' --output text
```

`/dev/sda1` is the correct root device name for this Ubuntu DLAMI. Using
`/dev/xvda` silently creates a second, unused volume.

### 6. Optional Elastic IP

```sh
ALLOC=$(aws ec2 allocate-address --domain vpc --query AllocationId --output text)
aws ec2 associate-address --instance-id <instance-id> --allocation-id "$ALLOC"
```

Worth it only if you dislike editing `qwen-ec2` after every start. An unattached
EIP bills ~$3.6/mo.

### 7. Watch the first boot

First boot downloads ~29 GB, so allow ~20 min. Later boots serve in a few
minutes. `provision.sh` / `qwen-ec2 start` also scp `chat_template.jinja`
(user-data cannot carry it: 16 KB cap).

```sh
ssh ubuntu@<ip> 'sudo tail -f /var/log/qwen-bootstrap.log'   # provisioning
ssh ubuntu@<ip> 'sudo journalctl -u llama -f'                # server
ssh ubuntu@<ip> 'curl -fsS localhost:8000/health'            # readiness
```

`touch /var/lib/cloud/qwen-bootstrap-done` is the completion marker.

### 8. Point the client at it

Edit `~/bin/qwen-ec2` and update the four hardcoded values at the top:

```sh
INSTANCE_ID="i-..."          # new instance
ELASTIC_IP="..."             # new EIP, or drop the reference
AWS_REGION="${AWS_REGION:-eu-north-1}"
HOURLY_USD="1.974"           # re-check for the new region
```

Then:

```sh
qwen-ec2 bootstrap    # SSM plugin + opencode + provider config (no sudo needed)
qwen-ec2 up           # start + supervised tunnel
qwen-ec2 status       # instance, llama-server health, tunnel state, hourly cost
qwen-ec2 code         # Claude Code against the local model
```

Install `ccr` and drop `ccr-config.json` at `~/.claude-code-router/config.json`:

```sh
npm install -g @musistudio/claude-code-router
```

## Chat template

Stock Qwen3.8 Jinja raises `System message must be at the beginning` when
Claude Code (via ccr) sends a second `system` turn. We vendor
froggeric/Qwen-Fixed-Chat-Templates v22.3 as `chat_template.jinja` and scp it
on start. Do not launch with the GGUF's own template.

If you change the systemd unit by hand, write the change back into
`llama.service` and `user-data.sh`.

## Key llama-server flags and why

| Flag | Why |
|---|---|
| `--alias qwen3.8-27b` | The name ccr asks for; decouples the client from the GGUF filename |
| `--ctx-size 262144` | Full native window; q8_0 KV (~25 GB) fits next to 29 GB weights on the 48 GB L40S with a little spill to 30 GiB RAM |
| `--cache-type-k/v q8_0` | Quantized KV so 256k fits next to 29 GB weights on 48 GB |
| `--flash-attn on` | Decode path; do not leave on auto |
| `--parallel 1` | One Operator, one conversation; the whole context is one slot |
| `--spec-type draft-mtp --spec-draft-n-max 1` | Fused MTP; n_max 1 is the fastest point on Coletti's tables |
| `--jinja --chat-template-file …` | Patched template; stock file 500s Claude Code |
| `--reasoning-format deepseek` | Thinking goes to `reasoning_content`, not the tool-call stream |
| `--chat-template-kwargs medium` | Thinking on, not Qwen's xhigh (burns the 8192 output budget) |
| `--cache-prompt --cache-reuse 256` | Prefix cache for agent turns |
| `-p 127.0.0.1:8000:8000` | Loopback only. This is the security boundary. |
| mmap (default) | 32 GiB host RAM, 29 GB GGUF. Never `--no-mmap` / `--mlock`. |

## Teardown

```sh
qwen-ec2 down                                              # tunnel + stop
aws ec2 terminate-instances --instance-ids <id>
aws ec2 release-address --allocation-id <alloc>             # else it bills forever
aws iam remove-role-from-instance-profile --instance-profile-name "$NAME-profile" --role-name "$NAME-role"
aws iam delete-instance-profile --instance-profile-name "$NAME-profile"
aws iam detach-role-policy --role-name "$NAME-role" --policy-arn arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore
aws iam delete-role --role-name "$NAME-role"
aws ec2 delete-security-group --group-id <sg>
aws ec2 delete-key-pair --key-name "$NAME-key"
```

The root volume has `DeleteOnTermination=true`, so it goes with the instance.
Releasing the EIP is the one people forget.

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| Claude Code: `500` / `TypeError: fetch failed`, retrying | ccr's upstream refused: `connect ECONNREFUSED 127.0.0.1:8000`. Tunnel is down. | `qwen-ec2 tunnel-bg`. `qwen-ec2 code` now preflights this automatically. |
| Claude Code: `Waiting for API response ... check your network` | Same as above. The message is misleading; it is never the network. | Check `~/.claude-code-router/logs/` for the real error |
| `qwen-ec2 status` claims the tunnel is up but nothing works | Was a stale pidfile. Fixed: status now health-probes the port and verifies the PID's command line. | |
| Tunnel dies after laptop sleep or an IP change | `ssh -f -N` is unsupervised. Fixed: `tunnel-bg` runs a reconnect loop (`ServerAliveInterval=15`, `ServerAliveCountMax=3`). | `tail ~/.qwen-ec2-tunnel.log` |
| SSH times out after moving networks | Home IP changed; the SG pins one `/32` | Fixed: the tunnel supervisor re-syncs the SG on reconnect (at most once per `TUNNEL_SG_SYNC_INTERVAL`, default 60s). `qwen-ec2 start` still forces it; `qwen-ec2 tunnel-ssm` needs no ingress at all |
| `500 fetch failed` while the instance is `running` and `llama` reads "not responding" | Reconnect loop was spinning against closed ingress, so nothing served port 8000 | Fixed: `status` now distinguishes "cannot reach the host over SSH" and prints the SG/your-IP mismatch |
| Everything hangs on a fresh launch | Still downloading 29 GB, or `chat_template.jinja` not on the box yet | `qwen-ec2 boot-log`; from the repo laptop, `qwen-ec2 start` scp's the template |
| Claude Code 500: `System message must be at the beginning` | Stock Qwen3.8 template | Confirm `/opt/models/chat_template.jinja` is froggeric v22.3 |
| `InsufficientInstanceCapacity` | No `g6e` capacity in that AZ | `provision.sh` retries every default-VPC AZ. If all fail, try another region (`AWS_REGION=...`) |
| `VcpuLimitExceeded` | GPU quota not raised | See step 0 |

### Reading the real error

ccr logs every request to `~/.claude-code-router/logs/ccr-<timestamp>.log`. The
files are large and one line per SSE token, so filter:

```sh
f=$(ls -t ~/.claude-code-router/logs/*.log | head -1)
grep -aoE '\{"level":(40|50)[^\n]{0,300}' "$f" | tail            # errors
grep -ao '"statusCode":[0-9]*},"responseTime":[0-9.]*' "$f" | tail  # outcomes
```

Do not grep for `timeout`: the word appears in the Bash tool's schema, so it
matches on every healthy request.

## Client-side notes

- `API_TIMEOUT_MS: 1200000` (20 min) in the ccr config. Observed request times
  ran 1s to 56s, so the generous ceiling is about long agentic turns, not the
  model being slow.
- Sampling is pinned client-side (`temperature 1.0`, `top_p 0.95`, `top_k 20`,
  `max_tokens 8192`), the Qwen3.8 thinking-mode set. Do not reuse Qwen3's 0.6.
- `ENABLE_CLAUDEAI_MCP_SERVERS=0` is set by `qwen-ec2 code` to suppress a
  misleading connector warning. claude.ai connectors genuinely cannot work
  against a non-Anthropic backend, so this states the truth rather than hiding
  a problem. It is scoped to that command, so plain `claude` is unaffected.
- `qwen-ec2 code` passes `--dangerously-skip-permissions`. Note that
  `--allow-dangerously-skip-permissions` is a *different* flag that only makes
  bypass available without enabling it, leaving the session in manual mode.
- `qwen-ec2 bootstrap` also installs `opencode` as an alternative client, with
  its own provider config at `~/.config/opencode/opencode.json`.
