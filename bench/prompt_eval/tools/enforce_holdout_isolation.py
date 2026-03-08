#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import os
import pathlib
import sys


def main() -> int:
    ap = argparse.ArgumentParser(description="Enforce holdout access policy")
    ap.add_argument("--phase", required=True)
    ap.add_argument("--config", default="")
    ap.add_argument("--allow-env", default="PROMPT_EVAL_ALLOW_HOLDOUT")
    args = ap.parse_args()

    phase = args.phase
    is_holdout_phase = phase in {"phaseF_holdout", "holdout"}

    cfg_path = pathlib.Path(args.config).resolve() if args.config else None
    cfg_text = cfg_path.read_text(encoding="utf-8") if cfg_path and cfg_path.exists() else ""
    touches_holdout = "datasets/holdout" in cfg_text or "split: holdout" in cfg_text or "holdout" in (cfg_path.name if cfg_path else "")

    allow = os.environ.get(args.allow_env, "0") == "1"

    errors: list[str] = []
    if touches_holdout and not is_holdout_phase:
        errors.append("holdout config access attempted outside holdout phase")
    if is_holdout_phase and not allow:
        errors.append(f"{args.allow_env}=1 required for holdout phase")

    out = {
        "ok": len(errors) == 0,
        "phase": phase,
        "config": str(cfg_path) if cfg_path else None,
        "touches_holdout": touches_holdout,
        "holdout_phase": is_holdout_phase,
        "allow_holdout_env": allow,
        "errors": errors,
    }
    print(json.dumps(out, indent=2, ensure_ascii=False))
    return 0 if not errors else 2


if __name__ == "__main__":
    raise SystemExit(main())
