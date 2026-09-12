# qwen-ec2

A single-operator inference host that serves one local coding model to the operator's coding agents over a tunnel.

## Language

**Inference Host**:
The single EC2 GPU machine that loads the Served Model and exposes an API on loopback only.
_Avoid_: server, box, GPU (those are the machine, the hardware, or the process — not this role)

**Tunnel**:
The SSH or SSM port-forward that makes the Inference Host's loopback API appear on the operator laptop.
_Avoid_: VPN, public endpoint, API gateway

**Served Model**:
DavidAU's Qwen3.8-27B TURBO-Fable-Cold-Fusion-735-882-Heretic-Uncensored-NEO-CODER-MAX (MTP) at Q8_0 GGUF (`Qwen3.8-27B-TurboFCFusion-735-882-Here-Uncen-NEO-CODER-MAX-MTP-Q8_0.gguf`, ~30 GB fused). A multi-stage fusion of Fable-Fusion-711-Uncensored-Heretic and Cold-Fusion-GAIN-V1.1 with Heretic de-censoring applied post-merge. This replaced JonathanColetti's Heretic-abliterated Qwen3.8-27B Uncensored (which itself replaced Qwen3-32B-FP8).
_Avoid_: Qwen3-32B, FP8, "the 8-bit model" (FP8 was also 8-bit), Qwen 3.8 as a cloud product, Coletti (that was the prior fine-tune)

**Uncensored**:
Refusal-reduced in two stages: 99/100 → 0/100 (KL 0.0535), then 11/100 (KL 0.0025), against the base Qwen3.8-27B. Refusals are reduced, not eliminated. DavidAU claims accuracy improved, not degraded, over the base model (735 ARC-C / 882 ARC-E vs. 591 ARC-C base, 8-bit).
_Avoid_: unrestricted, jailbroken, unfiltered, "no safety"

**Coding Agent**:
Claude Code (via the Router) or OpenCode, consuming the Served Model as the LLM backend. This is the job of the stack.
_Avoid_: chatbot, playground, LM Studio (those are other jobs)

**Router**:
The process on the Operator laptop that translates Claude Code's Anthropic traffic into the Inference Host's OpenAI-compatible API. OpenCode does not use it.
_Avoid_: proxy, gateway, ccr (that's the current program, not the role)

**Operator**:
The one person allowed to reach the Inference Host. Their laptop IP is the only ingress.
_Avoid_: user, client, customer

**Reasoning**:
Thinking is on at medium effort for every Coding Agent turn. Sampler is the thinking set (temperature 1.0, top_p 0.95, top_k 20), output cap 8192.
_Avoid_: xhigh (Qwen's card default; burns the output budget), thinking off, Qwen3's temperature 0.6
