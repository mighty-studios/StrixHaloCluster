#!/usr/bin/env python3
"""llm-profile -- derive a vLLM catalog entry from a downloaded model directory.

Reads <model_dir>/config.json and prints shell-sourceable P_* KEY=VALUE lines
(or JSON with --format json) that 'llm-model pull' turns into an 'llm-model add'
invocation. Every ceiling errs low and is overridable: a wrong-high budget only
costs headroom, but a wrong-low one is what let concurrent loads freeze a node.
"""
import argparse
import glob
import json
import math
import os
import shlex
import sys

# Architectures whose attention is (partly) linear/stateful -- Mamba/GDN and
# friends. vLLM allocates their recurrent state per sequence, so an uncapped
# --max-num-seqs balloons memory; we cap it. Deliberately liberal: the cap is
# harmless on a model that did not actually need it.
HYBRID_MARKERS = (
    "mamba", "gdn", "gated_delta", "gateddelta", "linear_attn", "linearattention",
    "hybrid", "jamba", "zamba", "falcon_h", "falconh", "recurrentgemma", "griffin",
    "rwkv", "qwen3_next", "minimax_text", "minimaxtext", "plamo2", "nemotron_h",
    "nemotronh", "bamba", "granitemoehybrid", "lfm2",
)

# (substring in arch/model_type/name, tool-parser, reasoning-parser). First hit
# wins, so put the more specific markers first. These are only SUGGESTIONS:
# llm-model pull validates each against the installed vLLM before using them.
FAMILY_PARSERS = (
    ("qwen3_coder", "qwen3_coder", ""),
    ("qwen3_next", "hermes", "qwen3"),
    ("qwen3", "hermes", "qwen3"),
    ("qwen2", "hermes", ""),
    ("llama4", "pythonic", ""),
    ("llama", "llama3_json", ""),
    ("mixtral", "mistral", ""),
    ("ministral", "mistral", ""),
    ("mistral", "mistral", ""),
    ("deepseek", "deepseek_v3", "deepseek_r1"),
    ("glm4_moe", "glm45", "glm45"),
    ("glm4", "glm45", "glm45"),
    ("granite", "granite", "granite"),
    ("hermes", "hermes", ""),
)


def _lower_join(seq):
    return " ".join(str(x) for x in seq).lower()


def load_config(path):
    cfg_path = os.path.join(path, "config.json")
    if not os.path.isfile(cfg_path):
        sys.stderr.write("llm-profile: no config.json in %s\n" % path)
        sys.exit(2)
    with open(cfg_path, "r", encoding="utf-8") as fh:
        return json.load(fh)


def text_config(cfg):
    """Multimodal repos nest the language-model settings under text_config."""
    tc = cfg.get("text_config")
    return tc if isinstance(tc, dict) else cfg


def weights_gib(path):
    """Total on-disk size of the loadable weights, in GiB. Prefers safetensors;
    falls back to *.bin. When a repo ships BOTH sharded safetensors and a single
    consolidated.safetensors (Mistral does this), the consolidated copy is a
    duplicate -- drop it so the estimate is not doubled."""
    for ext in ("*.safetensors", "*.bin"):
        files = glob.glob(os.path.join(path, "**", ext), recursive=True)
        if not files:
            continue
        bases = [os.path.basename(f) for f in files]
        if any("-of-" in b for b in bases):
            files = [f for f in files
                     if not os.path.basename(f).startswith("consolidated")]
        total = sum(os.path.getsize(f) for f in files)
        return total / (2 ** 30)
    return 0.0


def detect_quant(cfg):
    qc = cfg.get("quantization_config")
    if not isinstance(qc, dict):
        return None
    method = (qc.get("quant_method") or qc.get("quantization") or "").lower()
    if not method and "config_groups" in qc:
        method = "compressed-tensors"
    return method or "unknown"


def detect_max_len(tc, cap):
    for key in ("max_position_embeddings", "model_max_length", "n_positions",
                "seq_length", "max_seq_len"):
        v = tc.get(key)
        try:
            v = int(v)
        except (TypeError, ValueError):
            continue
        if v > 0:
            return min(v, cap), v
    return None, None


def kv_floor_gib(tc, max_len):
    """Rough KV-cache size for ONE sequence at max_len (bf16). Used only as a
    lower bound on the memory headroom, so a small model with a long context
    still gets enough budget for its cache instead of just weights + 35%."""
    try:
        layers = int(tc.get("num_hidden_layers"))
        hidden = int(tc.get("hidden_size"))
        heads = int(tc.get("num_attention_heads"))
    except (TypeError, ValueError):
        return 0.0
    if layers <= 0 or hidden <= 0 or heads <= 0 or not max_len:
        return 0.0
    kv_heads = tc.get("num_key_value_heads", heads)
    try:
        kv_heads = int(kv_heads)
    except (TypeError, ValueError):
        kv_heads = heads
    head_dim = tc.get("head_dim") or (hidden / heads)
    try:
        head_dim = float(head_dim)
    except (TypeError, ValueError):
        head_dim = hidden / heads
    per_token = 2 * layers * kv_heads * head_dim * 2.0  # k+v, bf16
    return (per_token * max_len) / (2 ** 30)


