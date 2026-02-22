# Next Release Prep Checklist

Target: next TurboDraft release after benchmark-suite cleanup and docs refresh.

## Release blockers

- [ ] Rebuild prompt-engineering benchmark suite from scratch (fixtures, scoring, CI workflow).
- [ ] Finalize README media assets:
  - [ ] Demo video
  - [ ] Main app screenshot
  - [ ] Small claude-pager screenshot
- [ ] Confirm benchmark freeze values on release candidate build.

## Validation

- [ ] `swift build -c release`
- [ ] `swift test`
- [ ] `scripts/run_editor_validation.sh`
- [ ] `python3 scripts/bench_open_close_suite.py --cycles 20 --warmup 1 --retries 2`
- [ ] `python3 scripts/bench_open_close_real_cli.py --cycles 20 --warmup 1 --trigger-mode cgevent`

## Release packaging

- [ ] Update changelog entries under `Unreleased`
- [ ] Tag release version
- [ ] Publish release notes with benchmark context (API vs real Ctrl+G interpretation)
