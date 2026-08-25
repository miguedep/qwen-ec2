# Serve the Uncensored Q8_0 GGUF with llama.cpp, not vLLM

The stack's job is a Coding Agent on one L40S. We are replacing Qwen3-32B-FP8 (Hugging Face weights, vLLM, hermes tool parser) with the Coletti Qwen3.8-27B Uncensored Q8_0 GGUF. vLLM is second-class for GGUF and would throw away the fused MTP draft head this file was built to keep. llama.cpp is the native GGUF engine, supports `--spec-type draft-mtp`, and still speaks OpenAI-compatible HTTP so the Tunnel and Coding Agent clients can stay.

vLLM-on-HF-uncensored-weights was the alternative that would have kept the old unit and parsers. We rejected it because the chosen artifact is the 29 GB GGUF, not the bf16 Hugging Face checkpoint.
