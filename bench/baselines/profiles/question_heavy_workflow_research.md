## Objective
Evaluate and improve our TurboDraft prompt-engineering process through parallel research in three areas:
1. Whether the current prompt-review checklist is trustworthy and objective.
2. Whether the current baseline prompt format is optimal for prompt-engineering tasks (not PRDs, epics, user stories, or task planning workflows).
3. Whether an iterative TurboDraft workflow (chat panel, agent asks questions, user answers, repeated refinements, then save and inject into CLI) is the right product direction.

## Scope and Constraints
- Run the research tracks in parallel using the study skill.
- Focus strictly on prompt engineering quality and workflow effectiveness.
- Keep conclusions evidence-based, actionable, and implementable in TurboDraft.
- Do not use or expose sensitive data; request redacted examples if needed.

## User Inputs to Request
- Ask the user to share the current prompt-review checklist and any scoring criteria used with it.
- Request that the user provide the current baseline prompt format being evaluated.
- Ask the user for 2-3 real examples where the current prompt process worked well and where it failed.
- Confirm which downstream AI systems/models the engineered prompts are intended for.
- Confirm workflow constraints: acceptable question volume, iteration limits, and definition of “ready to inject into CLI.”

## Agent Decisions / Recommendations
- Decision: Clarifying-question strategy during prompt refinement.
  - Option A: Ask many upfront questions; higher quality potential, higher user effort.
  - Option B: Ask minimal questions; faster flow, higher risk of weak outputs.
  - Option C: Progressive questioning (start minimal, expand only when needed); balanced quality/effort with added orchestration complexity.
  - Information that changes the decision: user tolerance for interaction length, prompt complexity, and required output quality.
- Decision: Standard baseline prompt format for prompt-only work.
  - Option A: Strict template; consistency and auditability, less flexibility.
  - Option B: Free-form structure; flexibility and speed, less consistency.
  - Option C: Hybrid format (required core + optional modules); balanced consistency/flexibility with moderate complexity.
  - Information that changes the decision: use-case variability, model consistency, and token constraints.
- Decision: TurboDraft session mode.
  - Option A: Single-pass refinement; fastest, lower ceiling on quality.
  - Option B: Iterative chat-panel refinement; best quality potential, slower sessions.
  - Option C: Single-pass default with optional iterative mode; balanced UX with more product complexity.
  - Information that changes the decision: measured quality gains per iteration and target session duration.

## Implementation Steps
1. Gather missing context using the User Inputs to Request list.
2. Launch three parallel research tracks: checklist objectivity, baseline prompt format effectiveness, and iterative workflow effectiveness.
3. Evaluate findings with a shared rubric (objectivity, reproducibility, quality impact, user effort, implementation complexity).
4. Select recommendations using the decision framework in Agent Decisions / Recommendations.
5. Produce a concrete TurboDraft recommendation package covering checklist updates, prompt format standard, and workflow mode.
6. Define validation metrics and a lightweight test plan to verify whether the recommended workflow improves prompt outcomes.

## Deliverables
- A concise, source-backed research summary for each track.
- A recommendation to keep, revise, or replace the current review checklist.
- A recommended baseline prompt format for prompt-engineering tasks with rationale.
- A recommended TurboDraft workflow for iterative refinement and final CLI injection.

## Acceptance Criteria
- All three research tracks are completed with credible evidence.
- Recommendations clearly state chosen options and rejected alternatives with tradeoffs.
- The final workflow explicitly supports iterative refinement and a clear save-and-inject endpoint.
- The output is concise, actionable, and implementation-ready.