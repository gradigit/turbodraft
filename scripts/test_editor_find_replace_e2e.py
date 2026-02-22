#!/usr/bin/env python3
from __future__ import annotations

import argparse
import datetime as dt
import pathlib
import subprocess
import sys
import time


def apple_escape(text: str) -> str:
    return text.replace("\\", "\\\\").replace('"', '\\"')


def run_osascript(script: str, timeout_s: float = 12.0) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        ["osascript"],
        input=script,
        text=True,
        capture_output=True,
        timeout=timeout_s,
    )


def capture_screenshot(path: pathlib.Path) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    subprocess.run(["screencapture", "-x", str(path)], check=False)


def write_artifact(path: pathlib.Path, text: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text, encoding="utf-8")


def drive_find_replace(query: str, replacement: str, timeout_s: float = 12.0) -> None:
    script = f"""
tell application "System Events"
  set targetProc to missing value
  set startedAt to (current date)
  repeat while ((current date) - startedAt) < 8
    if exists process "TurboDraft" then
      set targetProc to process "TurboDraft"
    else if exists process "turbodraft-app" then
      set targetProc to process "turbodraft-app"
    else if exists process "turbodraft-app.debug" then
      set targetProc to process "turbodraft-app.debug"
    else
      set targetProc to missing value
    end if
    if targetProc is not missing value then
      tell targetProc to set frontmost to true
      exit repeat
    end if
    delay 0.02
  end repeat
  if targetProc is missing value then error "TurboDraft process not found"

  delay 0.06
  keystroke "f" using command down
  delay 0.08
  keystroke "{apple_escape(query)}"
  delay 0.08
  keystroke "f" using {{command down, option down}}
  delay 0.08
  keystroke "{apple_escape(replacement)}"
  delay 0.10
  tell targetProc
    click button "Replace All" of window 1
  end tell
  delay 0.12
  key code 53 -- ESC closes find
  delay 0.05
  keystroke "s" using command down
  delay 0.05
  keystroke "w" using command down
end tell
"""
    cp = run_osascript(script, timeout_s=timeout_s)
    if cp.returncode != 0:
        detail = cp.stderr.strip() or cp.stdout.strip() or "osascript failed"
        if "Not authorized to send Apple events" in detail:
            detail += " (grant Accessibility + Automation permissions)"
        raise RuntimeError(detail)


def main() -> int:
    ap = argparse.ArgumentParser(description="E2E UI smoke test for TurboDraft inline find/replace.")
    ap.add_argument("--repo-root", default=str(pathlib.Path(__file__).resolve().parents[1]))
    ap.add_argument("--fixture", default=None, help="Fixture file path (default: tmp/search-replace-e2e.md)")
    ap.add_argument("--query", default="alpha")
    ap.add_argument("--replacement", default="omega")
    ap.add_argument("--timeout-s", type=float, default=14.0)
    ap.add_argument("--artifacts-dir", default=None, help="Write screenshots/logs here")
    ap.add_argument("--keep-fixture", action="store_true", help="Keep generated fixture file")
    args = ap.parse_args()

    repo = pathlib.Path(args.repo_root).resolve()
    fixture = pathlib.Path(args.fixture).resolve() if args.fixture else (repo / "tmp" / "search-replace-e2e.md")
    fixture.parent.mkdir(parents=True, exist_ok=True)
    fixture.write_text("alpha beta alpha ALPHA\n", encoding="utf-8")

    timestamp = dt.datetime.now().strftime("%Y%m%d-%H%M%S")
    artifacts = pathlib.Path(args.artifacts_dir).resolve() if args.artifacts_dir else (repo / "tmp" / "ui-e2e-artifacts" / timestamp)
    pre_shot = artifacts / "before.png"
    post_shot = artifacts / "after.png"
    err_log = artifacts / "error.log"
    result_dump = artifacts / "fixture.txt"

    turbodraft_bin = repo / ".build" / "release" / "turbodraft"
    if not turbodraft_bin.exists():
        raise SystemExit(f"missing binary: {turbodraft_bin}")

    proc = subprocess.Popen([str(turbodraft_bin), str(fixture)], cwd=str(repo))
    try:
        time.sleep(0.25)
        capture_screenshot(pre_shot)
        drive_find_replace(query=args.query, replacement=args.replacement, timeout_s=args.timeout_s)
        capture_screenshot(post_shot)
        try:
            proc.wait(timeout=max(2.0, args.timeout_s))
        except subprocess.TimeoutExpired:
            proc.terminate()
            proc.wait(timeout=2.0)
            raise RuntimeError("turbodraft process did not exit after UI sequence")
    except Exception as exc:
        write_artifact(err_log, f"{exc}\n")
        try:
            write_artifact(result_dump, fixture.read_text(encoding="utf-8"))
        except Exception:
            pass
        print("ui_find_replace_e2e\tFAIL", file=sys.stderr)
        print(str(exc), file=sys.stderr)
        print(f"artifacts\t{artifacts}", file=sys.stderr)
        return 1
    finally:
        if proc.poll() is None:
            proc.terminate()
            try:
                proc.wait(timeout=2.0)
            except subprocess.TimeoutExpired:
                proc.kill()

    result = fixture.read_text(encoding="utf-8")
    expected = "omega beta omega omega"
    if result.strip("\n") != expected:
        write_artifact(err_log, "fixture mismatch\n")
        write_artifact(result_dump, result)
        print("ui_find_replace_e2e\tFAIL", file=sys.stderr)
        print(f"expected: {expected!r}", file=sys.stderr)
        print(f"actual:   {result!r}", file=sys.stderr)
        print(f"artifacts\t{artifacts}", file=sys.stderr)
        return 1

    print("ui_find_replace_e2e\tPASS")
    print(f"fixture\t{fixture}")
    if not args.keep_fixture:
        try:
            fixture.unlink()
        except FileNotFoundError:
            pass
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
