"""llm-gateway -- OpenAI-compatible front door for the Strix Halo LLM cluster.

Canonical editable source deployed by setup-strixhalo-ai-server.sh.

Request path:
    client -> gateway -> residencyd (unix socket) -> vLLM (loopback or USB4)

The gateway never starts, stops or chooses models. It asks residencyd for a
lease, gets told which backend now holds the model, proxies the request there,
and returns the lease afterwards. If the cluster has no room, residencyd
answers 409 and that 409 is relayed to the caller verbatim -- an honest refusal
is far more useful to a client than a request that hangs for ten minutes.
"""
import asyncio
import os
import sys
import time

import httpx
from fastapi import FastAPI, Request, Response
from fastapi.responses import JSONResponse, StreamingResponse

SOCK = os.environ.get("RESIDENCY_SOCK", "/run/residencyd/control.sock")
LOAD_TIMEOUT = float(os.environ.get("RESIDENCY_LOAD_TIMEOUT", "1800"))
VERSION = "1"

app = FastAPI(title="llm-gateway", version=VERSION, docs_url=None, redoc_url=None)

# residencyd speaks HTTP over a unix socket, so the host part of the URL is a
# placeholder that httpx requires but never resolves.
_ctl_transport = httpx.AsyncHTTPTransport(uds=SOCK, retries=1)
_ctl = httpx.AsyncClient(
    transport=_ctl_transport,
    base_url="http://residencyd",
    # /acquire blocks for the whole cold start, so this must outlast it.
    timeout=httpx.Timeout(LOAD_TIMEOUT + 60.0, connect=10.0),
)
# Upstream vLLM: no read timeout at all. A long generation is not a failure,
# and a proxy that gives up on a slow token stream is worse than useless.
_up = httpx.AsyncClient(
    timeout=httpx.Timeout(None, connect=15.0),
    limits=httpx.Limits(max_connections=64, max_keepalive_connections=16),
)

# Leases the gateway currently holds, so a crash-free shutdown does not pin a
# model resident forever.
_open_leases = set()
_leases_lock = asyncio.Lock()


def _err(message, code, etype="cluster_error", status=502, param=None):
    return JSONResponse(
        {"error": {"message": message, "type": etype, "param": param, "code": code}},
        status_code=status,
    )


UNREACHABLE = _err(
    "[residencyd_unavailable] The cluster control plane is not responding. "
    "Check 'systemctl status residencyd' on the head node.",
    "residencyd_unavailable",
    status=503,
)


async def _release(lease):
    async with _leases_lock:
        _open_leases.discard(lease)
    try:
        await _ctl.post("/release", json={"lease": lease})
    except Exception:      # noqa: BLE001  - a lost release must never surface
        pass               #                to the client; the reaper covers it.


async def _report_dead(model, lease):
    """The backend accepted a lease but will not answer.

    residencyd still believes the model is healthy, and because every failed
    attempt refreshes its idle timer the LRU reaper would never clean it up
    either - so it would answer 'ready' forever while serving nothing. Release
    the lease first, then force it unloaded so the next request cold-starts it.
    """
    await _release(lease)
    try:
        await _ctl.post("/unload", json={"model": model, "force": True})
        print("gateway: marked %s unloaded, backend did not answer" % model,
              file=sys.stderr, flush=True)
    except Exception:      # noqa: BLE001
        pass


@app.on_event("shutdown")
async def _drain():
    async with _leases_lock:
        leases = list(_open_leases)
        _open_leases.clear()
    for lease in leases:
        try:
            await _ctl.post("/release", json={"lease": lease})
        except Exception:  # noqa: BLE001
            pass
    await _up.aclose()
    await _ctl.aclose()


# --------------------------------------------------------------------- health
@app.get("/health")
async def health():
    try:
        r = await _ctl.get("/health", timeout=5.0)
        return JSONResponse({"gateway": "ok", "residencyd": r.json()},
                            status_code=200 if r.status_code == 200 else 503)
    except Exception as exc:            # noqa: BLE001
        return JSONResponse({"gateway": "ok", "residencyd": "unreachable",
                             "detail": str(exc)}, status_code=503)


