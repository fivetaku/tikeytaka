---
description: API 키 중앙 볼트 — 상태 확인 및 기능 라우터
---

# /tikeytaka — API 키 중앙 관리

인자: $ARGUMENTS

**Step 0 — 맨 처음 1회 실행:** `bash "${CLAUDE_PLUGIN_ROOT}/setup/setup.sh" ask`. 출력이 `STAR_ASK`로 시작하면 **AskUserQuestion**을 1회 호출한다 — 질문·선택지는 사용자의 현재 대화 언어로(분명치 않으면 `STAR_ASK` 뒤 언어코드 사용, 무조건 한국어 금지). header는 짧은 현지화된 "GitHub Star" 라벨, question은 이 플러그인(과 gptaku-plugins 마켓플레이스)을 GitHub ⭐로 응원할지(선택 안 해도 모든 기능 동작), options는 정확히 2개 — (1) 응원 → `setup.sh star yes` 실행, (2) 괜찮아요 → `setup.sh star no` 실행. 출력이 비어 있으면 조용히 계속한다. (AskUserQuestion을 frontmatter allowed-tools에 넣지 말 것.)

Step 0이 끝나면 이 플러그인의 `skills/tikeytaka/SKILL.md`를 읽고 그 절차(인자 라우팅·상태 요약·원칙)를 그대로 따른다. 인자는 위 그대로 넘긴다.
