#!/usr/bin/env python3
from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import json
import itertools
import math
import pathlib
import re
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
    for line in path.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if line:
            rows.append(json.loads(line))
    return rows


def load_text(path: pathlib.Path) -> str:
    return path.read_text(encoding="utf-8")


def fill_template(template: str, values: dict[str, str]) -> str:
    out = template
    for k, v in values.items():
        out = out.replace("{{" + k + "}}", v)
    return out


def sha256_file(path: pathlib.Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
        while True:
            chunk = f.read(1024 * 1024)
            if not chunk:
                break
            h.update(chunk)
    return h.hexdigest()


def parse_json_from_text(text: str) -> dict[str, Any]:
    text = text.strip()
    text = re.sub(r"^```(?:json)?\s*", "", text)
    text = re.sub(r"\s*```$", "", text)
    try:
        return json.loads(text)
    except json.JSONDecodeError:
        s = text.find("{")
        e = text.rfind("}")
        if s >= 0 and e > s:
            return json.loads(text[s : e + 1])
        raise


def run_codex(prompt: str, model: str, reasoning_effort: str, schema_path: pathlib.Path, timeout_s: int) -> tuple[dict[str, Any], dict[str, Any] | None]:
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
    proc = subprocess.run(cmd, input=prompt, text=True, capture_output=True, timeout=timeout_s)
    last_msg: str | None = None
    last_usage: dict[str, Any] | None = None
    error_msg: str | None = None
    for raw in proc.stdout.splitlines():
        raw = raw.strip()
        if not raw:
            continue
        try:
            ev = json.loads(raw)
        except json.JSONDecodeError:
            continue
        t = ev.get("type")
        usage = ev.get("usage")
        if isinstance(usage, dict):
            last_usage = usage
        if t == "item.completed":
            item = ev.get("item") or {}
            if item.get("type") == "agent_message":
                last_msg = item.get("text", "")
        elif t == "error":
            error_msg = ev.get("message")
        elif t == "turn.failed":
            error_msg = (ev.get("error") or {}).get("message") or error_msg
    if error_msg:
        raise RuntimeError(error_msg)
    if proc.returncode != 0:
        raise RuntimeError(f"codex exit={proc.returncode}: {proc.stderr.strip()}")
    if not last_msg:
        raise RuntimeError("missing codex agent_message")
    return parse_json_from_text(last_msg), last_usage


def run_claude(prompt: str, model: str, effort: str, schema_obj: dict[str, Any], timeout_s: int) -> tuple[dict[str, Any], dict[str, Any] | None]:
    cmd = [
        "claude",
        "-p",
        "--model",
        model,
        "--effort",
        effort,
        "--disable-slash-commands",
        "--tools",
        "",
        "--output-format",
        "json",
        "--json-schema",
        json.dumps(schema_obj, separators=(",", ":")),
        prompt,
    ]
    proc = subprocess.run(cmd, text=True, capture_output=True, timeout=timeout_s)
    if proc.returncode != 0:
        raise RuntimeError(f"claude exit={proc.returncode}: {proc.stderr.strip()}")
    raw = proc.stdout.strip()
    if not raw:
        raise RuntimeError("empty claude output")
    data = json.loads(raw)
    if isinstance(data, dict):
        events = [data]
    else:
        events = data
    usage_payload: dict[str, Any] | None = None
    for ev in reversed(events):
        if ev.get("type") == "result" and isinstance(ev.get("usage"), dict):
            usage_payload = ev.get("usage")
            break
    for ev in reversed(events):
        if ev.get("type") == "result":
            so = ev.get("structured_output")
            if isinstance(so, dict):
                return so, usage_payload
    for ev in reversed(events):
        if ev.get("type") == "assistant":
            msg = ev.get("message") or {}
            for content in msg.get("content") or []:
                if content.get("type") == "tool_use":
                    inp = content.get("input")
                    if isinstance(inp, dict):
                        return inp, usage_payload
    raise RuntimeError("no structured output in claude response")


def winner_label(decision: dict[str, Any]) -> str:
    w = str(decision.get("winner", "")).strip()
    if w in {"A", "B", "Tie"}:
        return w
    wl = w.lower()
    if wl == "tie":
        return "Tie"
    return "Tie"


def safe_run_primary(
    prompt: str,
    model: str,
    reasoning_effort: str,
    schema_path: pathlib.Path,
    timeout_s: int,
) -> tuple[str, str | None, dict[str, Any] | None]:
    try:
        decision, usage = run_codex(prompt, model, reasoning_effort, schema_path, timeout_s)
        return winner_label(decision), None, usage
    except Exception as exc:
        return "Tie", str(exc), None


def safe_run_shadow(
    prompt: str,
    runner: str,
    model: str,
    reasoning_effort: str,
    schema_path: pathlib.Path,
    schema_obj: dict[str, Any],
    timeout_s: int,
) -> tuple[str, str | None, dict[str, Any] | None]:
    try:
        if runner == "codex":
            decision, usage = run_codex(prompt, model, reasoning_effort, schema_path, timeout_s)
        else:
            decision, usage = run_claude(prompt, model, reasoning_effort, schema_obj, timeout_s)
        return winner_label(decision), None, usage
    except Exception as exc:
        return "Tie", str(exc), None


def add_usage(acc: dict[str, float], usage: Any) -> None:
    if not isinstance(usage, dict):
        return
    for key in ("input_tokens", "output_tokens", "reasoning_tokens", "total_tokens", "cost_usd"):
        val = usage.get(key)
        if isinstance(val, (int, float)):
            acc[key] = acc.get(key, 0.0) + float(val)


def ci_wilson_upper(successes: int, total: int, z: float = 1.959963984540054) -> float:
    if total <= 0:
        return 1.0
    p = successes / total
    denom = 1 + (z**2 / total)
    center = p + (z**2 / (2 * total))
    margin = z * math.sqrt((p * (1 - p) / total) + (z**2 / (4 * total**2)))
    return (center + margin) / denom


def triad_has_violation(wab: str, wbc: str, wac: str) -> tuple[bool, int]:
    # Directed edges among labels A/B/C.
    edges: set[tuple[str, str]] = set()
    if wab == "A":
        edges.add(("A", "B"))
    elif wab == "B":
        edges.add(("B", "A"))
    if wbc == "A":
        edges.add(("B", "C"))
    elif wbc == "B":
        edges.add(("C", "B"))
    if wac == "A":
        edges.add(("A", "C"))
    elif wac == "B":
        edges.add(("C", "A"))

    chain_count = 0
    violation = False
    for x, y, z in itertools.permutations(["A", "B", "C"], 3):
        if (x, y) in edges and (y, z) in edges:
            chain_count += 1
            if (x, z) not in edges:
                violation = True
    return violation, chain_count


def build_pair_prompt(template: str, row: dict[str, Any], candidate_a: str, candidate_b: str) -> str:
    return fill_template(
        template,
        {
            "preset": str(row.get("preset", "")),
            "draft_prompt": str(row.get("draft_prompt", "")),
            "candidate_a": candidate_a,
            "candidate_b": candidate_b,
        },
    )


def main() -> int:
    ap = argparse.ArgumentParser(description="Generate strict judge-audit artifact.")
    ap.add_argument("--repo", default=".")
    ap.add_argument("--provider-contract", default=DEFAULT_PROVIDER_CONTRACT)
    ap.add_argument("--gate-manifest", default="bench/prompt_eval/config/gate_manifest.v1.json")
    ap.add_argument("--calibration-summary", default="")
    ap.add_argument("--judge-prompt", default="")
    ap.add_argument("--judge-schema", default="bench/prompt_eval/schemas/judge_decision.schema.json")
    ap.add_argument("--primary-model", default=None)
    ap.add_argument("--primary-reasoning-effort", default=None)
    ap.add_argument("--shadow-runner", choices=["claude", "codex"], default=None)
    ap.add_argument("--shadow-model", default=None)
    ap.add_argument("--shadow-reasoning-effort", default=None)
    ap.add_argument("--triad-dataset", default="bench/prompt_eval/datasets/calibration/judge_triads.jsonl")
    ap.add_argument("--shadow-dataset", default="bench/prompt_eval/datasets/calibration/shadow_spotcheck_pairs.jsonl")
    ap.add_argument("--gold-dataset", default="bench/prompt_eval/datasets/calibration/gold_anchor_pairs.jsonl")
    ap.add_argument("--max-triads", type=int, default=0)
    ap.add_argument("--max-shadow-pairs", type=int, default=0)
    ap.add_argument("--max-gold-pairs", type=int, default=0)
    ap.add_argument("--timeout", type=int, default=240)
    ap.add_argument("--simulate-no-provider", action="store_true")
    ap.add_argument("--out", required=True)
    args = ap.parse_args()

    repo = pathlib.Path(args.repo).resolve()
    out_path = pathlib.Path(args.out).resolve()
    out_path.parent.mkdir(parents=True, exist_ok=True)

    try:
        provider_contract = load_provider_contract(repo, args.provider_contract)
    except ProviderContractError as exc:
        raise RuntimeError(f"provider contract load failed: {exc}") from exc
    providers = provider_contract["providers"]
    primary_provider = providers["judge_primary"]
    shadow_provider = providers["judge_shadow"]
    primary_model = args.primary_model or primary_provider["model"]
    primary_reasoning_effort = args.primary_reasoning_effort or primary_provider["reasoning_effort"]
    shadow_runner = args.shadow_runner or shadow_provider["runner"]
    shadow_model = args.shadow_model or shadow_provider["model"]
    shadow_reasoning_effort = args.shadow_reasoning_effort or shadow_provider["reasoning_effort"]

    if args.simulate_no_provider:
        fixture = repo / "bench/prompt_eval/fixtures/judge_audit.simulated.json"
        if fixture.exists():
            out_path.write_text(fixture.read_text(encoding="utf-8"), encoding="utf-8")
            print(json.dumps({"ok": True, "simulated": True, "out": str(out_path)}, indent=2))
            return 0

    gate = load_json((repo / args.gate_manifest).resolve())
    judge_t = gate["judge_thresholds"]
    floor_t = gate["minimum_sample_floors"]
    required_families = list(gate.get("required_preset_families") or [])

    schema_path = (repo / args.judge_schema).resolve()
    schema_obj = load_json(schema_path)

    judge_prompt_path: pathlib.Path
    if args.judge_prompt:
        judge_prompt_path = (repo / args.judge_prompt).resolve()
    elif args.calibration_summary:
        csum = load_json((repo / args.calibration_summary).resolve())
        rp = ((csum.get("recommended_prompt") or {}).get("prompt") or "").strip()
        judge_prompt_path = pathlib.Path(rp).resolve() if rp else (repo / "bench/prompt_eval/prompts/judge_pairwise_v3.md").resolve()
    else:
        judge_prompt_path = (repo / "bench/prompt_eval/prompts/judge_pairwise_v3.md").resolve()

    judge_template = load_text(judge_prompt_path)

    triad_path = (repo / args.triad_dataset).resolve()
    shadow_path = (repo / args.shadow_dataset).resolve()
    gold_path = (repo / args.gold_dataset).resolve()
    triads = load_jsonl(triad_path)
    shadows = load_jsonl(shadow_path)
    golds = load_jsonl(gold_path)
    if args.max_triads > 0:
        triads = triads[: args.max_triads]
    if args.max_shadow_pairs > 0:
        shadows = shadows[: args.max_shadow_pairs]
    if args.max_gold_pairs > 0:
        golds = golds[: args.max_gold_pairs]

    reason_codes: list[str] = []
    transitivity_rows: list[dict[str, Any]] = []
    shadow_rows: list[dict[str, Any]] = []
    gold_rows: list[dict[str, Any]] = []
    usage_totals: dict[str, float] = {}

    # Transitivity audit on triads using primary judge.
    triads_with_chain = 0
    triad_violations = 0
    family_chain_counts: dict[str, int] = {fam: 0 for fam in required_families}
    family_violation_counts: dict[str, int] = {fam: 0 for fam in required_families}
    for row in triads:
        family = str(row.get("preset", ""))
        pab = build_pair_prompt(judge_template, row, row["candidate_a"], row["candidate_b"])
        pbc = build_pair_prompt(judge_template, row, row["candidate_b"], row["candidate_c"])
        pac = build_pair_prompt(judge_template, row, row["candidate_a"], row["candidate_c"])
        wab, err_ab, usage_ab = safe_run_primary(pab, primary_model, primary_reasoning_effort, schema_path, args.timeout)
        wbc, err_bc, usage_bc = safe_run_primary(pbc, primary_model, primary_reasoning_effort, schema_path, args.timeout)
        wac, err_ac, usage_ac = safe_run_primary(pac, primary_model, primary_reasoning_effort, schema_path, args.timeout)
        add_usage(usage_totals, usage_ab)
        add_usage(usage_totals, usage_bc)
        add_usage(usage_totals, usage_ac)
        violation, chain_count = triad_has_violation(wab, wbc, wac)
        if chain_count > 0:
            triads_with_chain += 1
            if family in family_chain_counts:
                family_chain_counts[family] += 1
            if violation:
                triad_violations += 1
                if family in family_violation_counts:
                    family_violation_counts[family] += 1
        transitivity_rows.append(
            {
                "id": row["id"],
                "preset": family,
                "winner_ab": wab,
                "winner_bc": wbc,
                "winner_ac": wac,
                "chain_count": chain_count,
                "violation": violation,
                **({"error_ab": err_ab} if err_ab else {}),
                **({"error_bc": err_bc} if err_bc else {}),
                **({"error_ac": err_ac} if err_ac else {}),
            }
        )

    violation_rate = (triad_violations / triads_with_chain) if triads_with_chain > 0 else 0.0
    violation_ci95_upper = ci_wilson_upper(triad_violations, triads_with_chain if triads_with_chain > 0 else 1)
    trans_threshold = float(judge_t["transitivity_violation_ci_upper_max"])
    triad_floor = int(floor_t.get("judge_triads_per_family_min", 1))
    trans_ok = violation_ci95_upper <= trans_threshold
    per_family_transitivity: dict[str, Any] = {}
    per_family_floor_ok = True
    for family in required_families:
        fam_n = int(family_chain_counts.get(family, 0))
        fam_v = int(family_violation_counts.get(family, 0))
        fam_rate = (fam_v / fam_n) if fam_n > 0 else 0.0
        fam_ci = ci_wilson_upper(fam_v, fam_n if fam_n > 0 else 1)
        fam_floor_ok = fam_n >= triad_floor
        if not fam_floor_ok:
            per_family_floor_ok = False
            reason_codes.append(f"JUDGE_AUDIT_SAMPLE_FLOOR_FAIL:triads:{family}")
        fam_ok = fam_floor_ok and fam_ci <= trans_threshold
        if not fam_ok:
            trans_ok = False
        per_family_transitivity[family] = {
            "triads_with_chain": fam_n,
            "violations": fam_v,
            "violation_rate": round(fam_rate, 6),
            "violation_ci95_upper": round(fam_ci, 6),
            "floor_ok": fam_floor_ok,
            "ok": fam_ok,
        }
    if triads_with_chain < triad_floor:
        reason_codes.append("JUDGE_AUDIT_SAMPLE_FLOOR_FAIL:triads_global")
    if not trans_ok:
        reason_codes.append("JUDGE_AUDIT_CHECK_FAIL:transitivity")

    # Shadow drift audit (primary vs shadow).
    shadow_disagreements = 0
    for row in shadows:
        prompt = build_pair_prompt(judge_template, row, row["candidate_a"], row["candidate_b"])
        primary, err_primary, usage_primary = safe_run_primary(
            prompt,
            primary_model,
            primary_reasoning_effort,
            schema_path,
            args.timeout,
        )
        shadow, err_shadow, usage_shadow = safe_run_shadow(
            prompt,
            shadow_runner,
            shadow_model,
            shadow_reasoning_effort,
            schema_path,
            schema_obj,
            args.timeout,
        )
        add_usage(usage_totals, usage_primary)
        add_usage(usage_totals, usage_shadow)
        disagree = primary != shadow
        if disagree:
            shadow_disagreements += 1
        shadow_rows.append(
            {
                "id": row["id"],
                "primary_winner": primary,
                "shadow_winner": shadow,
                "disagree": disagree,
                **({"error_primary": err_primary} if err_primary else {}),
                **({"error_shadow": err_shadow} if err_shadow else {}),
            }
        )
    shadow_n = len(shadows)
    shadow_rate = shadow_disagreements / max(1, shadow_n)
    shadow_threshold = float(judge_t["shadow_judge_disagreement_max"])
    shadow_floor = int(floor_t.get("shadow_spotcheck_pairs_min", 1))
    shadow_ok = shadow_n >= shadow_floor and shadow_rate <= shadow_threshold
    if shadow_n < shadow_floor:
        reason_codes.append("JUDGE_AUDIT_SAMPLE_FLOOR_FAIL:shadow_pairs")
    if not shadow_ok:
        reason_codes.append("JUDGE_AUDIT_CHECK_FAIL:shadow_drift")

    # Gold anchor accuracy audit (primary judge vs expected).
    gold_correct = 0
    for row in golds:
        prompt = build_pair_prompt(judge_template, row, row["candidate_a"], row["candidate_b"])
        primary, err_primary, usage_primary = safe_run_primary(
            prompt,
            primary_model,
            primary_reasoning_effort,
            schema_path,
            args.timeout,
        )
        add_usage(usage_totals, usage_primary)
        expected = str(row.get("expected_winner", "Tie"))
        correct = primary == expected
        if correct:
            gold_correct += 1
        gold_rows.append(
            {
                "id": row["id"],
                "expected_winner": expected,
                "primary_winner": primary,
                "correct": correct,
                **({"error_primary": err_primary} if err_primary else {}),
            }
        )
    gold_n = len(golds)
    gold_acc = gold_correct / max(1, gold_n)
    gold_threshold = float(judge_t["gold_anchor_accuracy_min"])
    gold_floor = int(floor_t.get("gold_anchor_pairs_min", 1))
    gold_ok = gold_n >= gold_floor and gold_acc >= gold_threshold
    if gold_n < gold_floor:
        reason_codes.append("JUDGE_AUDIT_SAMPLE_FLOOR_FAIL:gold_pairs")
    if not gold_ok:
        reason_codes.append("JUDGE_AUDIT_CHECK_FAIL:gold_anchor")

    out = {
        "version": "v1",
        "generated_at": dt.datetime.now(dt.timezone.utc).isoformat(),
        "mode": "real",
        "judge_prompt": str(judge_prompt_path),
        "providers": {
            "primary": {
                "runner": "codex",
                "model": primary_model,
                "reasoning_effort": primary_reasoning_effort,
            },
            "shadow": {
                "runner": shadow_runner,
                "model": shadow_model,
                "reasoning_effort": shadow_reasoning_effort,
            },
        },
        "datasets": {
            "triads_path": str(triad_path),
            "triads_sha256": sha256_file(triad_path),
            "triads_n": len(triads),
            "shadow_pairs_path": str(shadow_path),
            "shadow_pairs_sha256": sha256_file(shadow_path),
            "shadow_pairs_n": len(shadows),
            "gold_pairs_path": str(gold_path),
            "gold_pairs_sha256": sha256_file(gold_path),
            "gold_pairs_n": len(golds),
        },
        "metrics": {
            "transitivity": {
                "triads_evaluated": triads_with_chain,
                "violations": triad_violations,
                "violation_rate": round(violation_rate, 6),
                "violation_ci95_upper": round(violation_ci95_upper, 6),
                "threshold_max": trans_threshold,
                "per_family": per_family_transitivity,
                "ok": trans_ok,
            },
            "shadow_drift": {
                "pairs_evaluated": shadow_n,
                "disagreements": shadow_disagreements,
                "disagreement_rate": round(shadow_rate, 6),
                "threshold_max": shadow_threshold,
                "ok": shadow_ok,
            },
            "gold_anchor": {
                "pairs_evaluated": gold_n,
                "correct": gold_correct,
                "accuracy": round(gold_acc, 6),
                "threshold_min": gold_threshold,
                "ok": gold_ok,
            },
        },
        "usage_totals": {k: round(v, 4) for k, v in usage_totals.items()},
        "checks": {
            "transitivity_ok": trans_ok,
            "shadow_drift_ok": shadow_ok,
            "gold_anchor_ok": gold_ok,
        },
        "reason_codes": reason_codes,
    }

    # Write diagnostics beside audit file.
    diag_dir = out_path.parent
    (diag_dir / "judge_audit_transitivity_by_case.jsonl").write_text(
        "\n".join(json.dumps(r, ensure_ascii=False) for r in transitivity_rows) + "\n",
        encoding="utf-8",
    )
    (diag_dir / "judge_audit_shadow_by_case.jsonl").write_text(
        "\n".join(json.dumps(r, ensure_ascii=False) for r in shadow_rows) + "\n",
        encoding="utf-8",
    )
    (diag_dir / "judge_audit_gold_by_case.jsonl").write_text(
        "\n".join(json.dumps(r, ensure_ascii=False) for r in gold_rows) + "\n",
        encoding="utf-8",
    )

    out_path.write_text(json.dumps(out, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    print(json.dumps({"ok": True, "out": str(out_path), "audit": out}, indent=2, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