# --------------------------------------------------------------------- models
@app.get("/v1/models")
async def list_models():
    """Every catalogued model, resident or not.

    Clients use this to populate a model picker, so hiding cold models would
    make most of the cluster invisible. The extra non-standard fields are
    additive and ignored by strict OpenAI clients.
    """
    try:
        r = await _ctl.get("/catalog", timeout=15.0)
    except Exception:                   # noqa: BLE001
        return UNREACHABLE
    if r.status_code != 200:
        return JSONResponse(r.json(), status_code=r.status_code)
    cat = r.json()
    now = int(time.time())
    data = []
    for m in cat.get("data", []):
        if not m.get("enabled", True):
            continue
        data.append({
            "id": m["id"],
            "object": "model",
            "created": now,
            "owned_by": "strixhalo-cluster",
            # --- cluster extensions -------------------------------------
            "state": m.get("state"),
            "placement": m.get("placement"),
            "node": m.get("node"),
            "tensor_parallel": m.get("tensor_parallel"),
            "budget_gib": m.get("budget_gib"),
            "keep_warm": m.get("keep_warm"),
            # IDE clients size their prompt budget from this. Reporting the
            # configured cap (rather than the checkpoint's native window) is
            # what stops a client from building a request the engine will
            # refuse. Several clients look for either spelling.
            "max_model_len": m.get("max_model_len"),
            "context_length": m.get("max_model_len"),
        })
    return {"object": "list", "data": data}


@app.get("/cluster/catalog")
async def cluster_catalog():
    """Full residencyd view: per-node budgets, states, leases, last errors."""
    try:
        r = await _ctl.get("/catalog", timeout=15.0)
    except Exception:                   # noqa: BLE001
        return UNREACHABLE
    return JSONResponse(r.json(), status_code=r.status_code)


@app.post("/cluster/unload")
async def cluster_unload(request: Request):
    try:
        body = await request.json()
    except Exception:                   # noqa: BLE001
        return _err("a JSON body with 'model' is required", "invalid_body",
                    "invalid_request_error", 400, "model")
    try:
        r = await _ctl.post("/unload", json=body, timeout=180.0)
    except Exception:                   # noqa: BLE001
        return UNREACHABLE
    return JSONResponse(r.json(), status_code=r.status_code)


@app.post("/cluster/reload")
async def cluster_reload():
    try:
        r = await _ctl.post("/reload", json={}, timeout=30.0)
    except Exception:                   # noqa: BLE001
        return UNREACHABLE
    return JSONResponse(r.json(), status_code=r.status_code)


@app.post("/cluster/models/add")
async def cluster_models_add(request: Request):
    """Register a new catalog entry. residencyd shells out to the real
    'llm-model add' (name validation, port picking, budget defaulting and the
    distributed auto-placement math all live there, and only there) then
    reloads its own catalog before replying, so the model is already visible
    in /cluster/catalog by the time this call returns."""
    try:
        body = await request.json()
    except Exception:                   # noqa: BLE001
        return _err("a JSON body with at least 'name' and 'path' is required",
                    "invalid_body", "invalid_request_error", 400)
    try:
        r = await _ctl.post("/models/add", json=body, timeout=60.0)
    except Exception:                   # noqa: BLE001
        return UNREACHABLE
    return JSONResponse(r.json(), status_code=r.status_code)


@app.post("/cluster/models/delete")
async def cluster_models_delete(request: Request):
    """Stop (if resident) and remove a catalog entry via 'llm-model remove'."""
    try:
        body = await request.json()
    except Exception:                   # noqa: BLE001
        return _err("a JSON body with 'name' is required", "invalid_body",
                    "invalid_request_error", 400, "name")
    try:
        r = await _ctl.post("/models/delete", json=body, timeout=60.0)
    except Exception:                   # noqa: BLE001
        return UNREACHABLE
    return JSONResponse(r.json(), status_code=r.status_code)