def suggest_parsers(cfg, name):
    hay = "%s %s %s" % (_lower_join(cfg.get("architectures") or []),
                        str(cfg.get("model_type") or "").lower(),
                        (name or "").lower())
    for marker, tool, reason in FAMILY_PARSERS:
        if marker in hay:
            return tool, reason
    return "", ""


def is_hybrid(cfg):
    hay = "%s %s" % (_lower_join(cfg.get("architectures") or []),
                     str(cfg.get("model_type") or "").lower())
    return any(mk in hay for mk in HYBRID_MARKERS)


def main():
    ap = argparse.ArgumentParser(
        description="Profile a model directory into a vLLM catalog entry.")
    ap.add_argument("path", help="the downloaded model directory")
    ap.add_argument("--name", default="", help="catalog name (for parser hints)")
    ap.add_argument("--node-budget-gib", type=float,
                    default=float(os.environ.get("RESIDENCY_BUDGET_GIB") or 100),
                    help="per-node GPU-usable budget, for the distributed decision")
    ap.add_argument("--max-len-cap", type=int,
                    default=int(os.environ.get("LLM_MAX_LEN_CAP") or 32768))
    ap.add_argument("--hybrid-max-seqs", type=int,
                    default=int(os.environ.get("LLM_HYBRID_MAX_SEQS") or 64))
    ap.add_argument("--format", choices=("shell", "json"), default="shell")
    args = ap.parse_args()

    cfg = load_config(args.path)
    tc = text_config(cfg)
    weights = weights_gib(args.path)
    if weights <= 0:
        sys.stderr.write(
            "llm-profile: no safetensors/bin weights in %s "
            "(a GGUF-only repo cannot be served by vLLM)\n" % args.path)
        sys.exit(3)

    notes = []
    arch = (cfg.get("architectures") or ["?"])[0]

    quant = detect_quant(cfg)
    if quant:
        notes.append("quantized (%s); vLLM auto-detects it, not forcing --quantization" % quant)

    max_len, native = detect_max_len(tc, args.max_len_cap)
    if native and max_len and native > max_len:
        notes.append("context capped %d -> %d (raise with --max-len)" % (native, max_len))

    hybrid = is_hybrid(cfg)
    extra = ""
    if hybrid:
        extra = "--max-num-seqs %d" % args.hybrid_max_seqs
        notes.append("hybrid/linear-attention arch: capping --max-num-seqs at %d"
                     % args.hybrid_max_seqs)

    kvf = kv_floor_gib(tc, max_len or 0)
    node = args.node_budget_gib
    single = math.ceil(weights + max(0.35 * weights, kvf * 4.0, 8.0))

    if single <= node:
        placement, tp, pp, budget = "auto", 1, 1, single
    else:
        half = weights / 2.0
        per_node = math.ceil(half + max(0.30 * half, kvf * 2.0, 6.0))
        placement, tp, pp, budget = "distributed", 1, 2, per_node
        notes.append("too large for one node (~%d GiB > %d): PP=2 across both nodes, "
                     "~%d GiB/node" % (single, int(node), per_node))
        if per_node > node:
            notes.append("WARNING even a 2-way split needs ~%d GiB/node but a node holds %d"
                         % (per_node, int(node)))

    tool, reason = suggest_parsers(cfg, args.name)

    out = [
        ("P_ARCH", arch),
        ("P_WEIGHTS_GIB", str(int(math.ceil(weights)))),
        ("P_BUDGET_GIB", str(int(budget))),
        ("P_MAX_MODEL_LEN", str(max_len) if max_len else ""),
        ("P_QUANT", ""),  # left blank: vLLM auto-detects from config (see notes)
        ("P_PLACEMENT", placement),
        ("P_TP", str(tp)),
        ("P_PP", str(pp)),
        ("P_EXTRA_ARGS", extra),
        ("P_TOOL_PARSER", tool),
        ("P_REASONING_PARSER", reason),
        ("P_HYBRID", "1" if hybrid else "0"),
        ("P_NOTES", " | ".join(notes)),
    ]

    if args.format == "json":
        print(json.dumps(dict(out), indent=2))
    else:
        for key, val in out:
            print("%s=%s" % (key, shlex.quote(val)))


if __name__ == "__main__":
    main()
