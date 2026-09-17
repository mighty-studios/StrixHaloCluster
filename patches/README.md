# Vendored llama.cpp patches

This directory holds small, source patches applied to the pinned `llama.cpp`
checkout during `setup-qwen3d8.sh`'s build step. Patches are applied
automatically; nothing here needs to be run by hand.

## `llama-cpp-427291b-salvage-final-chat-parse.patch`

Targets commit `427291b5b34cd914a31b3fd3b61a68f6184f4b9f` (the commit pinned
by `LLAMA_CPP_COMMIT` in `setup-qwen3d8.sh`).

`llama-server`'s post-generation chat parser (`common_chat_peg_parse` in
`common/chat.cpp`) already has a graceful fallback that salvages whatever was
successfully parsed when a *partial* (streaming) parse fails to consume the
whole output. It does not apply that same fallback to a *final* parse: if the
grammar fails to consume 100% of the model's raw output, the server throws
and the request fails with HTTP 500 ("The model produced output that does
not match the expected ... format"). This is an open, unresolved upstream
generation bug ([ggml-org/llama.cpp#26381](https://github.com/ggml-org/llama.cpp/issues/26381),
[ggml-org/llama.cpp#20260](https://github.com/ggml-org/llama.cpp/issues/20260))
reproduced across ROCm, CUDA, and Vulkan backends.

The patch extends the existing partial-parse salvage path to final parses
too: whatever was successfully parsed is returned, with any unparsed
trailing text appended to the message content instead of being silently
dropped. This turns the hard crash into a degraded-but-successful response
for both the dashboard capacity test and normal production traffic.

If `LLAMA_CPP_COMMIT` is ever updated to a newer commit, re-check that this
patch still applies (`git apply --check`) and refresh the context lines if
upstream has changed the surrounding code.