@app.post("/cluster/models/edit")
async def cluster_models_edit(request: Request):
    """Save the per-model editable-fields form. residencyd shells out to the
    real 'llm-model set' (same validation/auto-distribute self-heal 'add'
    runs) then reloads its own catalog before replying."""
    try:
        body = await request.json()
    except Exception:                   # noqa: BLE001
        return _err("a JSON body with at least 'name' is required",
                    "invalid_body", "invalid_request_error", 400)
    try:
        r = await _ctl.post("/models/edit", json=body, timeout=60.0)
    except Exception:                   # noqa: BLE001
        return UNREACHABLE
    return JSONResponse(r.json(), status_code=r.status_code)


@app.get("/cluster/models/conf")
async def cluster_models_conf(name: str):
    """Raw .conf fields for the dashboard's editable-fields form."""
    try:
        r = await _ctl.get("/models/conf", params={"name": name}, timeout=15.0)
    except Exception:                   # noqa: BLE001
        return UNREACHABLE
    return JSONResponse(r.json(), status_code=r.status_code)


@app.post("/cluster/models/load")
async def cluster_models_load(request: Request):
    """Force-load a model with no caller-facing lease -- the dashboard's Force
    load button. Can legitimately block for minutes on a cold start, exactly
    like a real /v1/chat/completions request would; no explicit timeout here
    so this inherits _ctl's client-level LOAD_TIMEOUT-based default."""
    try:
        body = await request.json()
    except Exception:                   # noqa: BLE001
        return _err("a JSON body with 'name' is required", "invalid_body",
                    "invalid_request_error", 400, "name")
    try:
        r = await _ctl.post("/models/load", json=body)
    except Exception:                   # noqa: BLE001
        return UNREACHABLE
    return JSONResponse(r.json(), status_code=r.status_code)


@app.get("/cluster/models/log")
async def cluster_models_log(name: str, minutes: float = 5):
    """Tail vllm@<name>.service on both nodes (see residencyd.model_log)."""
    try:
        r = await _ctl.get("/models/log", params={"name": name, "minutes": minutes},
                           timeout=30.0)
    except Exception:                   # noqa: BLE001
        return UNREACHABLE
    return JSONResponse(r.json(), status_code=r.status_code)


@app.get("/cluster/models/progress")
async def cluster_models_progress(name: str, minutes: float = 5):
    """Live model operation state plus bounded residency/vLLM journal tails."""
    try:
        r = await _ctl.get("/models/progress",
                           params={"name": name, "minutes": minutes},
                           timeout=30.0)
    except Exception:                   # noqa: BLE001
        return UNREACHABLE
    return JSONResponse(r.json(), status_code=r.status_code)


@app.post("/cluster/models/pull")
async def cluster_models_pull(request: Request):
    """Start a Hugging Face/ModelScope download-and-add job. residencyd
    launches it as a transient systemd unit and returns almost immediately;
    409 if one is already running (only one download at a time)."""
    try:
        body = await request.json()
    except Exception:                   # noqa: BLE001
        return _err("a JSON body with 'source' and 'repo' is required",
                    "invalid_body", "invalid_request_error", 400)
    try:
        r = await _ctl.post("/models/pull", json=body, timeout=30.0)
    except Exception:                   # noqa: BLE001
        return UNREACHABLE
    return JSONResponse(r.json(), status_code=r.status_code)


@app.get("/cluster/models/pull/status")
async def cluster_models_pull_status():
    try:
        r = await _ctl.get("/models/pull/status", timeout=15.0)
    except Exception:                   # noqa: BLE001
        return UNREACHABLE
    return JSONResponse(r.json(), status_code=r.status_code)


@app.get("/cluster/models/pull/log")
async def cluster_models_pull_log(minutes: float = 5):
    try:
        r = await _ctl.get("/models/pull/log", params={"minutes": minutes}, timeout=15.0)
    except Exception:                   # noqa: BLE001
        return UNREACHABLE
    return JSONResponse(r.json(), status_code=r.status_code)


