# Vendored llama.cpp patches

This directory holds small, source patches applied to the pinned `llama.cpp`
checkout during `setup-qwen3d8.sh`'s build step. Patches are applied
automatically; nothing here needs to be run by hand.

## `llama-cpp-427291b-salvage-final-chat-parse.patch`

Targets commit `427291b5b34cd914a31b3fd3b61a68f6184f4b9f` (the commit pinned
by `LLAMA_CPP_COMMIT` in `setup-qwen3d8.sh`).

`llama-server`'s post-generation chat parser (`common_chat_peg_parse` in
`common/chat.cpp`) already has a graceful fallback that salvages whatever was
successfully parsed when a *partial* (streaming) parse fails partway through
the output. It does not apply any such fallback to a *final* (non-streaming)
parse: if the grammar fails to consume 100% of the model's raw output, the
server throws and the request fails with HTTP 500 ("The model produced
output that does not match the expected ... format"), even when the parser
made no progress at all (the output was unparseable from the very first
byte). This is an open, unresolved upstream generation bug
([ggml-org/llama.cpp#26381](https://github.com/ggml-org/llama.cpp/issues/26381),
[ggml-org/llama.cpp#20260](https://github.com/ggml-org/llama.cpp/issues/20260))
reproduced across ROCm, CUDA, and Vulkan backends, and observed on this
cluster at both very large (65536+ token) and moderate (16384 token) prompt
sizes, so it is not specific to the capacity test's synthetic workload size.

The patch makes a failed final parse unconditionally salvage instead of
throwing: whatever the AST captured (which may be nothing) is returned, with
any unparsed remainder (which may be the entire output) appended to the
message content instead of being silently dropped or crashing the request.
This turns the hard crash into a degraded-but-successful response for both
the dashboard capacity test and normal production traffic. The existing
partial (streaming) parse behavior is untouched.

If `LLAMA_CPP_COMMIT` is ever updated to a newer commit, re-check that this
patch still applies (`git apply --check`) and refresh the context lines if
upstream has changed the surrounding code.

## `llama-cpp-427291b-rpc-cache-weights-only.patch`

Targets commit `427291b5b34cd914a31b3fd3b61a68f6184f4b9f` (the commit pinned
by `LLAMA_CPP_COMMIT` in `setup-qwen3d8.sh`).

The pinned RPC backend's local cache path caches every RPC tensor transfer
larger than 10 MiB. During long capacity tests that includes compute-buffer
activation transfers, so enabling `ggml-rpc-server -c` can continuously write
new cache entries until the peer disk fills.

The patch ports the upstream behavior that uses the hash cache only for weight
buffers. That preserves the intended model-reload optimization while preventing
capacity-test activation traffic from flooding the RPC cache directory.
