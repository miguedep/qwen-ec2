#!/usr/bin/env python3
"""Benchmark llama.cpp tokens/sec against the qwen-ec2 OpenAI-compatible API.

Sends a streaming chat completion and measures two distinct speeds:

  * prefill  (time-to-first-token)  -> prompt tokens / s
  * decode   (steady-state)         -> generated tokens / s  <-- the headline number

Tokens are counted from the stream (chunk-level), so no tokenizer install is
needed. Prefill token count is estimated from the prompt; override with the
returned usage when the server provides it.

Usage:
  ./bench_tps.py                          # 1 run, default prompt, default endpoint
  ./bench_tps.py --runs 3 --max-tokens 2048
  ./bench_tps.py --prompt "write a haiku"
"""

import argparse
import json
import time
import urllib.request

DEFAULT_BASE = "http://127.0.0.1:8000/v1"
DEFAULT_MODEL = "qwen3.8-27b"
# Long-ish prompt so prefill is measurable and non-trivial.
DEFAULT_PROMPT = (
    "Explain, in plain English with a small worked example, how a transformer "
    "attention head computes its output from the query, key and value matrices. "
    "Include the softmax over the scaled dot products and the role of the "
    "head dimension. Then summarize in one sentence."
)


def stream_chat(base, model, prompt, max_tokens, temperature):
    """Send one streaming completion.

    Returns a dict with timings and token counts.
    """
    body = {
        "model": model,
        "messages": [{"role": "user", "content": prompt}],
        "max_tokens": max_tokens,
        "temperature": temperature,
        "stream": True,
    }
    req = urllib.request.Request(
        f"{base}/chat/completions",
        data=json.dumps(body).encode(),
        headers={"Content-Type": "application/json"},
        method="POST",
    )

    t_start = time.perf_counter()
    first_token_t = None
    n_tokens = 0
    usage = None

    with urllib.request.urlopen(req) as resp:
        for raw in resp:
            line = raw.decode().strip()
            if not line.startswith("data:"):
                continue
            payload = line[len("data:"):].strip()
            if payload == "[DONE]":
                break
            try:
                ev = json.loads(payload)
            except json.JSONDecodeError:
                continue
            if ev.get("usage"):
                usage = ev["usage"]
            choices = ev.get("choices") or []
            if not choices:
                continue
            delta = choices[0].get("delta") or {}
            # Count a token whenever the model emits content (or a role-only
            # chunk on the first delta, which we ignore).
            if delta.get("content") is not None or delta.get("reasoning_content"):
                if first_token_t is None:
                    first_token_t = time.perf_counter()
                n_tokens += 1

    t_end = time.perf_counter()
    return {
        "ttft": (first_token_t - t_start) if first_token_t else None,
        "total": t_end - t_start,
        "gen_time": (t_end - first_token_t) if first_token_t else 0.0,
        "n_tokens": n_tokens,
        "usage": usage,
    }


def main():
    p = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    p.add_argument("--model", default=DEFAULT_MODEL)
    p.add_argument("--prompt", default=DEFAULT_PROMPT, help="User prompt text")
    p.add_argument("--max-tokens", type=int, default=1024)
    p.add_argument("--temperature", type=float, default=0.0)
    p.add_argument("--runs", type=int, default=1, help="Number of runs (report best/avg)")
    args = p.parse_args()

    # Rough prompt token estimate (~4 chars/token) for prefill rate only.
    est_prompt_tokens = max(1, len(args.prompt) // 4)

    results = []
    for i in range(args.runs):
        print(f"run {i + 1}/{args.runs} ...", flush=True)
        r = stream_chat(DEFAULT_BASE, args.model, args.prompt,
                        args.max_tokens, args.temperature)
        results.append(r)

    # Decode tok/s
    def decode_tps(r):
        return r["n_tokens"] / r["gen_time"] if r["gen_time"] > 0 else 0.0

    # Prefill tok/s — use server-reported prompt tokens if present, else estimate.
    def prefill_tps(r):
        if r["ttft"] is None:
            return 0.0
        p_tok = (r["usage"] or {}).get("prompt_tokens") or est_prompt_tokens
        return p_tok / r["ttft"]

    print("\n" + "=" * 52)
    for i, r in enumerate(results):
        print(f"run {i + 1}: {r['n_tokens']} tokens, "
              f"TTFT {r['ttft']:.2f}s, gen {r['gen_time']:.2f}s")
    if len(results) > 1:
        best = max(results, key=decode_tps)
        avg = sum(decode_tps(r) for r in results) / len(results)
        print("-" * 52)
        print(f"decode   : {avg:8.2f} tok/s  (best {decode_tps(best):.2f} tok/s)")
        pavg = sum(prefill_tps(r) for r in results) / len(results)
        print(f"prefill  : {pavg:8.2f} tok/s  (TTFT ~{results[0]['ttft']:.2f}s)")
    else:
        r = results[0]
        print("-" * 52)
        print(f"decode   : {decode_tps(r):8.2f} tok/s")
        print(f"prefill  : {prefill_tps(r):8.2f} tok/s  (TTFT {r['ttft']:.2f}s)")
    print("=" * 52)


if __name__ == "__main__":
    main()
