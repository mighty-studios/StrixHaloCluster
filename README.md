# BOSGAME M5 DUAL CLUSTER AI SERVER
Setup scripts to install on two AMD Strix Halo 128gb PCS (Bosgame M5) to serve AI models on the local, trusted LAN for Windows 11 developers to access.

## Features

### vLLM + Ray + Open WebUI
- Multiple nodes connected through USB4NET
- Models hosted by vLLM
- Models distrubuted across nodes using Ray
- Model occupancy load balanced and managed by residencyd 
- Model files shared on a single SSD folder share via NFS
- Front-end provided by OpenWebUI
- Additional Gradio Dashboard to manage model catalog and use


Models that fit on one M5 can run locally on either node. Models requiring more memory can run across both nodes using vLLM + Ray + RCCL.

1. Final Architecture
                    Windows 11 LAN
                          │
             ┌────────────┴────────────┐
             │                         │
        Open WebUI              Copilot SDK Apps
             │                         │
             └────────────┬────────────┘
                          │
                    llm-gateway
                  M5-A LAN :8000
                          │
                    residencyd
                  Unix socket only
                          │
              ┌───────────┴───────────┐
              │                       │
             M5-A                    M5-B
       Ryzen AI Max+ 395       Ryzen AI Max+ 395
          128 GB UMA              128 GB UMA
              │                       │
              └══════ USB4NET ════════┘
                    10.44.0.0/30
                  Ray + RCCL + NFS


2. User-facing result
                 BOSGAME AI CLUSTER

Open WebUI ───────┐
                  │
Copilot SDK ──────┼──► llm-gateway
                  │         │
Other API apps ───┘         ▼
                       residencyd
                            │
                  ┌─────────┴─────────┐
                  ▼                   ▼
                M5-A ═══ USB4NET ═══ M5-B
                  │                   │
                  └──── vLLM/Ray ─────┘

### ComfyUI

- All models and downloads shared on a single SSD folder
    download once, use on any cluster node.
- Each cluster node provides a seperate ComfyUI server to use.
    allows parallel users

### Management

- Gradio Dashboard for vLLM model monitoring and maintenance
    simple fetch of new models from HuggingFave and ModelScope
    automatic catalog entries
    easy load/evict/add/delete controls
- Network Folder share on each node for file moving ('xfer' folders)
- Remote desktop support for Windows 11 clients

### Dashboard development

- `dashboard/dashboard.py` contains the Gradio dashboard mounted at
  `http://server:8000/dashboard`; `dashboard/restart-dashboard.sh` is the
  server-node helper for installing an edited copy and restarting only
  `llm-gateway.service`.
- Model details includes a live Operation progress panel with state, phase,
  target node, elapsed time, residencyd/vLLM log tails, and load/unload errors.
  The download tab continuously polls the `llm-pull.service` journal while a
  model download is active.
- `setup-strixhalo-ai-server.sh` still installs FastAPI, Uvicorn, httpx and
  Gradio, and copies `dashboard/dashboard.py` into the gateway virtualenv
  during initial provisioning. Transfer the setup script and all companion
  source subfolders (`gateway/`, `dashboard/`, `llmprofile/`, and
  `residency/`) together for that first install.
- To iterate, edit `dashboard/dashboard.py` locally, copy the updated
  `dashboard/` folder to the server, then run
  `sudo bash ./dashboard/restart-dashboard.sh`.
  The helper also accepts a dashboard source path and honors `GATEWAY_VENV`.
  Alternatively, install the file into the gateway virtualenv and run
  `sudo systemctl restart llm-gateway.service`. Do not rerun provisioning.

### Gateway development

- `gateway/app.py` is the canonical gateway source. Initial setup installs it
  as `$GATEWAY_VENV/app.py` (normally `/opt/llm-gateway/app.py`), and the systemd
  unit imports it from that virtualenv working directory.
- To iterate, edit or copy the `gateway/` folder to the server, then run
  `sudo bash ./gateway/restart-gateway.sh`. The helper atomically replaces
  only `app.py` and restarts only `llm-gateway.service`; it does not rerun
  provisioning or change `dashboard.py` or dependencies. It accepts an
  optional source path and honors `GATEWAY_VENV`/`GATEWAY_SOURCE`.

### Model profiling development

- `llmprofile/llm-profile.py` is the standard-library-only source installed as
  `/usr/local/bin/llm-profile`.
- To iterate, edit or copy the `llmprofile/` folder to the node, then run
  `sudo bash ./llmprofile/update-llm-profile.sh`. It atomically updates only
  the CLI, restarts no service, and leaves the model catalog untouched.
  `LLM_PROFILE_DEST` and an optional source path are supported.

### Residency control-plane development

- `residency/residencyd.py` is the server-node root daemon and
  `residency/residency-agent.py` is the peer-side USB4-only HTTP agent. They
  are standard-library-only canonical sources; initial provisioning requires
  the `residency/` folder beside `setup-strixhalo-ai-server.sh`, which installs
  them in `/usr/local/lib/llm-cluster` (or the configured `RESIDENCY_LIB`).
- To iterate, edit the source files locally, copy the `residency/` folder to
  the node, then run `sudo bash ./residency/restart-residency.sh`. Running it
  on the server restarts `residencyd.service`; running it on the peer restarts
  `residency-agent.service`. An optional source-directory argument and the
  `RESIDENCY_LIB` environment override are supported. The source-directory
  argument is not required when both Python files are beside the helper; it is
  only for storing the source files elsewhere. The helper reloads systemd unit
  definitions before restarting the service.
- Test edits one node at a time as appropriate. The helper only replaces the
  residency sources and restarts the installed residency service; it does not
  rerun provisioning or alter the model catalog/configuration.

### VSCode

- VSCode of vLLM models supported through https://github.com/arbs-io/github-copilot-llm-gateway

## Installation

- Simple, idempotent setup script to run on each node. setup-strixhalo-ai-server.sh
- The container runtime is checked for the pinned vLLM/Ray pair (vLLM 0.22.1
  with Ray 2.48.0 by default). Setup resolves the base image to an immutable
  digest and automatically builds a local compatibility overlay when the base
  image carries a different Ray version. It then verifies the actual runtime
  versions before creating the Ray services. Override
  `VLLM_EXPECTED_VERSION` and `RAY_EXPECTED_VERSION` only for a tested pair.
- Post-setup verification script after reboot: verify-and-seed-strixhalo-ai-server.sh
- List of models to seed system with: strixhalo-models.txt