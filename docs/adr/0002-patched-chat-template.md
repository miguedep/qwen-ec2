# Vendor froggeric's Qwen 3.8 chat template, not the GGUF's

Claude Code (via the Router) sends extra `system` turns. Qwen3.8's stock Jinja raises `System message must be at the beginning` on the second one, so `qwen-ec2 code` 500s. We ship froggeric/Qwen-Fixed-Chat-Templates v22.3 (`chat_template.jinja`) and run llama-server with `--jinja --chat-template-file --reasoning-format deepseek`.

That file renders later system turns in place (prefix cache stays intact), maps Claude Code effort aliases, accepts OpenAI stringified tool arguments, and defaults Reasoning to medium. We rejected a four-line patch of Coletti's template because it would still carry Qwen's xhigh default and the official `enable_thinking=false` crash. We rejected llama.cpp-only forks of the same work to avoid tracking a second moving file.