# ---------------------------------------------------------------- inference
HOP_BY_HOP = {"connection", "keep-alive", "proxy-authenticate",
              "proxy-authorization", "te", "trailers",
              "transfer-encoding", "upgrade", "content-length",
              "content-encoding"}


async def _proxy(request: Request, path: str):
    try:
        body = await request.json()
    except Exception:                   # noqa: BLE001
        return _err("request body must be JSON", "invalid_body",
                    "invalid_request_error", 400)
    model = body.get("model")
    if not isinstance(model, str) or not model:
        return _err("a 'model' field is required", "missing_model",
                    "invalid_request_error", 400, "model")

    # --- lease -------------------------------------------------------------
    # This call is what loads the model, evicts something to make room, or
    # refuses. It can legitimately block for minutes on a cold start.
    try:
        r = await _ctl.post("/acquire", json={"model": model})
    except Exception:                   # noqa: BLE001
        return UNREACHABLE
    if r.status_code != 200:
        # 409 model_capacity_unavailable, 404 model_not_found, 503 load failure:
        # all relayed unchanged so the client sees the real reason.
        try:
            payload = r.json()
        except Exception:               # noqa: BLE001
            payload = {"error": {"message": r.text, "type": "cluster_error",
                                 "code": "residencyd_error"}}
        return JSONResponse(payload, status_code=r.status_code)

    info = r.json()
    lease = info["lease"]
    async with _leases_lock:
        _open_leases.add(lease)
    # vLLM only answers to the name it was served under, which is not
    # necessarily the catalog name the client asked for.
    body["model"] = info.get("served_name") or model
    url = info["backend"] + path
    stream = bool(body.get("stream"))

    if not stream:
        try:
            resp = await _up.post(url, json=body)
        except httpx.HTTPError as exc:
            await _report_dead(info.get("model") or model, lease)
            return _err("[backend_unreachable] %s did not answer: %s. It has "
                        "been unloaded; retry to cold-start it."
                        % (info["backend"], exc), "backend_unreachable",
                        status=502)
        await _release(lease)
        headers = {k: v for k, v in resp.headers.items()
                   if k.lower() not in HOP_BY_HOP}
        return Response(content=resp.content, status_code=resp.status_code,
                        headers=headers,
                        media_type=resp.headers.get("content-type"))

    # --- streaming ---------------------------------------------------------
    # The lease must outlive the response body, so it is released by the
    # generator's finally: -- which runs on normal completion AND when the
    # client hangs up mid-stream.
    try:
        req = _up.build_request("POST", url, json=body)
        resp = await _up.send(req, stream=True)
    except httpx.HTTPError as exc:
        await _report_dead(info.get("model") or model, lease)
        return _err("[backend_unreachable] %s did not answer: %s. It has been "
                    "unloaded; retry to cold-start it."
                    % (info["backend"], exc), "backend_unreachable", status=502)

    async def relay():
        try:
            async for chunk in resp.aiter_raw():
                yield chunk
        finally:
            await resp.aclose()
            await _release(lease)

    headers = {k: v for k, v in resp.headers.items()
               if k.lower() not in HOP_BY_HOP}
    return StreamingResponse(
        relay(), status_code=resp.status_code, headers=headers,
        media_type=resp.headers.get("content-type", "text/event-stream"),
    )


@app.post("/v1/chat/completions")
async def chat_completions(request: Request):
    return await _proxy(request, "/v1/chat/completions")


@app.post("/v1/completions")
async def completions(request: Request):
    return await _proxy(request, "/v1/completions")


@app.post("/v1/embeddings")
async def embeddings(request: Request):
    return await _proxy(request, "/v1/embeddings")


try:
    from dashboard import mount_dashboard
except ModuleNotFoundError as exc:
    if exc.name not in ("dashboard", "gradio"):
        raise
    print("gateway: dashboard unavailable (%s); /dashboard will not be mounted"
          % exc, file=sys.stderr, flush=True)
else:
    mount_dashboard(app, _ctl)
