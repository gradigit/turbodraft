#!/usr/bin/env python3
import argparse
import datetime as dt
import json
import pathlib
import re
import subprocess
from typing import List, Dict, Tuple, Any


def load_jsonl(path: pathlib.Path) -> List[dict]:
    rows: List[dict] = []
    with path.open("r", encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if line:
                rows.append(json.loads(line))
    return rows


def load_text(path: pathlib.Path) -> str:
    return path.read_text(encoding="utf-8")


def fill_template(template: str, values: Dict[str, str]) -> str:
    out = template
    for k, v in values.items():
        out = out.replace("{{" + k + "}}", v)
    return out


def parse_json_from_text(text: str) -> dict:
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


def run_codex(prompt: str, model: str, reasoning_effort: str, schema_path: pathlib.Path, timeout_s: int) -> Tuple[dict, str, dict[str, Any] | None]:
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
    last_msg = None
    error = None
    last_usage: dict[str, Any] | None = None
    for line in proc.stdout.splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            ev = json.loads(line)
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
            error = ev.get("message")
        elif t == "turn.failed":
            error = (ev.get("error") or {}).get("message") or error
    if error:
        raise RuntimeError(error)
    if proc.returncode != 0:
        raise RuntimeError(f"codex exit={proc.returncode} stderr={proc.stderr.strip()}")
    if not last_msg:
        raise RuntimeError("missing agent_message")
    data = parse_json_from_text(last_msg)
    return data, last_msg, last_usage


def add_usage(acc: dict[str, float], usage: Any) -> None:
    if not isinstance(usage, dict):
        return
    for key in ("input_tokens", "output_tokens", "reasoning_tokens", "total_tokens", "cost_usd"):
        val = usage.get(key)
        if isinstance(val, (int, float)):
            acc[key] = acc.get(key, 0.0) + float(val)


def reverse_winner(w: str) -> str:
    if w == "A":
        return "B"
    if w == "B":
        return "A"
    return "Tie"


def mode_winner(votes: List[str]) -> str:
    normalized = [v if v in {"A", "B", "Tie"} else "Tie" for v in votes]
    counts = {label: normalized.count(label) for label in ("A", "B", "Tie")}
    max_count = max(counts.values()) if counts else 0
    winners = [label for label, count in counts.items() if count == max_count]
    if len(winners) != 1:
        return "Tie"
    return winners[0]


def main() -> int:
    ap = argparse.ArgumentParser(description="Assess LLM judge symmetry and repeatability")
    ap.add_argument("--repo", default=".")
    ap.add_argument("--dataset", default="bench/prompt_eval/datasets/judge_calibration_pairs.jsonl")
    ap.add_argument("--judge-prompt", default="bench/prompt_eval/prompts/judge_pairwise_v1.md")
    ap.add_argument("--schema", default="bench/prompt_eval/schemas/judge_decision.schema.json")
    ap.add_argument("--model", default="gpt-5.4")
    ap.add_argument("--reasoning-effort", default="xhigh")
    ap.add_argument("--repeats", type=int, default=2)
    ap.add_argument("--max-cases", type=int, default=0)
    ap.add_argument("--timeout", type=int, default=240)
    ap.add_argument("--out-dir", default="")
    args = ap.parse_args()

    repo = pathlib.Path(args.repo).resolve()
    dataset = load_jsonl((repo / args.dataset).resolve())
    if args.max_cases > 0:
        dataset = dataset[: args.max_cases]
    prompt_template = load_text((repo / args.judge_prompt).resolve())
    schema_path = (repo / args.schema).resolve()

    stamp = dt.datetime.now().strftime("%Y%m%d-%H%M%S")
    out_dir = pathlib.Path(args.out_dir).resolve() if args.out_dir else (repo / "bench" / "prompt_eval" / "reports" / f"judge_symmetry_{stamp}")
    out_dir.mkdir(parents=True, exist_ok=True)

    rows = []
    usage_totals: dict[str, float] = {}

    for pair in dataset:
        # Forward repeats (A,B)
        forward = []
        for r in range(args.repeats):
            p = fill_template(prompt_template, {
                "preset": pair["preset"],
                "draft_prompt": pair["draft_prompt"],
                "candidate_a": pair["candidate_a"],
                "candidate_b": pair["candidate_b"],
            })
            try:
                dec, raw, usage = run_codex(p, args.model, args.reasoning_effort, schema_path, args.timeout)
                add_usage(usage_totals, usage)
                forward.append(dec.get("winner", "Tie"))
            except Exception:
                forward.append("Tie")

        # Reverse repeats (B,A)
        reverse = []
        for r in range(args.repeats):
            p = fill_template(prompt_template, {
                "preset": pair["preset"],
                "draft_prompt": pair["draft_prompt"],
                "candidate_a": pair["candidate_b"],
                "candidate_b": pair["candidate_a"],
            })
            try:
                dec, raw, usage = run_codex(p, args.model, args.reasoning_effort, schema_path, args.timeout)
                add_usage(usage_totals, usage)
                reverse.append(dec.get("winner", "Tie"))
            except Exception:
                reverse.append("Tie")

        # Metrics per case
        forward_mode = mode_winner(forward)
        reverse_mode = mode_winner(reverse)
        reverse_mapped = reverse_winner(reverse_mode)

        within_forward_agreement = forward.count(forward_mode) / len(forward)
        within_reverse_agreement = reverse.count(reverse_mode) / len(reverse)
        symmetric = (forward_mode == reverse_mapped)

        rows.append({
            "case_id": pair["id"],
            "preset": pair["preset"],
            "expected_winner": pair.get("expected_winner", ""),
            "forward_votes": forward,
            "forward_mode": forward_mode,
            "reverse_votes": reverse,
            "reverse_mode": reverse_mode,
            "reverse_mode_mapped_to_original": reverse_mapped,
            "within_forward_agreement": round(within_forward_agreement, 3),
            "within_reverse_agreement": round(within_reverse_agreement, 3),
            "symmetric": symmetric,
        })

    n = len(rows)
    symmetry_rate = sum(1 for r in rows if r["symmetric"]) / max(1, n)
    forward_consistency = sum(r["within_forward_agreement"] for r in rows) / max(1, n)
    reverse_consistency = sum(r["within_reverse_agreement"] for r in rows) / max(1, n)

    expected_non_tie = [r for r in rows if r["expected_winner"] in {"A", "B"}]
    expected_match = 0
    for r in expected_non_tie:
        if r["forward_mode"] == r["expected_winner"]:
            expected_match += 1
    expected_match_rate = expected_match / max(1, len(expected_non_tie))

    summary = {
        "timestamp": dt.datetime.now().isoformat(),
        "model": args.model,
        "reasoning_effort": args.reasoning_effort,
        "judge_prompt": str((repo / args.judge_prompt).resolve()),
        "schema": str(schema_path),
        "repeats_per_orientation": args.repeats,
        "n_cases": n,
        "symmetry_rate": round(symmetry_rate, 4),
        "forward_repeat_agreement": round(forward_consistency, 4),
        "reverse_repeat_agreement": round(reverse_consistency, 4),
        "expected_non_tie_match_rate": round(expected_match_rate, 4),
        "usage_totals": {k: round(v, 4) for k, v in usage_totals.items()},
    }

    (out_dir / "by_case.jsonl").write_text("\n".join(json.dumps(r, ensure_ascii=False) for r in rows) + "\n", encoding="utf-8")
    (out_dir / "summary.json").write_text(json.dumps(summary, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    print(json.dumps({"ok": True, "out_dir": str(out_dir), "summary": summary}, ensure_ascii=False, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
