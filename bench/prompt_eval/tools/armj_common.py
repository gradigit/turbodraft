#!/usr/bin/env python3
from __future__ import annotations

import json
import math
import pathlib
import random
import re
import hashlib
import subprocess
from typing import Any

from provider_contract import (
    DEFAULT_PROVIDER_CONTRACT,
    ProviderContractError,
    load_provider_contract,
)


def load_json(path: pathlib.Path) -> dict[str, Any]:
    return json.loads(path.read_text(encoding="utf-8"))


def load_jsonl(path: pathlib.Path) -> list[dict[str, Any]]:
    rows: list[dict[str, Any]] = []
    with path.open("r", encoding="utf-8") as handle:
        for line in handle:
            line = line.strip()
            if not line:
                continue
            rows.append(json.loads(line))
    return rows


def write_json(path: pathlib.Path, payload: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(payload, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")


def write_jsonl(path: pathlib.Path, rows: list[dict[str, Any]]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("\n".join(json.dumps(row, ensure_ascii=False) for row in rows) + "\n", encoding="utf-8")


def stable_hash_object(payload: Any) -> str:
    data = json.dumps(payload, sort_keys=True, ensure_ascii=False, separators=(",", ":"))
    return hashlib.sha256(data.encode("utf-8")).hexdigest()


def canonical_rows(rows: list[dict[str, Any]]) -> list[dict[str, Any]]:
    return sorted(rows, key=lambda row: str(row.get("id", "")))


def rows_digest(rows: list[dict[str, Any]]) -> str:
    return stable_hash_object(canonical_rows(rows))


def compute_dataset_fingerprint(dataset_dir: pathlib.Path) -> dict[str, Any]:
    manifest_path = dataset_dir / "split_manifest.v1.json"
    pairwise_path = dataset_dir / "pairwise_labels.jsonl"
    manifest = load_json(manifest_path) if manifest_path.exists() else {}
    manifest_core = dict(manifest)
    manifest_core.pop("integrity", None)
    detached = (
        manifest.get("integrity", {}).get("detached_manifest_signature")
        if isinstance(manifest.get("integrity"), dict)
        else {}
    )
    pair_rows = load_jsonl(pairwise_path) if pairwise_path.exists() else []
    return {
        "dataset_dir": str(dataset_dir.resolve()),
        "manifest_core_sha256": stable_hash_object(manifest_core) if manifest_core else "",
        "manifest_payload_sha256": str(detached.get("payload_sha256") or ""),
        "pairwise_rows_sha256": rows_digest(pair_rows) if pair_rows else "",
        "pairwise_row_count": len(pair_rows),
    }


def fill_template(template: str, values: dict[str, str]) -> str:
    out = template
    for key, value in values.items():
        out = out.replace("{{" + key + "}}", value)
    return out


def parse_judge_json(text: str) -> dict[str, Any]:
    raw = text.strip()
    raw = re.sub(r"^```(?:json)?\s*", "", raw)
    raw = re.sub(r"\s*```$", "", raw)
    try:
        return json.loads(raw)
    except json.JSONDecodeError:
        start = raw.find("{")
        end = raw.rfind("}")
        if start >= 0 and end > start:
            return json.loads(raw[start : end + 1])
        raise


def load_codex_judge_provider(
    repo: pathlib.Path,
    contract_path: str = DEFAULT_PROVIDER_CONTRACT,
) -> dict[str, str]:
    contract = load_provider_contract(repo, contract_path)
    provider = contract["providers"]["judge_primary"]
    if provider["runner"] != "codex":
        raise ProviderContractError(
            "Arm J tools currently require judge_primary runner=codex "
            f"(got {provider['runner']!r})"
        )
    return provider


def run_codex_judge(
    *,
    prompt: str,
    model: str,
    reasoning_effort: str,
    schema_path: pathlib.Path,
    timeout_s: int,
) -> tuple[dict[str, Any], list[dict[str, Any]]]:
    cmd = [
        "codex",
        "exec",
        "-m",
        model,
        "-c",
        f'model_reasoning_effort="{reasoning_effort}"',
        "--json",
        "--skip-git-repo-check",
        "--output-schema",
        str(schema_path),
        "-",
    ]
    proc = subprocess.run(
        cmd,
        input=prompt,
        text=True,
        capture_output=True,
        timeout=timeout_s,
    )
    events: list[dict[str, Any]] = []
    last_agent_message: str | None = None
    error_message: str | None = None
    for line in (proc.stdout or "").splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            event = json.loads(line)
        except json.JSONDecodeError:
            continue
        events.append(event)
        ev_type = event.get("type")
        if ev_type == "item.completed":
            item = event.get("item") or {}
            if item.get("type") == "agent_message":
                last_agent_message = str(item.get("text", ""))
        elif ev_type == "error":
            error_message = str(event.get("message", "") or error_message or "")
        elif ev_type == "turn.failed":
            err = event.get("error") or {}
            error_message = str(err.get("message", "") or error_message or "")
    if proc.returncode != 0 and not error_message:
        error_message = f"codex exited {proc.returncode}: {(proc.stderr or '').strip()}"
    if error_message:
        raise RuntimeError(error_message)
    if not last_agent_message:
        raise RuntimeError("missing judge output")
    decision = parse_judge_json(last_agent_message)
    return decision, events


def extract_usage(events: list[dict[str, Any]]) -> dict[str, float]:
    totals: dict[str, float] = {}
    for event in events:
        usage = event.get("usage")
        if not isinstance(usage, dict):
            continue
        for key in ("input_tokens", "output_tokens", "reasoning_tokens", "total_tokens", "cost_usd"):
            value = usage.get(key)
            if isinstance(value, (int, float)) and not isinstance(value, bool):
                totals[key] = totals.get(key, 0.0) + float(value)
    if "total_tokens" not in totals:
        i = totals.get("input_tokens", 0.0)
        o = totals.get("output_tokens", 0.0)
        if i or o:
            totals["total_tokens"] = i + o
    return totals


def merge_usage(target: dict[str, float], delta: dict[str, float]) -> None:
    for key, value in delta.items():
        target[key] = target.get(key, 0.0) + float(value)


def wilson_lower(wins: int, total: int, z: float = 1.959963984540054) -> float:
    if total <= 0:
        return 0.0
    p = wins / total
    denom = 1 + (z**2 / total)
    center = p + (z**2 / (2 * total))
    margin = z * ((p * (1 - p) / total + z**2 / (4 * total**2)) ** 0.5)
    return (center - margin) / denom


def rank(values: list[float]) -> list[float]:
    indexed = sorted(enumerate(values), key=lambda x: x[1])
    ranks = [0.0] * len(values)
    i = 0
    while i < len(indexed):
        j = i + 1
        while j < len(indexed) and indexed[j][1] == indexed[i][1]:
            j += 1
        avg_rank = (i + j - 1) / 2.0 + 1.0
        for k in range(i, j):
            ranks[indexed[k][0]] = avg_rank
        i = j
    return ranks


def pearson(xs: list[float], ys: list[float]) -> float:
    if len(xs) != len(ys) or len(xs) < 2:
        return 0.0
    mx = sum(xs) / len(xs)
    my = sum(ys) / len(ys)
    num = 0.0
    den_x = 0.0
    den_y = 0.0
    for x, y in zip(xs, ys):
        dx = x - mx
        dy = y - my
        num += dx * dy
        den_x += dx * dx
        den_y += dy * dy
    if den_x <= 0 or den_y <= 0:
        return 0.0
    return num / math.sqrt(den_x * den_y)


def spearman(xs: list[float], ys: list[float]) -> float:
    if len(xs) != len(ys) or len(xs) < 2:
        return 0.0
    return pearson(rank(xs), rank(ys))


def median(values: list[float]) -> float:
    if not values:
        return 0.0
    ordered = sorted(values)
    n = len(ordered)
    mid = n // 2
    if n % 2 == 1:
        return float(ordered[mid])
    return float((ordered[mid - 1] + ordered[mid]) / 2.0)


def brier_and_ece(confidences: list[float], outcomes: list[int], bins: int = 10) -> tuple[float, float]:
    if not confidences:
        return 0.0, 0.0
    brier = 0.0
    for c, y in zip(confidences, outcomes):
        brier += (c - float(y)) ** 2
    brier /= len(confidences)

    bucket: list[list[int]] = [[] for _ in range(bins)]
    bucket_conf: list[list[float]] = [[] for _ in range(bins)]
    for c, y in zip(confidences, outcomes):
        idx = min(bins - 1, max(0, int(c * bins)))
        bucket[idx].append(int(y))
        bucket_conf[idx].append(float(c))
    ece = 0.0
    total = float(len(confidences))
    for ys, cs in zip(bucket, bucket_conf):
        if not ys:
            continue
        acc = sum(ys) / len(ys)
        conf = sum(cs) / len(cs)
        ece += (len(ys) / total) * abs(acc - conf)
    return float(brier), float(ece)


def calibration_profile(confidences: list[float], outcomes: list[int], bins: int = 10) -> list[dict[str, float]]:
    if bins <= 0:
        bins = 10
    bucket_count = [0 for _ in range(bins)]
    bucket_correct = [0.0 for _ in range(bins)]
    bucket_conf = [0.0 for _ in range(bins)]
    for c_raw, y_raw in zip(confidences, outcomes):
        c = float(max(0.0, min(1.0, c_raw)))
        y = float(1.0 if int(y_raw) else 0.0)
        idx = min(bins - 1, max(0, int(c * bins)))
        bucket_count[idx] += 1
        bucket_correct[idx] += y
        bucket_conf[idx] += c

    out: list[dict[str, float]] = []
    total = max(1, sum(bucket_count))
    for idx in range(bins):
        count = bucket_count[idx]
        start = idx / bins
        end = (idx + 1) / bins
        if count <= 0:
            out.append(
                {
                    "bin_index": float(idx),
                    "bin_start": float(start),
                    "bin_end": float(end),
                    "count": 0.0,
                    "share": 0.0,
                    "mean_confidence": 0.0,
                    "observed_accuracy": 0.0,
                    "abs_gap": 0.0,
                }
            )
            continue
        mean_conf = bucket_conf[idx] / count
        obs_acc = bucket_correct[idx] / count
        out.append(
            {
                "bin_index": float(idx),
                "bin_start": float(start),
                "bin_end": float(end),
                "count": float(count),
                "share": float(count / total),
                "mean_confidence": float(mean_conf),
                "observed_accuracy": float(obs_acc),
                "abs_gap": float(abs(mean_conf - obs_acc)),
            }
        )
    return out


def deterministic_sample(rows: list[dict[str, Any]], *, max_rows: int, seed: int, rerun_index: int) -> list[dict[str, Any]]:
    if max_rows <= 0 or max_rows >= len(rows):
        rows_copy = list(rows)
    else:
        rows_copy = list(rows)
    rng = random.Random(f"{seed}:{rerun_index}")
    rng.shuffle(rows_copy)
    if max_rows > 0:
        return rows_copy[:max_rows]
    return rows_copy
