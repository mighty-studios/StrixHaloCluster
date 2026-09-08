"""Gradio dashboard for the Strix Halo residency gateway."""

import math
import html as html_lib

import gradio as gr


def mount_dashboard(app, ctl):
    """Build and mount the dashboard on the gateway FastAPI application."""
    def _fmt_idle(seconds):
        try:
            seconds = float(seconds)
        except (TypeError, ValueError):
            return "-"
        if seconds <= 0:
            return "-"
        m, s = divmod(int(seconds), 60)
        h, m = divmod(m, 60)
        return "%dh%02dm" % (h, m) if h else "%dm%02ds" % (m, s)

    def _fmt_elapsed(seconds):
        try:
            seconds = max(0, int(float(seconds or 0)))
        except (TypeError, ValueError):
            return "0s"
        m, s = divmod(seconds, 60)
        h, m = divmod(m, 60)
        return "%dh%02dm" % (h, m) if h else "%dm%02ds" % (m, s)

    def _fmt_budget(v):
        # Defensive rounding-up for display only: residencyd already stores
        # whole-GiB budgets, but this keeps the dashboard clean even against
        # an older residencyd or a hand-edited .conf that has not been
        # normalized yet, rather than ever showing e.g. 25.303897857666016.
        try:
            return math.ceil(float(v))
        except (TypeError, ValueError):
            return "-"

    async def _dashboard_catalog():
        try:
            r = await ctl.get("/catalog", timeout=15.0)
            return r.json()
        except Exception as exc:        # noqa: BLE001
            return {"error": str(exc), "data": [], "nodes": {}}

    NODE_HEADERS = ["node", "used_gib", "budget_gib", "free_gib", "mem_available_gib"]
    MODEL_HEADERS = ["name", "state", "node", "placement", "tp", "pp",
                     "budget_gib", "port", "leases", "idle", "keep_warm",
                     "enabled", "last_error"]

    def _short_text(value, limit):
        text = "" if value is None else str(value)
        return text if len(text) <= limit else text[:limit - 3] + "..."

    def _model_table_html(rows):
        state_colors = {
            "ready": "#16803c",
            "loaded": "#16803c",
            "loading": "#9a6700",
            "failed": "#b42318",
        }

        def cell(value, class_name="", limit=None, text_color=None):
            full = "" if value is None else str(value)
            display = _short_text(full, limit) if limit else full
            class_attr = (' class="catalog-cell %s"' % class_name) if class_name else \
                ' class="catalog-cell"'
            title_attr = (' title="%s" aria-label="%s"' %
                          (html_lib.escape(full, quote=True),
                           html_lib.escape(full, quote=True))) if full else ""
            color_attr = (' style="color:%s !important;"' % text_color) \
                if text_color else ""
            return "<td><span%s%s%s>%s</span></td>" % (
                class_attr, title_attr, color_attr, html_lib.escape(display))

        header = "".join(
            '<th style="color:#222 !important;background-color:#f5f5f5 !important;">'
            '<span style="color:#222 !important;">%s</span></th>'
            % html_lib.escape(str(name))
                         for name in MODEL_HEADERS)
        body = []
        for row in rows:
            row_color = state_colors.get(str(row[1] or "").lower())
            cells = []
            for index, value in enumerate(row):
                if index == 0:
                    cells.append(cell(value, "catalog-name", 28, row_color))
                elif index == len(MODEL_HEADERS) - 1:
                    cells.append(cell(value, "catalog-error", 80, row_color))
                else:
                    cells.append(cell(value, text_color=row_color))
            body.append("<tr>%s</tr>" % "".join(cells))
        return (
            "<style>"
            ".catalog-table-wrap{overflow-x:auto;width:100%%;}"
            ".catalog-table{border-collapse:collapse;width:100%%;"
            "font-size:0.9em;table-layout:auto;}"
            ".catalog-table th,.catalog-table td{border:1px solid #d9d9d9;"
            "padding:4px 6px;text-align:left;white-space:nowrap;}"
            ".catalog-table th{background:#f5f5f5 !important;"
            "color:#222 !important;font-weight:600 !important;}"
            ".catalog-cell{display:block;overflow:hidden;text-overflow:ellipsis;"
            "white-space:nowrap;max-width:120px;}"
            ".catalog-name{max-width:220px;}"
            ".catalog-error{max-width:360px;}"
            "</style>"
            "<div class=\"catalog-table-wrap\"><table class=\"catalog-table\">"
            "<thead><tr>%s</tr></thead><tbody>%s</tbody></table></div>"
            % (header, "".join(body))
        )

    async def _refresh():
        cat = await _dashboard_catalog()
        nodes = cat.get("nodes") or {}
        node_rows = [[n, round(v.get("used_gib", 0) or 0, 1),
                     _fmt_budget(v.get("budget_gib", 0)),
                     round(v.get("free_gib", 0) or 0, 1),
                     ("%.1f" % v["mem_available_gib"]) if v.get("mem_available_gib") is not None
                     else "?"] for n, v in sorted(nodes.items())]
        names = []
        model_rows = []
        for m in cat.get("data") or []:
            names.append(m.get("id"))
            model_rows.append([
                m.get("id"), m.get("state"), m.get("node") or "-",
                m.get("placement"), m.get("tensor_parallel"),
                m.get("pipeline_parallel"), _fmt_budget(m.get("budget_gib")), m.get("port"),
                m.get("active_leases", 0), _fmt_idle(m.get("idle_seconds")),
                "yes" if m.get("keep_warm") else "",
                "yes" if m.get("enabled", True) else "no",
                (m.get("last_error") or "")[:80],
            ])
        return (node_rows, _model_table_html(model_rows), gr.update(choices=names))

    with gr.Blocks(title="Strix Halo cluster") as _dashboard:
        gr.Markdown("# Strix Halo cluster -- model residency & node utilization\n"
                    "Auto-refreshes every 5s. Every action here is the same "
                    "`/cluster/*` API `curl` can already reach.")
        node_table = gr.Dataframe(headers=NODE_HEADERS, label="Node utilization (GiB)",
                                  interactive=False)
        model_table = gr.HTML(label="Model catalog & residency")
        with gr.Row():
            refresh_btn = gr.Button("Refresh now")
            reload_btn = gr.Button("Reload catalog (pick up .conf changes made over SSH)")
        top_status = gr.Textbox(label="Last action result", interactive=False, lines=2)

        with gr.Tabs():
            with gr.Tab("Model details"):
                gr.Markdown(
                    "Pick a model to view or edit its catalog entry, force it "
                    "loaded or unloaded, delete it, or tail its recent log. Every "
                    "action here is the same `/cluster/*` API `curl` can already reach."
                )
                detail_select = gr.Dropdown(choices=[], label="Model")
                with gr.Row():
                    detail_state = gr.Textbox(label="State", interactive=False)
                    detail_node = gr.Textbox(label="Node", interactive=False)
                detail_error = gr.Textbox(label="Last error", interactive=False, lines=2)

                gr.Markdown("#### Catalog entry (edit and Save)")
                with gr.Row():
                    d_path = gr.Textbox(label="Model path")
                    d_served = gr.Textbox(label="Served name")
                    d_placement = gr.Dropdown(["auto", "server", "peer", "distributed"],
                                              label="Placement")
                with gr.Row():
                    d_tp = gr.Number(precision=0, label="Tensor parallel")
                    d_pp = gr.Number(precision=0, label="Pipeline parallel")
                    d_budget = gr.Number(precision=0, label="Budget GiB (whole numbers only)")
                    d_port = gr.Number(precision=0, label="Port")
                with gr.Row():
                    d_maxlen = gr.Number(precision=0, label="Max model len (blank = default)")
                    d_gpuutil = gr.Textbox(label="GPU util (blank = auto)")
                    d_quant = gr.Textbox(label="Quantization")
                with gr.Row():
                    d_toolp = gr.Textbox(label="Tool parser")
                    d_reasonp = gr.Textbox(label="Reasoning parser")
                    d_extra = gr.Textbox(label="Extra vLLM args")
                with gr.Row():
                    d_eager = gr.Checkbox(label="Enforce eager")
                    d_keepwarm = gr.Checkbox(label="Keep warm (exempt from idle eviction)")
                    d_enabled = gr.Checkbox(label="Enabled")
                save_btn = gr.Button("Save changes", variant="primary")

                gr.Markdown("#### Residency actions")
                with gr.Row():
                    load_btn = gr.Button("Force load", visible=True)
                    unload_abort_btn = gr.Button("Unload / abort load", visible=False,
                                                 variant="stop")
                with gr.Row():
                    del_confirm = gr.Checkbox(label="Yes, stop it and remove its catalog entry")
                    del_btn = gr.Button("Delete from catalog", visible=True, variant="stop")
                detail_status = gr.Textbox(label="Last action result", interactive=False, lines=2)

                gr.Markdown("#### Operation progress (live)")
                operation_status = gr.Textbox(
                    label="Current operation", interactive=False, lines=3)
                operation_log = gr.Textbox(
                    label="Residency/vLLM progress log", lines=12,
                    interactive=False, autoscroll=True)

                gr.Markdown("#### Recent log (last 5 minutes, both nodes)")
                detail_log = gr.Textbox(label="vllm@<name>.service", lines=14,
                                        interactive=False, autoscroll=True)
                detail_log_refresh = gr.Button("Refresh log")

            with gr.Tab("Add model (download)"):
                gr.Markdown(
                    "### Download a model from Hugging Face or ModelScope and add it "
                    "to the catalog\n"
                    "Paste just the **repo id** (`owner/name`), not a URL. On Hugging "
                    "Face, open the model's page and copy the `owner/name` from the URL "
                    "right after `huggingface.co/` -- e.g. for "
                    "`https://huggingface.co/Qwen/Qwen2.5-7B-Instruct-AWQ` the repo id is "
                    "`Qwen/Qwen2.5-7B-Instruct-AWQ`. ModelScope repo ids look the same, "
                    "copied from right after `modelscope.cn/models/`.\n\n"
                    "**Prefer a pre-quantized checkpoint** over the original bf16/fp16 "
                    "release: look for repo names ending in `-AWQ`, `-GPTQ`, "
                    "`-GPTQ-Int4`, `-FP8` or similar (often published by the same group, "
                    "or by community requantizers such as `neuralmagic`/`RedHatAI`). A "
                    "4-bit (AWQ/GPTQ-Int4) checkpoint uses roughly a quarter of the memory "
                    "of the original weights -- usually the difference between a 30B+ "
                    "model fitting on one node here or needing to be split across both. "
                    "GGUF repos cannot be used: vLLM only serves safetensors, and this "
                    "download step skips `.gguf` files automatically.\n\n"
                    "Downloads run one at a time; this form disables itself while one is "
                    "in progress."
                )
                with gr.Row():
                    pull_source = gr.Radio(["Hugging Face", "ModelScope"],
                                           value="Hugging Face", label="Source")
                    pull_repo = gr.Textbox(label="Repo id",
                                           placeholder="Qwen/Qwen2.5-7B-Instruct-AWQ")
                    pull_name = gr.Textbox(label="Catalog name (blank = derived from repo id)")
                with gr.Row():
                    pull_placement = gr.Dropdown(["", "auto", "server", "peer", "distributed"],
                                                 value="",
                                                 label="Placement override (blank = auto-profiled)")
                    pull_maxlen = gr.Number(value=None, precision=0,
                                            label="Max model len override (blank = default)")
                    pull_revision = gr.Textbox(label="Revision/branch (blank = main)")
                with gr.Row():
                    pull_noparser = gr.Checkbox(label="Skip auto tool/reasoning parser detection")
                    pull_keepwarm = gr.Checkbox(label="Keep warm")

                gr.Markdown("#### Additional catalog settings "
                           "(optional; applied after the download finishes)")
                with gr.Row():
                    pull_tp = gr.Number(value=None, precision=0, label="Tensor parallel override")
                    pull_pp = gr.Number(value=None, precision=0, label="Pipeline parallel override")
                    pull_budget = gr.Number(value=None, precision=0,
                                           label="Budget GiB override (whole numbers only)")
                    pull_port = gr.Number(value=None, precision=0, label="Port override")
                with gr.Row():
                    pull_gpuutil = gr.Textbox(label="GPU util override (blank = auto)")
                    pull_quant = gr.Textbox(label="Quantization override")
                    pull_toolp = gr.Textbox(label="Tool parser override")
                    pull_reasonp = gr.Textbox(label="Reasoning parser override")
                with gr.Row():
                    pull_extra = gr.Textbox(label="Extra vLLM args override")
                    pull_eager = gr.Checkbox(label="Enforce eager")

                pull_btn = gr.Button("Add to catalog (download)", variant="primary")
                pull_result = gr.Textbox(label="Last action result", interactive=False, lines=2)
                pull_job_status = gr.Textbox(label="Job status", interactive=False, lines=1)
                gr.Markdown("#### Recent log (last 5 minutes, download progress included)")
                pull_log = gr.Textbox(label="llm-pull.service", lines=16,
                                      interactive=False, autoscroll=True)
                pull_log_refresh = gr.Button("Refresh log")

        _refresh_outputs = [node_table, model_table, detail_select]
        gr.Timer(5).tick(_refresh, outputs=_refresh_outputs)
        _dashboard.load(_refresh, outputs=_refresh_outputs)
        refresh_btn.click(_refresh, outputs=_refresh_outputs)

        async def _do_reload():
            try:
                r = await ctl.post("/reload", json={}, timeout=30.0)
                return "%s: %s" % (r.status_code, r.json())
            except Exception as exc:    # noqa: BLE001
                return "error: %s" % exc
        reload_btn.click(_do_reload, outputs=top_status)

        _detail_outputs = [d_path, d_served, d_placement, d_tp, d_pp, d_budget, d_port,
                          d_maxlen, d_gpuutil, d_quant, d_toolp, d_reasonp, d_extra,
                          d_eager, d_keepwarm, d_enabled, detail_state, detail_node,
                          detail_error, load_btn, unload_abort_btn, del_btn, detail_log]

        def _num(v):
            try:
                return float(v) if v not in (None, "") else None
            except (TypeError, ValueError):
                return None

        async def _load_detail(name):
            if not name:
                return ("", "", "auto", 1, 1, None, None, None, "", "", "", "", "",
                       False, False, True, "-", "-", "",
                       gr.update(visible=True), gr.update(visible=False),
                       gr.update(visible=True), "")
            cat = await _dashboard_catalog()
            model = next((m for m in (cat.get("data") or []) if m.get("id") == name), None)
            try:
                r = await ctl.get("/models/conf", params={"name": name}, timeout=15.0)
                conf = r.json() if r.status_code == 200 else {}
            except Exception:           # noqa: BLE001
                conf = {}
            state = (model or {}).get("state", "unloaded")
            node = (model or {}).get("node") or "-"
            last_error = (model or {}).get("last_error", "") or ""
            loaded_or_loading = state in ("ready", "loading")
            return (
                conf.get("MODEL_PATH", ""), conf.get("SERVED_NAME", ""),
                conf.get("PLACEMENT") or "auto",
                _num(conf.get("TENSOR_PARALLEL")) or 1, _num(conf.get("PIPELINE_PARALLEL")) or 1,
                _num(conf.get("MEM_BUDGET_GIB")), _num(conf.get("PORT")),
                _num(conf.get("MAX_MODEL_LEN")), conf.get("GPU_MEMORY_UTILIZATION", ""),
                conf.get("QUANTIZATION", ""), conf.get("TOOL_CALL_PARSER", ""),
                conf.get("REASONING_PARSER", ""), conf.get("EXTRA_ARGS", ""),
                conf.get("ENFORCE_EAGER", "0") == "1", conf.get("KEEP_WARM", "0") == "1",
                conf.get("ENABLED", "1") != "0",
                state, node, last_error,
                gr.update(visible=not loaded_or_loading),
                gr.update(visible=loaded_or_loading),
                gr.update(visible=not loaded_or_loading),
                "",
            )
        async def _refresh_progress(name):
            if not name:
                return "Pick a model to see live operation progress.", ""
            try:
                r = await ctl.get("/models/progress",
                                   params={"name": name, "minutes": 5},
                                   timeout=30.0)
                data = r.json()
                if not isinstance(data, dict):
                    return "error: unexpected progress response", ""
                if r.status_code != 200:
                    return "error: %s" % (data.get("error") or data), ""
            except Exception as exc:    # noqa: BLE001
                return "error: %s" % exc, ""
            state = data.get("state") or "-"
            phase = data.get("phase") or data.get("operation_phase") or "-"
            node = data.get("node") or "-"
            placement = data.get("placement") or "-"
            leases = data.get("active_leases", 0)
            elapsed = _fmt_elapsed(data.get("elapsed_seconds"))
            status = ("state=%s | phase=%s | target=%s | placement=%s | "
                      "leases=%s | elapsed=%s"
                      % (state, phase, node, placement, leases, elapsed))
            if data.get("last_error"):
                status += "\nlast_error: %s" % data["last_error"]
            return status, data.get("log") or "(no recent output)"

        detail_select.change(_load_detail, inputs=[detail_select], outputs=_detail_outputs
                            ).then(_refresh_progress, inputs=[detail_select],
                                   outputs=[operation_status, operation_log])
        _dashboard.load(_refresh_progress, inputs=[detail_select],
                        outputs=[operation_status, operation_log])

        async def _do_save(name, path, served, placement, tp, pp, budget, port, maxlen,
                           gpuutil, quant, toolp, reasonp, extra, eager, keepwarm, enabled):
            if not name:
                return "pick a model first"
            body = {"name": name, "path": path or None, "served_name": served or None,
                   "placement": placement or None,
                   "tp": int(tp) if tp else None, "pp": int(pp) if pp else None,
                   "budget_gib": budget if budget else None,
                   "port": int(port) if port else None,
                   "max_len": int(maxlen) if maxlen else None,
                   "gpu_util": gpuutil or None, "quantization": quant or None,
                   "tool_parser": toolp or None, "reasoning_parser": reasonp or None,
                   "extra": extra or None, "enforce_eager": bool(eager),
                   "keep_warm": bool(keepwarm), "enabled": bool(enabled)}
            try:
                r = await ctl.post("/models/edit", json=body, timeout=60.0)
                return "%s: %s" % (r.status_code, r.json())
            except Exception as exc:    # noqa: BLE001
                return "error: %s" % exc
        save_btn.click(_refresh_progress, inputs=[detail_select],
                       outputs=[operation_status, operation_log],
                       queue=False
                       ).then(_do_save, inputs=[detail_select, d_path, d_served, d_placement,
                                                d_tp, d_pp, d_budget, d_port, d_maxlen,
                                                d_gpuutil, d_quant, d_toolp, d_reasonp,
                                                d_extra, d_eager, d_keepwarm, d_enabled],
                              outputs=detail_status
                       ).then(_refresh, outputs=_refresh_outputs
                       ).then(_load_detail, inputs=[detail_select], outputs=_detail_outputs
                       ).then(_refresh_progress, inputs=[detail_select],
                              outputs=[operation_status, operation_log])

        async def _do_force_load(name):
            if not name:
                return "pick a model first"
            try:
                r = await ctl.post("/models/load", json={"name": name})
                return "%s: %s" % (r.status_code, r.json())
            except Exception as exc:    # noqa: BLE001
                return "error: %s" % exc
        load_btn.click(_refresh_progress, inputs=[detail_select],
                       outputs=[operation_status, operation_log],
                       queue=False
                       ).then(_do_force_load, inputs=[detail_select], outputs=detail_status
                       ).then(_refresh, outputs=_refresh_outputs
                       ).then(_load_detail, inputs=[detail_select], outputs=_detail_outputs
                       ).then(_refresh_progress, inputs=[detail_select],
                              outputs=[operation_status, operation_log])

        async def _do_unload_abort(name):
            if not name:
                return "pick a model first"
            try:
                r = await ctl.post("/unload", json={"model": name, "force": True},
                                    timeout=180.0)
                return "%s: %s" % (r.status_code, r.json())
            except Exception as exc:    # noqa: BLE001
                return "error: %s" % exc
        unload_abort_btn.click(_refresh_progress, inputs=[detail_select],
                               outputs=[operation_status, operation_log],
                               queue=False
                               ).then(_do_unload_abort, inputs=[detail_select],
                                      outputs=detail_status
                              ).then(_refresh, outputs=_refresh_outputs
                              ).then(_load_detail, inputs=[detail_select], outputs=_detail_outputs
                              ).then(_refresh_progress, inputs=[detail_select],
                                     outputs=[operation_status, operation_log])

        async def _do_delete_detail(name, confirmed):
            if not name:
                return "pick a model first"
            if not confirmed:
                return "tick the confirm box first"
            try:
                r = await ctl.post("/models/delete", json={"name": name}, timeout=60.0)
                return "%s: %s" % (r.status_code, r.json())
            except Exception as exc:    # noqa: BLE001
                return "error: %s" % exc
        del_btn.click(_refresh_progress, inputs=[detail_select],
                      outputs=[operation_status, operation_log],
                      queue=False
                     ).then(_do_delete_detail, inputs=[detail_select, del_confirm],
                            outputs=detail_status
                     ).then(_refresh, outputs=_refresh_outputs
                     ).then(lambda: gr.update(value=None), outputs=detail_select
                     ).then(_refresh_progress, inputs=[detail_select],
                            outputs=[operation_status, operation_log])

        async def _do_log_refresh(name):
            if not name:
                return "(pick a model first)"
            try:
                r = await ctl.get("/models/log", params={"name": name, "minutes": 5},
                                   timeout=30.0)
                data = r.json()
                return data.get("log") or data.get("error") or "(no output)"
            except Exception as exc:    # noqa: BLE001
                return "error: %s" % exc
        detail_log_refresh.click(_do_log_refresh, inputs=[detail_select], outputs=detail_log)

        async def _do_pull(source, repo, name, placement, maxlen, revision, noparser,
                           keepwarm, tp, pp, budget, port, gpuutil, quant, toolp,
                           reasonp, extra, eager):
            if not repo:
                return "a repo id is required"
            body = {
                "source": "hf" if source == "Hugging Face" else "ms",
                "repo": repo, "name": name or None, "placement": placement or None,
                "max_len": int(maxlen) if maxlen else None, "revision": revision or None,
                "no_parser": bool(noparser), "keep_warm": bool(keepwarm),
                "tp": int(tp) if tp else None, "pp": int(pp) if pp else None,
                "budget_gib": budget if budget else None, "port": int(port) if port else None,
                "gpu_util": gpuutil or None, "quantization": quant or None,
                "tool_parser": toolp or None, "reasoning_parser": reasonp or None,
                "extra": extra or None, "enforce_eager": bool(eager),
            }
            try:
                r = await ctl.post("/models/pull", json=body, timeout=30.0)
                return "%s: %s" % (r.status_code, r.json())
            except Exception as exc:    # noqa: BLE001
                return "error: %s" % exc

        async def _do_pull_log_refresh():
            try:
                r = await ctl.get("/models/pull/log", params={"minutes": 5}, timeout=15.0)
                data = r.json() if r.status_code == 200 else {}
            except Exception as exc:    # noqa: BLE001
                return "error: %s" % exc, "", gr.update(interactive=True)
            active = bool(data.get("active"))
            text = data.get("log") or "(no output yet)"
            latest = next((line.strip() for line in reversed(text.splitlines())
                           if line.strip()), "")
            status = ("running" if active else "idle - ready for a new download")
            if active and latest:
                status += " | " + latest[-180:]
            return (status, text,
                   gr.update(interactive=not active))

        pull_btn.click(_do_pull, inputs=[pull_source, pull_repo, pull_name, pull_placement,
                                        pull_maxlen, pull_revision, pull_noparser,
                                        pull_keepwarm, pull_tp, pull_pp, pull_budget,
                                        pull_port, pull_gpuutil, pull_quant, pull_toolp,
                                        pull_reasonp, pull_extra, pull_eager],
                      outputs=pull_result
                      ).then(_do_pull_log_refresh,
                             outputs=[pull_job_status, pull_log, pull_btn])
        pull_log_refresh.click(_do_pull_log_refresh,
                               outputs=[pull_job_status, pull_log, pull_btn])
        gr.Timer(4).tick(_do_pull_log_refresh, outputs=[pull_job_status, pull_log, pull_btn])
        _dashboard.load(_do_pull_log_refresh, outputs=[pull_job_status, pull_log, pull_btn])
        # Keep the live poll outside the queued action callbacks: a cold load
        # can block for minutes, but the panel should continue to receive
        # residencyd snapshots while it is in flight.
        gr.Timer(2).tick(_refresh_progress, inputs=[detail_select],
                         outputs=[operation_status, operation_log], queue=False)

    gr.mount_gradio_app(app, _dashboard, path="/dashboard")
