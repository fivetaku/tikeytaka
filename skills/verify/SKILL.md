---
name: verify
description: API 키의 생사를 등록 전·후에 실호출로 검증한다. 트리거 — "/tikeytaka:verify", "이 키 되는거냐", "키 검증해줘", "볼트 키 전부 확인", "등록된 키 작동하냐", 그리고 add/scan에서 키를 볼트에 넣기 직전(필수 선행). 죽은 키는 볼트에 등록하지 않는 것이 원칙이다.
---

# tikeytaka:verify — 키 생사 실측 검증

코어 CLI: `bash "${CLAUDE_PLUGIN_ROOT}/bin/tkt"` (이하 `tkt`)

## 원칙

1. **등록 전 검증 필수**: 죽은 키는 볼트에 들어가면 안 된다. add/scan은 이 절차를 통과한 값만 `set-stdin` 한다.
2. **무과금 엔드포인트만**: 모델 목록 조회, getMe, auth/key 조회 등. 과금 호출이 불가피하면 max_tokens=1 또는 빈 바디로 인증 단계만 확인.
3. **값 미출력**: 키는 셸 변수로만 다루고, 비교·보고는 sha256 앞 8자리 지문으로만.
4. **argv 미노출**: curl은 `--config -`(stdin)로 URL·헤더를 전달한다. `curl -H "Bearer $KEY"` 직접 사용 금지.

## HTTP 코드 해석 (오판 방지)

| 코드 | 판정 |
|---|---|
| 200 | 생존 |
| 400 | **키 유효** — 요청 형식 문제일 뿐 (빈 바디 프로브의 정상 응답) |
| 401 | 키 사망/무효 |
| 403 | **키 유효, 권한·플랜 문제** (예: 플랜 미구매) — 사망으로 오판하지 말 것 |
| 000 | 네트워크/프록시 차단 — **프록시 우회(`env -u HTTP_PROXY -u HTTPS_PROXY`) 후 재시도**하고 나서 판정 |

⚠️ 흔한 오판 2종: ① 로컬 프록시(teamclaude 등)가 api.anthropic.com을 차단해 000 → 우회 재시도 필수. ② rc 파일에서 값을 추출할 때 `$(command …)` 참조형이면 리터럴 문자열을 키로 보내게 됨 — 값이 `$(`로 시작하면 해당 명령을 실행해 실제 값을 얻어 검증한다.

## 알려진 프로바이더 레시피 (2026-08 실측 검증됨)

`np() { env -u HTTP_PROXY -u HTTPS_PROXY curl -s -m 10 --config - "$@"; }` 전제.

| 서비스 | 프로브 | 생존 판정 |
|---|---|---|
| Gemini/Google AI | GET `generativelanguage.googleapis.com/v1beta/models?key=K` | 200 |
| OpenAI | GET `api.openai.com/v1/models` + Bearer | 200 |
| Anthropic | GET `api.anthropic.com/v1/models` + `x-api-key` + `anthropic-version: 2023-06-01` (프록시 우회 필수) | 200 |
| OpenRouter | GET `openrouter.ai/api/v1/auth/key` + Bearer | 200 |
| Perplexity | POST `api.perplexity.ai/chat/completions` + Bearer, 빈 바디 `{}` | 400 (401=사망) |
| Telegram 봇 | GET `api.telegram.org/bot<K>/getMe` | `"ok":true` + 봇 이름 |
| data.go.kr (KMA/TOUR 등) | KMA getUltraSrtNcst에 serviceKey — **원본과 URL인코딩 양쪽 시도** | resultCode 00/10 (SERVICE_KEY_IS_NOT_REGISTERED=인코딩 재시도 후 판정) |
| DashScope/QwenCloud | 계약된 엔드포인트로 max_tokens=1 (예: `token-plan.*.maas.aliyuncs.com/apps/anthropic/v1/messages`) | 200/400; 403 Unpurchased=키 유효·플랜 없음 |
| 로컬/자체 프록시 | `/health` 200 + 인증 필요한 경로 1개 200 | 둘 다 |

## 미지의 프로바이더 — 공식문서로 레시피 만들기

레시피 표에 없는 서비스는 **추측으로 프로브를 만들지 말고**:
1. **docs-guide 스킬**(`/docs-guide:docs-guide`)로 해당 서비스 공식 API 문서에서 무과금 인증 확인 엔드포인트(모델 목록·계정 조회류)를 확인한다.
2. docs-guide 불가 시 WebSearch → 공식 문서 WebFetch 폴백.
3. 확인된 엔드포인트로 위 원칙(2·3·4)에 맞는 프로브를 구성해 검증한다.
4. 검증에 성공한 레시피는 이 표에 추가할 가치가 있음을 사용자에게 알린다 (플러그인 개선 제안).

## 전량 검증 모드 ("볼트 키 전부 확인")

`tkt list` 순회 → 서비스명에서 프로바이더 추정 → 각 레시피 실행 → 표로 보고:
서비스명 / 판정(생존·사망·권한문제·판정불가) / 근거 코드. 사망 키는 재발급 안내 + `tkt del` 제안.
프록시 URL 항목(`*-proxy-url`, `*-base-url`)은 `/health` + 인증 경로로 검증한다.
