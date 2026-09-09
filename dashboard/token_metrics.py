#!/usr/bin/env python3
"""Persistent token-rate metrics for triggered cluster tests."""

from __future__ import annotations

import json
import sqlite3
import time
import uuid
from dataclasses import asdict, dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Any


def utc_now() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="seconds")


def _int_value(value: Any) -> int | None:
    try:
        return int(value)
    except (TypeError, ValueError):
        return None


def _float_value(value: Any) -> float | None:
    try:
        return float(value)
    except (TypeError, ValueError):
        return None


def _rate(tokens: int | None, seconds: float | None) -> float | None:
    if tokens is None or seconds is None or seconds <= 0:
        return None
    return tokens / seconds


@dataclass
class TokenMetric:
    run_id: str
    test_name: str
    recorded_at: str
    slot_id: int
    prompt_tokens: int | None
    generated_tokens: int | None
    prompt_seconds: float | None
    generation_seconds: float | None
    wall_seconds: float | None
    prompt_tokens_per_second: float | None
    generation_tokens_per_second: float | None
    total_tokens_per_second: float | None
    context_tokens: int
    parallel_slots: int
    estimated: bool = False


def metric_from_response(
    body: dict[str, Any],
    *,
    run_id: str,
    test_name: str,
    slot_id: int,
    wall_seconds: float,
    expected_prompt_tokens: int,
    expected_output_tokens: int,
    context_tokens: int,
    parallel_slots: int,
) -> TokenMetric:
    timings = body.get("timings", {})
    if not isinstance(timings, dict):
        timings = {}

    prompt_tokens = _int_value(timings.get("prompt_n"))
    if prompt_tokens is None:
        prompt_tokens = _int_value(body.get("tokens_evaluated"))
    if prompt_tokens is None:
        prompt_tokens = expected_prompt_tokens

    generated_tokens = _int_value(timings.get("predicted_n"))
    if generated_tokens is None:
        response_tokens = body.get("tokens")
        if isinstance(response_tokens, list):
            generated_tokens = len(response_tokens)
    estimated = generated_tokens is None
    if generated_tokens is None:
        generated_tokens = expected_output_tokens

    prompt_ms = _float_value(timings.get("prompt_ms"))
    generation_ms = _float_value(timings.get("predicted_ms"))
    prompt_seconds = prompt_ms / 1000 if prompt_ms is not None else None
    generation_seconds = (
        generation_ms / 1000 if generation_ms is not None else None
    )
    total_tokens = prompt_tokens + generated_tokens

    return TokenMetric(
        run_id=run_id,
        test_name=test_name,
        recorded_at=utc_now(),
        slot_id=slot_id,
        prompt_tokens=prompt_tokens,
        generated_tokens=generated_tokens,
        prompt_seconds=prompt_seconds,
        generation_seconds=generation_seconds,
        wall_seconds=wall_seconds,
        prompt_tokens_per_second=_rate(prompt_tokens, prompt_seconds),
        generation_tokens_per_second=_rate(generated_tokens, generation_seconds),
        total_tokens_per_second=_rate(total_tokens, wall_seconds),
        context_tokens=context_tokens,
        parallel_slots=parallel_slots,
        estimated=estimated,
    )


