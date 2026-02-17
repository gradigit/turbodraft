## Objective
Implement the approved plan in this repository from start to finish.

## Constraints
- Stay within the plan’s scope; do not add unrelated refactors or feature changes.
- If any plan item is ambiguous or conflicts with the codebase, stop and clarify before proceeding.
- Preserve unrelated existing local changes.
- Avoid destructive operations unless the user explicitly approves them.

## User Inputs to Request
- Ask the user to provide the exact plan text (or a link) to implement.
- Confirm the target branch/worktree and related issue/PR, if applicable.
- Request acceptance criteria per plan item, or confirm that matching the plan exactly is sufficient.
- Confirm non-negotiable constraints (required libraries, performance limits, deadlines, and explicit out-of-scope items).

## Implementation Steps
1. Gather the missing plan details and constraints, then restate the confirmed scope in concise bullets.
2. Convert the plan into an ordered task list and map each task to affected files/modules.
3. Implement tasks in sequence, keeping each change directly tied to a plan item.
4. Run relevant validations after major changes (tests, lint, type checks, or focused manual checks) and fix regressions.
5. Verify completion against each plan item and acceptance criterion, marking any deferred items with reasons.
6. Provide a final delivery summary with changed files, validation outcomes, and remaining risks or follow-ups.

## Done When
- All in-scope plan items are implemented or explicitly deferred with justification.
- Validation has been executed and results are clearly reported.
- The final summary is clear enough for the user to review and approve quickly.