# TurboDraft Human Adjudication Workbook — Batch 3 KO R1

## Instructions
- Make your blind decision in this file directly.
- Do not open any AI-assist appendix until the blind pass is finished.
- Required per case: winner + confidence.
- Optional per case: short note.
- Candidate order is randomized per case; do not infer quality from position.

## Confidence rubric
- **High** — clear winner; materially better on multiple important criteria.
- **Medium** — likely winner; better overall, but there is a real tradeoff or ambiguity.
- **Low** — close call; uncertain or difficult to distinguish.

<!-- TD_CASE_META {"case_id": "batch3blind_ko_005", "preset_family": "coding", "language_tag": "ko-KR", "split": "tune", "display_map": {"A": "candidate_a", "B": "candidate_b"}, "seed": "1", "rater_label": "beta", "integrity_sha256": "fbe2e3c8dc1df244c697fce96aa79551f9f8612c7f1f4230fd4912ebe1f5ee20"} -->
## Case 01

### Draft
```text
TurboDraft에서 Escape 키가 현재 아무 역할도 없을 때만 editor를 닫도록 해줘. 기존 취소/포커스 해제 같은 동작은 유지되어야 해.
```
### Candidate A
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
### Candidate B
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

<!-- TD_CASE_META {"case_id": "batch3blind_ko_006", "preset_family": "review", "language_tag": "ko-KR", "split": "tune", "display_map": {"A": "candidate_a", "B": "candidate_b"}, "seed": "1", "rater_label": "beta", "integrity_sha256": "ae053761d8a3799b558c71234330b737afbfca9699e2d0c3171df085fe1b2f1f"} -->
## Case 02

### Draft
```text
기존 프리셋 프롬프트들을 감사해서 실제 문제점과 누락을 짚어줘. 형식만 맞는지 보는 피상적인 리뷰는 원하지 않아.
```
### Candidate A
```text
Goal / Framing
기존 프리셋 프롬프트들을 감사해서 실제 문제점, 누락된 제약, 실사용상 혼동 지점을 구체적으로 식별한다.

Assumptions / Constraints
- 형식 준수 여부만 보는 피상적 리뷰는 피한다.
- 실제 사용 시 오작동할 수 있는 부분을 우선한다.
- 증거가 약하면 단정하지 않고 불확실성을 표시한다.

Open Questions
- 어떤 프리셋이 실사용 제약을 충분히 보존하지 못하는가?
- 구조는 맞아도 의미적으로 약한 지점은 어디인가?
- 사용자/모델 혼동을 일으킬 표현은 무엇인가?

Option Space / Tradeoffs
- 최소 수정으로 보완.
- 더 큰 구조 수정으로 혼동 감소.
- 문서/UX 보완.

Recommended Next Steps
- 프리셋별 실제 실패 모드를 적는다.
- 형식이 맞아도 의미가 약한 사례를 분리한다.
- 수정 우선순위를 위험 기준으로 정리한다.

Evaluation Criteria
- 실제 실패 가능성을 짚는다.
- 누락/혼동 지점이 구체적이다.
- 피상적 형식 점검으로 끝나지 않는다.
```
### Candidate B
```text
Goal / Framing
기존 프리셋 프롬프트들을 감사해서 실제 문제점, 누락된 제약, 그리고 형식이 맞아도 실사용에서 약한 지점을 구체적으로 식별한다.

Assumptions / Constraints
- 형식 준수 여부만 보는 피상적 리뷰는 피한다.
- 실제 사용 시 오작동하거나 오해를 부를 수 있는 부분을 우선한다.
- 증거가 약하면 단정하지 않고 불확실성을 표시한다.

Open Questions
- 어떤 프리셋이 실사용 제약을 충분히 보존하지 못하는가?
- 형식은 맞아도 의미적으로 약한 지점은 어디인가?
- 사용자/모델 혼동을 일으키는 표현은 무엇인가?

Option Space / Tradeoffs
- 최소 수정으로 보완.
- 더 큰 구조 수정으로 혼동 감소.
- 문서/UX 보완으로 리스크 완화.

Recommended Next Steps
- 프리셋별 실제 실패 모드를 적는다.
- 형식이 맞아도 의미가 약한 사례를 분리한다.
- 수정 우선순위를 실사용 위험 기준으로 정리한다.

Evaluation Criteria
- 실제 실패 가능성을 짚는다.
- 누락/혼동 지점이 구체적이다.
- 피상적 형식 점검으로 끝나지 않는다.
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

<!-- TD_CASE_META {"case_id": "batch3blind_ko_007", "preset_family": "research", "language_tag": "ko-KR", "split": "sealed_test", "display_map": {"A": "candidate_a", "B": "candidate_b"}, "seed": "1", "rater_label": "beta", "integrity_sha256": "c3d0e4f7750e00822fedd3d404ddbd8f7395e0793c6159e4070706db35cbed99"} -->
## Case 03

### Draft
```text
시스템 프롬프트 유출 자료 같은 건 참고만 하고, 정말 신뢰할 수 있는 프롬프트 소스를 중심으로 연구해줘.
```
### Candidate A
```text
Goal / Framing
신뢰 가능한 프롬프트 소스를 중심으로 연구하되, 유출/마이닝 자료는 1차 근거가 아니라 보조 참고로만 다룬다.

