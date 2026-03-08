# TurboDraft Human Adjudication — AI Assist Appendix

> Open this only **after** recording the blind human decision.

## Case — `batch2v2_coding_sidebar_en_dev`
- Gemini pick: A
- Gemini confidence: Medium
- Gemini rationale: Candidate A provides a slightly more precise execution contract regarding state isolation and explicitly guides the agent on how to handle remaining coupling without fabricating constraints.
- Blind winner (immutable for lock): ______
- Post-assist winner (secondary): ______
- Human final status after viewing AI:
  - [ ] Kept original decision
  - [ ] Changed decision after AI review
  - [ ] Still unresolved; escalate to tie-break

## Case — `batch2v2_refactor_provider_en_tune`
- Gemini pick: A
- Gemini confidence: High
- Gemini rationale: Candidate A strictly preserves the draft's specific focus on judge-baseline changes, whereas Candidate B fabricates scope by unnecessarily expanding the refactor to include drafting roles and shared baseline data.
- Blind winner (immutable for lock): ______
- Post-assist winner (secondary): ______
- Human final status after viewing AI:
  - [ ] Kept original decision
  - [ ] Changed decision after AI review
  - [ ] Still unresolved; escalate to tie-break

## Case — `batch2v2_review_ci_en_sealed`
- Gemini pick: B
- Gemini confidence: High
- Gemini rationale: Candidate B is tighter, more concise, and avoids introducing unprompted concepts like 'config/runtime/doc drift' found in Candidate A.
- Blind winner (immutable for lock): ______
- Post-assist winner (secondary): ______
- Human final status after viewing AI:
  - [ ] Kept original decision
  - [ ] Changed decision after AI review
  - [ ] Still unresolved; escalate to tie-break

## Case — `batch2v2_research_judge_en_dev`
- Gemini pick: B
- Gemini confidence: High
- Gemini rationale: Candidate B establishes a stronger execution contract by explicitly directing the agent to avoid sycophancy, test against counter-hypotheses, and clearly define failure modes, making it a more robust evaluation prompt.
- Blind winner (immutable for lock): ______
- Post-assist winner (secondary): ______
- Human final status after viewing AI:
  - [ ] Kept original decision
  - [ ] Changed decision after AI review
  - [ ] Still unresolved; escalate to tie-break

## Case — `batch2v2_brainstorm_arch_en_tune`
- Gemini pick: A
- Gemini confidence: Medium
- Gemini rationale: Candidate A provides richer structural guidance by explicitly prompting for a contrarian option and specifying how to observe tradeoffs, ensuring a more rigorous and exhaustive brainstorm.
- Blind winner (immutable for lock): ______
- Post-assist winner (secondary): ______
- Human final status after viewing AI:
  - [ ] Kept original decision
  - [ ] Changed decision after AI review
  - [ ] Still unresolved; escalate to tie-break

## Case — `batch2v2_legacy_en_dev`
- Gemini pick: A
- Gemini confidence: Medium
- Gemini rationale: Candidate A provides more concrete operational guidance, such as specifying a 'diff check' and explicitly targeting 'redundancy', forming a stronger execution contract.
- Blind winner (immutable for lock): ______
- Post-assist winner (secondary): ______
- Human final status after viewing AI:
  - [ ] Kept original decision
  - [ ] Changed decision after AI review
  - [ ] Still unresolved; escalate to tie-break

