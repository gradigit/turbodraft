#!/usr/bin/env python3
from __future__ import annotations

import argparse
import pathlib
import subprocess
import sys
import time


def run_osascript(script: str, timeout_s: float = 12.0) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        ["osascript"],
        input=script,
        text=True,
        capture_output=True,
        timeout=timeout_s,
    )


def set_frontmost(timeout_s: float = 10.0) -> None:
    script = """
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
end tell
"""
    cp = run_osascript(script, timeout_s=timeout_s)
    if cp.returncode != 0:
        raise RuntimeError(cp.stderr.strip() or cp.stdout.strip() or "could not focus TurboDraft")


def send_key(ch: str, modifiers: str = "", timeout_s: float = 8.0) -> None:
    if modifiers:
        script = f'tell application "System Events" to keystroke "{ch}" using {{{modifiers}}}'
    else:
        script = f'tell application "System Events" to keystroke "{ch}"'
    cp = run_osascript(script, timeout_s=timeout_s)
    if cp.returncode != 0:
        raise RuntimeError(cp.stderr.strip() or cp.stdout.strip() or f"failed keystroke {ch}")


def type_text(text: str, timeout_s: float = 8.0) -> None:
    safe = text.replace("\\", "\\\\").replace('"', '\\"')
    script = f'tell application "System Events" to keystroke "{safe}"'
    cp = run_osascript(script, timeout_s=timeout_s)
    if cp.returncode != 0:
        raise RuntimeError(cp.stderr.strip() or cp.stdout.strip() or "failed typing text")


def set_clipboard(text: str) -> None:
    cp = subprocess.run(["pbcopy"], input=text, text=True, capture_output=True)
    if cp.returncode != 0:
        raise RuntimeError(cp.stderr.strip() or "failed to set clipboard")


def copy_editor_text() -> str:
    send_key("a", modifiers="command down")
    time.sleep(0.03)
    send_key("c", modifiers="command down")
    time.sleep(0.03)
    cp = subprocess.run(["pbpaste"], text=True, capture_output=True)
    return cp.stdout


def assert_editor_text(expected: str, label: str) -> None:
    actual = copy_editor_text().strip("\n")
    if actual != expected:
        raise AssertionError(f"{label}: expected={expected!r} actual={actual!r}")


def wait_for_editor_text(expected: str, timeout_s: float = 3.0) -> None:
    end = time.time() + timeout_s
    last = ""
    while time.time() < end:
        try:
            last = copy_editor_text().strip("\n")
            if last == expected:
                return
        except Exception:
            pass
        time.sleep(0.06)
    raise RuntimeError(f"editor did not reach expected initial text {expected!r}; last={last!r}")


def main() -> int:
    ap = argparse.ArgumentParser(description="E2E undo/redo timeline smoke test for TurboDraft")
    ap.add_argument("--repo-root", default=str(pathlib.Path(__file__).resolve().parents[1]))
    ap.add_argument("--fixture", default=None)
    ap.add_argument("--timeout-s", type=float, default=14.0)
    args = ap.parse_args()

    repo = pathlib.Path(args.repo_root).resolve()
    fixture = pathlib.Path(args.fixture).resolve() if args.fixture else (repo / "tmp" / "undo-redo-e2e.md")
    fixture.parent.mkdir(parents=True, exist_ok=True)
    fixture.write_text("draft\n", encoding="utf-8")

    turbodraft_bin = repo / ".build" / "release" / "turbodraft"
    if not turbodraft_bin.exists():
        raise SystemExit(f"missing binary: {turbodraft_bin}")

    proc = subprocess.Popen([str(turbodraft_bin), str(fixture)], cwd=str(repo))
    try:
      time.sleep(0.25)
      set_frontmost(timeout_s=args.timeout_s)
      wait_for_editor_text("draft")

      send_key("a", modifiers="command down")
      set_clipboard("improved1")
      send_key("v", modifiers="command down")
      time.sleep(0.05)
      type_text(" + edit1")
      time.sleep(0.05)

      send_key("a", modifiers="command down")
      set_clipboard("improved2")
      send_key("v", modifiers="command down")
      time.sleep(0.05)
      type_text(" + edit2")
      time.sleep(0.06)
      assert_editor_text("improved2 + edit2", "after edits")

      send_key("z", modifiers="command down")
      time.sleep(0.05)
      assert_editor_text("improved2", "undo 1")
      send_key("z", modifiers="command down")
      time.sleep(0.05)
      assert_editor_text("improved1 + edit1", "undo 2")
      send_key("z", modifiers="command down")
      time.sleep(0.05)
      assert_editor_text("improved1", "undo 3")
      send_key("z", modifiers="command down")
      time.sleep(0.05)
      assert_editor_text("draft", "undo 4")

      send_key("z", modifiers="command down, shift down")
      time.sleep(0.05)
      assert_editor_text("improved1", "redo 1")
      send_key("z", modifiers="command down, shift down")
      time.sleep(0.05)
      assert_editor_text("improved1 + edit1", "redo 2")
      send_key("z", modifiers="command down, shift down")
      time.sleep(0.05)
      assert_editor_text("improved2", "redo 3")
      send_key("z", modifiers="command down, shift down")
      time.sleep(0.05)
      assert_editor_text("improved2 + edit2", "redo 4")

      send_key("s", modifiers="command down")
      time.sleep(0.03)
      send_key("w", modifiers="command down")

      try:
          proc.wait(timeout=max(2.0, args.timeout_s))
      except subprocess.TimeoutExpired:
          proc.terminate()
          proc.wait(timeout=2.0)
          raise RuntimeError("turbodraft process did not exit after undo/redo sequence")
    except Exception as exc:
      print("ui_undo_redo_e2e\tFAIL", file=sys.stderr)
      print(str(exc), file=sys.stderr)
      return 1
    finally:
      if proc.poll() is None:
          proc.terminate()
          try:
              proc.wait(timeout=2.0)
          except subprocess.TimeoutExpired:
              proc.kill()

    final_text = fixture.read_text(encoding="utf-8").strip("\n")
    if final_text != "improved2 + edit2":
      print("ui_undo_redo_e2e\tFAIL", file=sys.stderr)
      print(f"expected final='improved2 + edit2' actual={final_text!r}", file=sys.stderr)
      return 1

    print("ui_undo_redo_e2e\tPASS")
    print(f"fixture\t{fixture}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