class TokenRateStore:
    """Small SQLite store shared by the dashboard and its CLI tests."""

    def __init__(self, path: str | Path):
        self.path = Path(path)

    def _connect(self) -> sqlite3.Connection:
        if not self.path.parent.exists():
            raise FileNotFoundError(
                f"token metrics directory does not exist: {self.path.parent}"
            )
        connection = sqlite3.connect(self.path, timeout=10)
        connection.execute(
            """
            CREATE TABLE IF NOT EXISTS token_rate_runs (
                run_id TEXT PRIMARY KEY,
                test_name TEXT NOT NULL,
                recorded_at REAL NOT NULL,
                recorded_at_iso TEXT NOT NULL,
                context_tokens INTEGER NOT NULL,
                parallel_slots INTEGER NOT NULL,
                wall_seconds REAL NOT NULL,
                success INTEGER NOT NULL,
                details_json TEXT NOT NULL
            )
            """
        )
        connection.execute(
            """
            CREATE TABLE IF NOT EXISTS token_rate_requests (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                run_id TEXT NOT NULL,
                recorded_at REAL NOT NULL,
                slot_id INTEGER NOT NULL,
                prompt_tokens INTEGER,
                generated_tokens INTEGER,
                prompt_seconds REAL,
                generation_seconds REAL,
                wall_seconds REAL,
                prompt_tokens_per_second REAL,
                generation_tokens_per_second REAL,
                total_tokens_per_second REAL,
                context_tokens INTEGER NOT NULL,
                parallel_slots INTEGER NOT NULL,
                estimated INTEGER NOT NULL,
                FOREIGN KEY(run_id) REFERENCES token_rate_runs(run_id)
            )
            """
        )
        connection.execute(
            "CREATE INDEX IF NOT EXISTS idx_token_rate_runs_time "
            "ON token_rate_runs(recorded_at)"
        )
        connection.execute(
            "CREATE INDEX IF NOT EXISTS idx_token_rate_requests_run "
            "ON token_rate_requests(run_id)"
        )
        return connection

    def record_run(
        self,
        metrics: list[TokenMetric],
        *,
        test_name: str,
        context_tokens: int,
        parallel_slots: int,
        wall_seconds: float,
        success: bool,
        details: dict[str, Any] | None = None,
    ) -> str:
        run_id = metrics[0].run_id if metrics else uuid.uuid4().hex
        recorded_at = time.time()
        recorded_at_iso = utc_now()
        detail_text = json.dumps(details or {}, separators=(",", ":"))
        connection = self._connect()
        try:
            with connection:
                connection.execute(
                    """
                    INSERT INTO token_rate_runs (
                        run_id, test_name, recorded_at, recorded_at_iso,
                        context_tokens, parallel_slots, wall_seconds,
                        success, details_json
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                    (
                        run_id,
                        test_name,
                        recorded_at,
                        recorded_at_iso,
                        context_tokens,
                        parallel_slots,
                        wall_seconds,
                        int(success),
                        detail_text,
                    ),
                )
                for metric in metrics:
                    connection.execute(
                        """
                        INSERT INTO token_rate_requests (
                            run_id, recorded_at, slot_id, prompt_tokens,
                            generated_tokens, prompt_seconds, generation_seconds,
                            wall_seconds, prompt_tokens_per_second,
                            generation_tokens_per_second, total_tokens_per_second,
                            context_tokens, parallel_slots, estimated
                        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                        """,
                        (
                            run_id,
                            recorded_at,
                            metric.slot_id,
                            metric.prompt_tokens,
                            metric.generated_tokens,
                            metric.prompt_seconds,
                            metric.generation_seconds,
                            metric.wall_seconds,
                            metric.prompt_tokens_per_second,
                            metric.generation_tokens_per_second,
                            metric.total_tokens_per_second,
                            metric.context_tokens,
                            metric.parallel_slots,
                            int(metric.estimated),
                        ),
                    )
        finally:
            connection.close()
        return run_id

    @staticmethod
    def _aggregate(rows: list[sqlite3.Row]) -> dict[str, Any]:
        run_wall: dict[str, float] = {}
        run_names: dict[str, str] = {}
        prompt_tokens = 0
        generated_tokens = 0
        prompt_seconds = 0.0
        generation_seconds = 0.0
        requests = 0

        for row in rows:
            run_id = str(row["run_id"])
            run_wall[run_id] = float(row["run_wall_seconds"] or 0)
            run_names[run_id] = str(row["test_name"])
            if row["request_id"] is None:
                continue
            requests += 1
            prompt_tokens += int(row["prompt_tokens"] or 0)
            generated_tokens += int(row["generated_tokens"] or 0)
            prompt_seconds += float(row["prompt_seconds"] or 0)
            generation_seconds += float(row["generation_seconds"] or 0)

        total_tokens = prompt_tokens + generated_tokens
        total_wall_seconds = sum(run_wall.values())
        return {
            "test_runs": len(run_wall),
            "requests": requests,
            "prompt_tokens": prompt_tokens,
            "generated_tokens": generated_tokens,
            "prompt_tokens_per_second": _rate(prompt_tokens, prompt_seconds),
            "generation_tokens_per_second": _rate(
                generated_tokens, generation_seconds
            ),
            "aggregate_tokens_per_second": _rate(
                total_tokens, total_wall_seconds
            ),
            "total_wall_seconds": total_wall_seconds,
            "test_names": sorted(set(run_names.values())),
        }

    def summary(self) -> dict[str, Any]:
        windows = (
            ("last hour", 3600),
            ("last 24 hours", 86400),
            ("last 7 days", 604800),
            ("all time", None),
        )
        result: dict[str, Any] = {"windows": []}
        connection = self._connect()
        connection.row_factory = sqlite3.Row
        try:
            for label, seconds in windows:
                cutoff = time.time() - seconds if seconds is not None else 0
                rows = connection.execute(
                    """
                    SELECT r.run_id, r.test_name, r.wall_seconds AS run_wall_seconds,
                           q.id AS request_id,
                           q.prompt_tokens, q.generated_tokens,
                           q.prompt_seconds, q.generation_seconds
                    FROM token_rate_runs AS r
                    LEFT JOIN token_rate_requests AS q ON q.run_id = r.run_id
                    WHERE r.recorded_at >= ?
                    ORDER BY r.recorded_at DESC
                    """,
                    (cutoff,),
                ).fetchall()
                aggregate = self._aggregate(rows)
                aggregate["label"] = label
                result["windows"].append(aggregate)

            latest = connection.execute(
                """
                SELECT run_id, test_name, recorded_at_iso, context_tokens,
                       parallel_slots, wall_seconds, success, details_json
                FROM token_rate_runs
                ORDER BY recorded_at DESC
                LIMIT 1
                """
            ).fetchone()
            if latest is not None:
                latest_data = dict(latest)
                try:
                    latest_data["details"] = json.loads(
                        latest_data.pop("details_json")
                    )
                except (TypeError, json.JSONDecodeError):
                    latest_data["details"] = {}
                result["latest"] = latest_data
        finally:
            connection.close()
        return result


def metric_as_dict(metric: TokenMetric) -> dict[str, Any]:
    return asdict(metric)
