---
name: requires
description: 플러그인이 선언한 필요 API 키를 볼트와 대조해 미등록 키를 찾아낸다. 트리거 — "/tikeytaka:requires", "이 플러그인 키 뭐 필요해?", "플러그인 키 점검해줘", "설치했는데 키 뭐 넣어야 해?", 플러그인 설치 직후 키 준비 확인.
---

# tikeytaka:requires — 플러그인 키 선언 대조

코어 CLI: `bash "${CLAUDE_PLUGIN_ROOT}/bin/tkt"` (이하 `tkt`)

```bash
tkt requires                      # 설치된 마켓/캐시 플러그인 전체 스캔
tkt requires <플러그인경로> ...    # 특정 경로만
```

플러그인 루트의 `keys.json` 선언을 읽어 볼트와 대조한다. 사람이 "이 플러그인엔 무슨 키가 필요하더라"를 기억할 필요를 없앤다.

## 출력 읽는 법

- `ok` — 볼트에 있음. 추가 조치 불필요.
- `MISSING` — **필수인데 미등록**. exit code 4.
- `opt` — 선택 항목 미등록. 그 기능만 비활성일 뿐 정상 동작.

`MISSING`이 있으면 발급 링크(`docs`)를 안내하고 **add 스킬 절차로 유도**한다. 키 값을 채팅으로 받지 않는다 — `tkt setp <service>`(터미널 숨김 입력)를 사용자가 직접 실행하게 한다.

## keys.json 스키마

플러그인 루트(`plugin.json`과 같은 층)에 둔다. `plugin.json`에는 넣지 않는다 — Claude Code 매니페스트 스키마에 없는 키를 넣으면 `claude plugin validate`가 실패한다.

```json
{
  "keys": [
    {
      "service": "gemini-api-key",
      "env": "GEMINI_API_KEY",
      "required": true,
      "description": "이미지 분석 호출용",
      "docs": "https://aistudio.google.com/apikey"
    }
  ]
}
```

| 필드 | 필수 | 뜻 |
|---|---|---|
| `service` | O | 볼트 안의 서비스명 (`tkt list` 출력과 일치해야 함) |
| `env` | | 이 키가 들어갈 환경변수명 — 보고에 표시 |
| `required` | | 기본 `true`. `false`면 `opt`로 보고하고 exit code에 영향 없음 |
| `description` | | 용도 한 줄 |
| `docs` | | 발급 페이지 URL — 미등록일 때 사용자에게 안내됨 |

## 주의

- `service`는 볼트의 실제 이름이다. 새로 짓지 말고 `tkt list`로 기존 이름을 먼저 확인해 맞춘다 (같은 키가 두 이름으로 갈라지면 전파가 깨진다).
- 이 명령은 **읽기 전용**이다. 키를 자동 등록하거나 `.env`를 건드리지 않는다. 전파는 `map-add` + `sync` 소관.
- python3가 필요하다 (keys.json 파싱).
