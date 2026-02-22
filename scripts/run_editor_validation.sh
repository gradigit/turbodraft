#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

printf '[phase-1] core search logic tests\n'
swift test --filter TextSearchEngineTests

printf '\n[phase-2] app workflow smoke test\n'
swift test --filter EditorWorkflowTests/testFindReplaceAndImageSmoke

printf '\n[phase-3] markdown behavior tests\n'
swift test --filter MarkdownEnterBehaviorTests
swift test --filter MarkdownOrderedListRenumberingTests

printf '\n[phase-4] perf guardrail tests\n'
swift test --filter TextSearchEngineTests/testSummarizeMatchesLargeInputWithinBudget
swift test --filter TextSearchEngineTests/testReplaceAllLargeInputWithinBudget

if [[ "${RUN_AX_UI:-0}" == "1" ]]; then
  printf '\n[phase-5] AX E2E automation\n'
  python3 scripts/test_editor_find_replace_e2e.py --keep-fixture
  python3 scripts/test_editor_undo_redo_e2e.py
else
  printf '\n[phase-5] AX E2E automation skipped (set RUN_AX_UI=1 to enable)\n'
fi

printf '\neditor validation suite complete\n'