Assumptions / Constraints
- 공식 문서, 공식 프롬프트 아티팩트, 내부 검증 산출물을 우선한다.
- 유출/마이닝 자료는 독립 근거가 아니라 비교/경고 신호 수준으로만 활용한다.
- 신뢰도와 최신성을 구분해 설명한다.

Open Questions
- 어떤 소스가 1차 신뢰 근거가 되는가?
- 어떤 소스는 보조 참고로만 남겨야 하는가?
- 현재 프로젝트 목표에 직접 연결되는 소스는 무엇인가?

Option Space / Tradeoffs
- 공식 소스 중심 보수 경로.
- 보조 참고를 넓히되 검증 비용을 늘리는 경로.
- 내부 산출물과 공식 외부 소스를 결합하는 경로.

Recommended Next Steps
- 소스를 신뢰 등급별로 정리한다.
- 오래되었거나 반박된 정보는 배제/보관한다.
- 보조 참고가 1차 근거처럼 소비되지 않도록 적용 규칙을 적는다.

Evaluation Criteria
- 신뢰 등급이 분명하다.
- 1차 근거와 보조 참고가 섞이지 않는다.
- 최신성과 적용 가능성이 설명된다.
```
### Candidate B
```text
Goal / Framing
신뢰 가능한 프롬프트 소스를 중심으로 연구하되, 유출/마이닝 자료는 보조 참고로만 취급한다.

Assumptions / Constraints
- 공식 문서, 공식 프롬프트 아티팩트, 내부 검증 산출물을 우선한다.
- 유출/마이닝 자료는 독립 검증을 돕는 힌트 수준으로만 본다.
- 신뢰도와 최신성을 구분해 설명한다.

Open Questions
- 어떤 소스가 1차 신뢰 근거가 되는가?
- 어떤 소스는 보조 참고로만 다뤄야 하는가?
- 현재 프로젝트 목표에 직접 연결되는 소스는 무엇인가?

Option Space / Tradeoffs
- 공식 소스 중심 보수 경로.
- 보조 참고를 넓히되 검증 비용을 늘리는 경로.
- 내부 산출물과 공식 외부 소스를 결합하는 경로.

Recommended Next Steps
- 소스를 신뢰 등급별로 정리한다.
- 오래되었거나 반박된 정보는 배제/보관한다.
- 프로젝트 목표와 직접 연결되는 소스를 우선 적용한다.

Evaluation Criteria
- 신뢰 등급이 분명하다.
- 1차 근거와 보조 참고가 섞이지 않는다.
- 최신성과 적용 가능성이 설명된다.
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

<!-- TD_CASE_META {"case_id": "batch3blind_ko_008", "preset_family": "pivot_kr_en_reason_ko", "language_tag": "ko-KR", "split": "tune", "display_map": {"A": "candidate_b", "B": "candidate_a"}, "seed": "1", "rater_label": "beta", "integrity_sha256": "372738c5a451e4fc607d403ca285d61cd877a118e46df88637bd1250d4be96fe"} -->
## Case 04

### Draft
```text
한국어 사용자용 답변이 필요하지만, 품질은 영어 중심 추론 경로를 쓰는 것처럼 높게 유지하고 싶어. 최종 출력은 한국어만 나와야 해.
```
### Candidate A
```text
Refine the request into a prompt that maximizes task quality while ensuring the final user-visible output is Korean only.
- Preserve all user constraints and uncertainty.
- Optimize for high-quality task execution rather than Korean surface polish alone.
- Keep the prompt directly usable by the downstream model.
- Do not instruct the final output to reveal intermediate reasoning.
- Output only the final refined prompt text.
```
### Candidate B
```text
Refine the request into a prompt that maximizes task quality while ensuring the final user-visible output remains Korean only.
- Preserve all user constraints and uncertainty.
- Emphasize execution quality over Korean surface polish alone.
- Keep the prompt directly usable by the downstream model.
- Do not expose intermediate reasoning, but allow the model to internally organize the task in the way that best preserves quality.
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

<!-- TD_CASE_META {"case_id": "batch3blind_ko_009", "preset_family": "pivot_kr_en_optimize_ko", "language_tag": "ko-KR", "split": "sealed_test", "display_map": {"A": "candidate_a", "B": "candidate_b"}, "seed": "1", "rater_label": "beta", "integrity_sha256": "1f79bb43f1a58c0ff6d543808f59a646c1ad460e3b48291e0dd2b214f5756f20"} -->
## Case 05

### Draft
```text
한국어 사용자가 쓴 초안을 더 강한 실행용 프롬프트로 다듬어줘. 결과 프롬프트는 바로 다른 모델에 넣을 수 있어야 하고, 한국어로 동작해야 해.
```
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
