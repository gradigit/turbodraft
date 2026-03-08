#!/usr/bin/env python3
import argparse
import datetime as dt
import json
import pathlib
import re
import subprocess
from typing import List, Dict, Tuple, Any


def load_text(path: pathlib.Path) -> str:
    return path.read_text(encoding="utf-8")


def load_jsonl(path: pathlib.Path) -> List[dict]:
    rows: List[dict] = []
    with path.open("r", encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            rows.append(json.loads(line))
    return rows


def run_codex_exec(
    prompt: str,
    model: str,
    output_schema: pathlib.Path | None = None,
    timeout_s: int = 240,
    reasoning_effort: str | None = None,
) -> tuple[str, dict[str, Any] | None]:
    cmd = [
        "codex",
        "exec",
        "-m",
        model,
        "--json",
        "--skip-git-repo-check",
        "-",
    ]
    if reasoning_effort:
        cmd[5:5] = ["-c", f'model_reasoning_effort="{reasoning_effort}"']
    if output_schema is not None:
        cmd.extend(["--output-schema", str(output_schema)])

    proc = subprocess.run(
        cmd,
        input=prompt,
        text=True,
        capture_output=True,
        timeout=timeout_s,
    )

    last_agent_message: str | None = None
    last_usage: dict[str, Any] | None = None
    error_message: str | None = None

    for raw in proc.stdout.splitlines():
        raw = raw.strip()
        if not raw:
            continue
        try:
            ev = json.loads(raw)
        except json.JSONDecodeError:
            continue
        ev_type = ev.get("type")
        usage = ev.get("usage")
        if isinstance(usage, dict):
            last_usage = usage
        if ev_type == "item.completed":
            item = ev.get("item") or {}
            if item.get("type") == "agent_message":
                last_agent_message = item.get("text", "")
        elif ev_type == "error":
            error_message = ev.get("message")
        elif ev_type == "turn.failed":
            error_message = (ev.get("error") or {}).get("message") or error_message

    if proc.returncode != 0 and not error_message:
        error_message = f"codex exited {proc.returncode}: {proc.stderr.strip()}"
    if error_message:
        raise RuntimeError(error_message)
    if not last_agent_message:
        raise RuntimeError("No judge output")
    return last_agent_message, last_usage


def add_usage(acc: dict[str, float], usage: Any) -> None:
    if not isinstance(usage, dict):
        return
    for key in ("input_tokens", "output_tokens", "reasoning_tokens", "total_tokens", "cost_usd"):
        val = usage.get(key)
        if isinstance(val, (int, float)):
            acc[key] = acc.get(key, 0.0) + float(val)


def fill_template(template: str, values: Dict[str, str]) -> str:
    out = template
    for k, v in values.items():
        out = out.replace("{{" + k + "}}", v)
    return out


def parse_judge_json(text: str) -> dict:
    text = text.strip()
    text = re.sub(r"^```(?:json)?\s*", "", text)
    text = re.sub(r"\s*```$", "", text)
    try:
        return json.loads(text)
    except json.JSONDecodeError:
        start = text.find("{")
        end = text.rfind("}")
        if start >= 0 and end > start:
            return json.loads(text[start : end + 1])
        raise


def accuracy(gold: List[str], pred: List[str]) -> float:
    if not gold:
        return 0.0
    return sum(1 for g, p in zip(gold, pred) if g == p) / len(gold)


def per_label_recall(gold: List[str], pred: List[str], label: str) -> float:
    idx = [i for i, g in enumerate(gold) if g == label]
    if not idx:
        return 0.0
    return sum(1 for i in idx if pred[i] == label) / len(idx)


def select_recommended_prompt(
    prompt_summaries: List[dict[str, Any]],
    preferred_prompt: pathlib.Path | None = None,
) -> dict[str, Any] | None:
    if not prompt_summaries:
        return None

    preferred_resolved = str(preferred_prompt.resolve()) if preferred_prompt is not None else ""

    def rank(summary: dict[str, Any]) -> tuple[float, float, float, int]:
        prompt_path = str(summary.get("prompt", ""))
        is_preferred = 1 if (preferred_resolved and prompt_path == preferred_resolved) else 0
        return (
            float(summary.get("accuracy", 0.0) or 0.0),
            float(-(summary.get("invalid_count", 0) or 0)),
            float(summary.get("recall_Tie", 0.0) or 0.0),
            is_preferred,
        )

    ordered = sorted(prompt_summaries, key=rank, reverse=True)
    return ordered[0]


def main() -> int:
    ap = argparse.ArgumentParser(description="Calibrate judge prompts against labeled pair dataset")
    ap.add_argument("--repo", default=".")
    ap.add_argument("--model", default="gpt-5.4")
    ap.add_argument("--reasoning-effort", default="xhigh")
    ap.add_argument("--dataset", default="bench/prompt_eval/datasets/judge_calibration_pairs.jsonl")
    ap.add_argument("--max-pairs", type=int, default=0)
    ap.add_argument("--schema", default="bench/prompt_eval/schemas/judge_decision.schema.json")
    ap.add_argument("--judge-prompts", nargs="+", default=[
        "bench/prompt_eval/prompts/judge_pairwise_v1.md",
        "bench/prompt_eval/prompts/judge_pairwise_v2.md",
        "bench/prompt_eval/prompts/judge_pairwise_v3.md",
    ])
    ap.add_argument(
        "--preferred-prompt",
        default="bench/prompt_eval/prompts/judge_pairwise_v2.md",
        help="Tie-break preference when prompt scores are equal.",
    )
    ap.add_argument("--out-dir", default="")
    ap.add_argument("--timeout", type=int, default=240)
    args = ap.parse_args()

    repo = pathlib.Path(args.repo).resolve()
    dataset_path = (repo / args.dataset).resolve()
    schema_path = (repo / args.schema).resolve()
    prompt_paths = [(repo / p).resolve() for p in args.judge_prompts]
    preferred_prompt = (repo / args.preferred_prompt).resolve() if args.preferred_prompt else None

    stamp = dt.datetime.now().strftime("%Y%m%d-%H%M%S")
    out_dir = pathlib.Path(args.out_dir).resolve() if args.out_dir else (repo / "bench" / "prompt_eval" / "reports" / f"judge_calibration_{stamp}")
    out_dir.mkdir(parents=True, exist_ok=True)

    pairs = load_jsonl(dataset_path)
    if args.max_pairs > 0:
        pairs = pairs[: args.max_pairs]

    report_rows: List[dict] = []
    prompt_summaries: List[dict] = []
    usage_totals: dict[str, float] = {}

    for ppath in prompt_paths:
        template = load_text(ppath)
        gold: List[str] = []
        pred: List[str] = []
        invalid = 0
        by_case: List[dict] = []

        for pair in pairs:
            judge_prompt = fill_template(template, {
                "preset": pair["preset"],
                "draft_prompt": pair["draft_prompt"],
                "candidate_a": pair["candidate_a"],
                "candidate_b": pair["candidate_b"],
            })

            try:
                raw, usage = run_codex_exec(
                    judge_prompt,
                    model=args.model,
                    output_schema=schema_path,
                    timeout_s=args.timeout,
                    reasoning_effort=args.reasoning_effort,
                )
                decision = parse_judge_json(raw)
                add_usage(usage_totals, usage)
                winner = decision.get("winner", "")
                if winner not in {"A", "B", "Tie"}:
                    winner = ""
            except Exception as e:
                decision = {"error": str(e)}
                winner = ""

            if not winner:
                invalid += 1
                winner = "Tie"

            expected = pair["expected_winner"]
            gold.append(expected)
            pred.append(winner)

            row = {
                "prompt": ppath.name,
                "case_id": pair["id"],
                "expected": expected,
                "predicted": winner,
                "correct": expected == winner,
                "decision": decision,
            }
            by_case.append(row)
            report_rows.append(row)

        acc = accuracy(gold, pred)
        recall_a = per_label_recall(gold, pred, "A")
        recall_b = per_label_recall(gold, pred, "B")
        recall_t = per_label_recall(gold, pred, "Tie")

        summary = {
            "prompt": str(ppath),
            "n": len(pairs),
            "accuracy": round(acc, 4),
            "invalid_count": invalid,
            "recall_A": round(recall_a, 4),
            "recall_B": round(recall_b, 4),
            "recall_Tie": round(recall_t, 4),
        }
        prompt_summaries.append(summary)

        (out_dir / f"{ppath.stem}_by_case.jsonl").write_text(
            "\n".join(json.dumps(r, ensure_ascii=False) for r in by_case) + "\n",
            encoding="utf-8",
        )

    best = select_recommended_prompt(prompt_summaries, preferred_prompt=preferred_prompt)

    summary = {
        "timestamp": dt.datetime.now().isoformat(),
        "model": args.model,
        "reasoning_effort": args.reasoning_effort,
        "dataset": str(dataset_path),
        "schema": str(schema_path),
        "prompt_summaries": prompt_summaries,
        "recommended_prompt": best,
        "usage_totals": {k: round(v, 4) for k, v in usage_totals.items()},
    }

    (out_dir / "all_results.jsonl").write_text("\n".join(json.dumps(r, ensure_ascii=False) for r in report_rows) + "\n", encoding="utf-8")
    (out_dir / "summary.json").write_text(json.dumps(summary, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")

    print(json.dumps({"ok": True, "out_dir": str(out_dir), "summary": summary}, ensure_ascii=False, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
