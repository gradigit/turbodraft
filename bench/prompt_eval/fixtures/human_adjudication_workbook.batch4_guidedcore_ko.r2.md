# TurboDraft Guided Blind Core Workbook — Batch4 KO R2

## Instructions
- This is the **guided blind core** lane for lock-grade human evidence.
- Use the checklist as a reading aid, but make your own decision.
- Do not open any AI-assisted workbook or appendix first.
- Required per case: winner + confidence.
- Optional per case: short note.
- If both candidates seem acceptable, use the checklist to identify which one is less likely to fail the draft.
- If you still genuinely cannot tell, choose `Tie` with `Low` confidence.

## Confidence rubric
- **High** — one candidate clearly satisfies the draft better with fewer obvious risks.
- **Medium** — likely winner, but there is a real tradeoff or ambiguity.
- **Low** — still hard to distinguish from text alone.

<!-- TD_CASE_META {"case_id": "batch3blind_ko_005", "preset_family": "coding", "language_tag": "ko-KR", "split": "tune", "display_map": {"A": "candidate_b", "B": "candidate_a"}, "seed": "11", "rater_label": "eta", "lane": "guided_blind_core", "content_sha256": "58ef2d75db46cb3215ef702e067ab81c785f15b31d6146d2265f34ef9b5c1c6e", "integrity_sha256": "7a73529f87fdbb75de2cc43a9f0fd5c9406eda0782d27a3e4c6e0e7cde030ba6"} -->
## Case 01

### Draft
```text
TurboDraft에서 Escape 키가 현재 아무 역할도 없을 때만 editor를 닫도록 해줘. 기존 취소/포커스 해제 같은 동작은 유지되어야 해.
```
### Why this case matters
> The key question is which candidate better protects existing Escape behavior while only adding close behavior where Escape currently does nothing meaningful.
### Quick checklist
- 기존 취소/포커스 해제/모달 종료 같은 Escape 의미를 유지하는가?
- 의미 없는 editor 문맥에서만 close를 연결하는가?
- 우선순위 충돌이나 포커스/모달 예외를 다루는가?
### Disqualifiers to look for
- Escape 전역 의미를 재정의함
- 기존 취소/포커스 해제 동작을 약화시킴
- 어떤 문맥에서 close가 허용되는지 불명확함
### Candidate A
```text
Goal / Objective
Escape 키 동작을 정리하되, 기존 취소/포커스 해제 의미를 유지하면서 의미 없는 Escape만 editor close로 연결한다.

Scope and Constraints
- 기존 취소, 포커스 해제, 모달 종료 같은 Escape 동작은 유지한다.
- close 동작은 기존 의미 있는 Escape가 없는 editor 문맥에만 연결한다.
- 동작 우선순위를 설명 가능하게 유지한다.

Implementation Steps
1. 현재 Escape 처리 경로와 우선순위를 확인한다.
2. 기존 의미 있는 Escape가 없는 문맥만 close 대상으로 제한한다.
3. 포커스/모달 상태별 예외를 문서화하고 회귀 테스트를 추가한다.
4. 우선순위 충돌이 있으면 동작을 넓히지 말고 보고한다.

Validation / Acceptance Checks
- 의미 없는 Escape만 editor를 닫는다.
- 기존 취소/포커스 해제 동작은 유지된다.
- 동작 경계가 테스트와 설명으로 확인된다.
```
### Candidate B
```text
Goal / Objective
Escape 키에 의미 있는 기존 바인딩이 없는 editor 문맥에서만 editor를 닫도록 구현한다.

Scope and Constraints
- 기존 취소, 포커스 해제, 모달 종료 같은 Escape 동작은 유지한다.
- Escape 우선순위를 바꾸면서 전역 의미를 재정의하지 않는다.
- 예측 가능한 동작이어야 한다.

Implementation Steps
1. 현재 Escape 처리 경로와 우선순위를 확인한다.
2. 기존 의미 있는 Escape 동작이 없는 editor 문맥에만 close를 연결한다.
3. 포커스/모달 상태 충돌 여부를 점검한다.
4. 회귀 테스트를 추가한다.

Validation / Acceptance Checks
- 의미 없는 Escape만 editor를 닫는다.
- 기존 취소/포커스 해제 동작은 유지된다.
- 충돌 문맥은 보고한다.
```
### Blind decision
Winner:
- [ ] A
- [ ] B
- [ ] Tie
- [ ] BothBad

Confidence:
- [ ] High
- [ ] Medium
- [ ] Low

Optional note:
> 

<!-- TD_CASE_META {"case_id": "batch3blind_ko_008", "preset_family": "pivot_kr_en_reason_ko", "language_tag": "ko-KR", "split": "tune", "display_map": {"A": "candidate_a", "B": "candidate_b"}, "seed": "11", "rater_label": "eta", "lane": "guided_blind_core", "content_sha256": "259d981f2118e00e1ee677db584914ad398fadf008718e21dbd1006f18962056", "integrity_sha256": "9fc00722816f843cd3da96c3488911f3472c6ca3adabd6f4016e01953b14d33c"} -->
## Case 02

