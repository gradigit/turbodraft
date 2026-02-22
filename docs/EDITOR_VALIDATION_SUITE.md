# Editor Validation Suite (Phase Execution)

This project now has a phased validation flow for editor/search/improve behaviors.

## Run all phases

```bash
scripts/run_editor_validation.sh
```

To include Accessibility-driven UI automation phases:

```bash
RUN_AX_UI=1 scripts/run_editor_validation.sh
```

## Phase breakdown

1. **Core search logic tests**
   - `TextSearchEngineTests`
2. **App workflow smoke**
   - `EditorWorkflowTests/testFindReplaceAndImageSmoke`
3. **Markdown behavior coverage**
   - `MarkdownEnterBehaviorTests`
   - `MarkdownOrderedListRenumberingTests`
4. **Performance guardrails**
   - `testSummarizeMatchesLargeInputWithinBudget`
   - `testReplaceAllLargeInputWithinBudget`
5. **AX E2E automation (optional/local)**
   - `scripts/test_editor_find_replace_e2e.py`
   - `scripts/test_editor_undo_redo_e2e.py`

## Notes

- AX phases require macOS Accessibility + Automation permissions.
- The AX scripts are intended for local validation (not CI runners).
- If phase 5 fails, inspect artifacts under `tmp/ui-e2e-artifacts/`.