### Draft
```text
한국어 사용자용 답변이 필요하지만, 품질은 영어 중심 추론 경로를 쓰는 것처럼 높게 유지하고 싶어. 최종 출력은 한국어만 나와야 해.
```
### Why this case matters
> The human only needs to check whether the prompt protects Korean-only final output while preserving the intended high-quality reasoning path.
### Quick checklist
- 최종 사용자 가시 출력이 한국어만 나오도록 유지하는가?
- 품질 향상을 위한 내부 영어 중심 추론 경로를 허용하되, 그 결과를 노출하지 않는가?
- 실행 프롬프트로 바로 쓸 수 있는 형태를 유지하는가?
### Disqualifiers to look for
- 최종 출력 언어가 섞이거나 불명확함
- 영어 내부 추론을 최종 출력에 노출함
- 다른 에이전트를 언급하거나 메타 지시가 섞임
### Candidate A
```text
Refine the request into a prompt that maximizes task quality while ensuring the final user-visible output remains Korean only.
- Preserve all user constraints and uncertainty.
- Emphasize execution quality over Korean surface polish alone.
- Keep the prompt directly usable by the downstream model.
- Do not expose intermediate reasoning, but allow the model to internally organize the task in the way that best preserves quality.
- Output only the final refined prompt text.
```
### Candidate B
```text
Refine the request into a prompt that maximizes task quality while ensuring the final user-visible output is Korean only.
- Preserve all user constraints and uncertainty.
- Optimize for high-quality task execution rather than Korean surface polish alone.
- Keep the prompt directly usable by the downstream model.
- Do not instruct the final output to reveal intermediate reasoning.
- Output only the final refined prompt text.
```
### Blind decision
Winner:
- [ ] A
- [ ] B
- [ ] Tie
- [ ] BothBad

Confidence:
- [ ] High
- [ ] Medium
- [ ] Low

Optional note:
> 

<!-- TD_CASE_META {"case_id": "batch3blind_ko_009", "preset_family": "pivot_kr_en_optimize_ko", "language_tag": "ko-KR", "split": "sealed_test", "display_map": {"A": "candidate_a", "B": "candidate_b"}, "seed": "11", "rater_label": "eta", "lane": "guided_blind_core", "content_sha256": "45276c07952a11c7af39ddee076cd7aaf79f5662d2c9c5f7ed87ef2d1fa3aa33", "integrity_sha256": "8c2d6fb6e92e0279905fd1397df155e68ce183e9d07dfd880fa731b91661dab0"} -->
## Case 03

### Draft
```text
한국어 사용자가 쓴 초안을 더 강한 실행용 프롬프트로 다듬어줘. 결과 프롬프트는 바로 다른 모델에 넣을 수 있어야 하고, 한국어로 동작해야 해.
```
### Why this case matters
> The winner should be the candidate that most safely turns the Korean draft into a stronger execution prompt without changing behavior or adding agent confusion.
### Quick checklist
- 한국어 초안을 바로 실행 가능한 더 강한 프롬프트로 만든다는 목적을 유지하는가?
- 원래 의도와 제약을 바꾸지 않고 강화하는가?
- 결과 프롬프트가 한국어로 동작해야 한다는 요구를 분명히 지키는가?
### Disqualifiers to look for
- 불필요한 범위 확장
- 메타 설명이나 다른 에이전트 언급
- 한국어 동작 요구를 약화시킴
### Candidate A
```text
다음 한국어 초안을 더 강한 실행용 프롬프트로 다듬는다.
- 원래 목표, 제약, 불확실성을 보존한다.
- 구조를 명확하게 만들되 불필요한 범위 확장은 하지 않는다.
- 최종 프롬프트는 한국어로 직접 사용 가능해야 한다.
- 정말 필요한 경우에만 누락 정보 요청을 별도 섹션으로 분리하고, 그 외에는 바로 실행 가능한 형태를 유지한다.
- 출력은 최종 정제 프롬프트 본문만 제공한다.
```
### Candidate B
```text
다음 한국어 초안을 더 강한 실행용 프롬프트로 다듬는다.
- 원래 목표, 제약, 불확실성을 보존한다.
- 구조를 명확하게 만들되 불필요한 범위 확장은 하지 않는다.
- 최종 프롬프트는 한국어로 직접 사용 가능해야 한다.
- 출력은 최종 정제 프롬프트 본문만 제공한다.
- 부족한 정보가 정말 필수일 때만 추가 질문 항목을 분리한다.
```
### Blind decision
Winner:
- [ ] A
- [ ] B
- [ ] Tie
- [ ] BothBad

Confidence:
- [ ] High
- [ ] Medium
- [ ] Low

Optional note:
> 
