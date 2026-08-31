#!/bin/bash
# tikeytaka v2 회귀 테스트 — 격리 환경(TIKEYTAKA_DIR + TKT_PASSPHRASE_FILE)에서 실행.
# 사용: bash tests/regression.sh   (실볼트·키체인 무접촉)
set -u
TKT="$(cd "$(dirname "$0")/.." && pwd)/bin/tkt"
WORK="$(mktemp -d)"
export TIKEYTAKA_DIR="$WORK/vault"
export TKT_PASSPHRASE_FILE="$WORK/pass"
export HOME_REAL="$HOME"
printf 'test-passphrase-1234' > "$TKT_PASSPHRASE_FILE"; chmod 600 "$TKT_PASSPHRASE_FILE"
PASS_N=0; FAIL_N=0
ok()   { PASS_N=$((PASS_N+1)); echo "  ok  - $1"; }
fail() { FAIL_N=$((FAIL_N+1)); echo "  FAIL - $1"; }
check() { if eval "$2"; then ok "$1"; else fail "$1"; fi; }
vault_sha() { shasum -a 256 "$TIKEYTAKA_DIR/secrets.enc" | awk '{print $1}'; }

echo "# 1. 기본 라운드트립"
bash "$TKT" set svc-a AAAA111 >/dev/null 2>&1
check "set/get 일치" '[ "$(bash "$TKT" get svc-a)" = "AAAA111" ]'
bash "$TKT" set svc-b BBBB222 >/dev/null 2>&1
check "list 2건" '[ "$(bash "$TKT" list | wc -l | tr -d " ")" = "2" ]'
check "볼트가 암호문(평문 미노출)" '! grep -q AAAA111 "$TIKEYTAKA_DIR/secrets.enc"'
bash "$TKT" del svc-b >/dev/null 2>&1
check "del 반영" '[ "$(bash "$TKT" list)" = "svc-a" ]'
check "del 후 .bak 존재" '[ -f "$TIKEYTAKA_DIR/secrets.enc.bak" ]'

echo "# 2. 손상 볼트 — 원본 무손상 (구버전 치명 결함)"
cp "$TIKEYTAKA_DIR/secrets.enc" "$WORK/good.enc"
echo "GARBAGE" > "$TIKEYTAKA_DIR/secrets.enc"
S0="$(vault_sha)"
bash "$TKT" set svc-c CCC333 >/dev/null 2>&1; RC=$?
check "손상 볼트 set 실패 exit!=0" '[ "$RC" != "0" ]'
check "손상 볼트 set 후 원본 해시 불변" '[ "$(vault_sha)" = "$S0" ]'
bash "$TKT" del svc-a >/dev/null 2>&1; RC=$?
check "손상 볼트 del 실패 + 해시 불변" '[ "$RC" != 0 ] && [ "$(vault_sha)" = "$S0" ]'
bash "$TKT" list >/dev/null 2>&1; RC=$?
check "손상 볼트 list는 에러(키 0개 오보 금지)" '[ "$RC" != "0" ]'
cp "$WORK/good.enc" "$TIKEYTAKA_DIR/secrets.enc"

echo "# 3. 입력 검증"
check "서비스명 '[' 거부" '! bash "$TKT" set "[" X 2>/dev/null'
check "서비스명 'a.*' 거부" '! bash "$TKT" set "a.*" X 2>/dev/null'
check "탭 포함 값 거부" '! bash "$TKT" set svc-t "$(printf "a\tb")" 2>/dev/null'
check "개행 포함 값 거부" '! bash "$TKT" set svc-n "$(printf "a\nb")" 2>/dev/null'
check "공백 포함 값 거부" '! bash "$TKT" set svc-s "a b" 2>/dev/null'
check "잘못된 sync 인자 거부" '! bash "$TKT" sync --typo 2>/dev/null'
check "검증 실패들이 볼트를 안 건드림" '[ "$(bash "$TKT" list)" = "svc-a" ]'

echo "# 4. set-stdin (argv 미노출 경로)"
printf '%s' "STDIN-VAL-99" | bash "$TKT" set-stdin svc-d >/dev/null 2>&1
check "set-stdin 저장" '[ "$(bash "$TKT" get svc-d)" = "STDIN-VAL-99" ]'

echo "# 5. sync — 권한 보존·중복 정규화·리터럴 값"
E="$WORK/test.env"
printf 'FOO=old\nFOO=stale-dup\nBAR=keep\n' > "$E"; chmod 600 "$E"
MAPF="$HOME/.config/tikeytaka/map.tsv"
cp "$MAPF" "$WORK/map.backup" 2>/dev/null || touch "$WORK/map.backup"
bash "$TKT" map-add "$E" FOO svc-d >/dev/null 2>&1
bash "$TKT" sync >/dev/null 2>&1
check ".env 값 갱신" 'grep -q "^FOO=STDIN-VAL-99$" "$E"'
check "중복 FOO= 한 줄로 정규화" '[ "$(grep -c "^FOO=" "$E")" = "1" ]'
check "무관 변수 보존" 'grep -q "^BAR=keep$" "$E"'
PERM="$(stat -f %Lp "$E" 2>/dev/null || stat -c %a "$E")"
check "0600 권한 보존" '[ "$PERM" = "600" ]'
bash "$TKT" set svc-d 'abc\ndef' >/dev/null 2>&1
bash "$TKT" sync >/dev/null 2>&1
check '백슬래시 값 리터럴 유지(행 분리 없음)' 'grep -qF "FOO=abc\ndef" "$E" && [ "$(wc -l < "$E" | tr -d " ")" = "2" ]'
bash "$TKT" sync --check > "$WORK/chk.out" 2>&1
check "변경 없으면 --check 0건" 'grep -q "0건 변경" "$WORK/chk.out"'
grep -v "^$E	" "$MAPF" > "$MAPF.n" 2>/dev/null; mv "$MAPF.n" "$MAPF"

echo "# 6. 편집 중 외부 변경 감지 (해시 가드) — 코드 경로 직접 검증"
S1="$(vault_sha)"
check "커밋 전 해시 비교 코드 존재" 'grep -q "편집 도중 볼트가 외부에서 변경됨" "$TKT"'
check "볼트 정상 상태 유지" '[ "$(vault_sha)" = "$S1" ]'

echo "# 7. ps 노출 — 암호/값이 argv에 없어야"
( bash "$TKT" set svc-ps PSVAL777 >/dev/null 2>&1 & W=$!
  for i in 1 2 3 4 5 6 7 8 9 10; do ps -axo command= 2>/dev/null; sleep 0.05; done > "$WORK/ps.cap"
  wait $W )
check "암호가 ps에 미노출" '! grep -q "test-passphrase-1234" "$WORK/ps.cap"'
check "openssl argv에 pass: 문자열 없음" '! grep -E "openssl.*pass:(test|PSVAL)" "$WORK/ps.cap"'

echo "# 8. 교차 복호화 (LibreSSL ↔ OpenSSL 3, 동일 명시 옵션)"
O3="$(ls /opt/homebrew/opt/openssl@3/bin/openssl 2>/dev/null | head -1)"
if [ -n "$O3" ]; then
  printf 'test-passphrase-1234\n' | "$O3" enc -d -aes-256-cbc -salt -pbkdf2 -iter 600000 -md sha256 -pass stdin -in "$TIKEYTAKA_DIR/secrets.enc" -out "$WORK/x.plain" 2>/dev/null
  check "OpenSSL3가 LibreSSL 볼트 복호화" 'head -1 "$WORK/x.plain" | grep -q "^#TKT2$"'
else
  echo "  skip - OpenSSL 3 미설치"
fi

echo "# 9. init — 틀린 암호 미저장 (파일 스토어 시뮬레이션)"
export TIKEYTAKA_DIR="$WORK/vault2"
printf 'right-pass' > "$WORK/pass2"; chmod 600 "$WORK/pass2"
TKT_PASSPHRASE_FILE="$WORK/pass2" bash "$TKT" set svc-x XXX >/dev/null 2>&1   # right-pass 볼트 생성
printf 'WRONG' > "$WORK/pass3"; chmod 600 "$WORK/pass3"
TKT_PASSPHRASE_FILE="$WORK/pass3" bash "$TKT" list >/dev/null 2>&1; RC=$?
check "틀린 암호로 list → 복호화 실패 에러" '[ "$RC" != "0" ]'
TKT_PASSPHRASE_FILE="$WORK/pass3" bash "$TKT" init </dev/null >/dev/null 2>&1; RC=$?
check "틀린 저장 암호 init → '이미 셋업됨' 미출력(TTY 재입력 요구/실패)" '[ "$RC" != "0" ]'
check "init 실패 후 저장 암호 불변" '[ "$(cat "$WORK/pass3")" = "WRONG" ]'

echo "# 10. vault.path 경로 고정 (TIKEYTAKA_DIR 없이 — v0.2.0 자기참조 빈 파일 버그 회귀)"
FAKEHOME="$WORK/home"; mkdir -p "$FAKEHOME"
printf 'pin-pass' > "$WORK/pass4"; chmod 600 "$WORK/pass4"
env -u TIKEYTAKA_DIR HOME="$FAKEHOME" TKT_PASSPHRASE_FILE="$WORK/pass4" bash "$TKT" init </dev/null >/dev/null 2>&1
check "vault.path가 비어있지 않음" '[ -s "$FAKEHOME/.config/tikeytaka/vault.path" ]'
check "vault.path가 절대경로" 'grep -q "^/" "$FAKEHOME/.config/tikeytaka/vault.path"'
W_OUT="$(env -u TIKEYTAKA_DIR HOME="$FAKEHOME" TKT_PASSPHRASE_FILE="$WORK/pass4" bash "$TKT" where)"
check "where가 고정 경로의 secrets.enc를 가리킴" 'echo "$W_OUT" | grep -q "^볼트: $FAKEHOME/.tikeytaka/secrets.enc$"'
check "재실행 시 볼트 인식(빈 경로 회귀 방지)" 'env -u TIKEYTAKA_DIR HOME="$FAKEHOME" TKT_PASSPHRASE_FILE="$WORK/pass4" bash "$TKT" list >/dev/null 2>&1'

echo "# 11. 실패 원인 구분 보고 + doctor (v0.4.0 — 접근불가·손상·암호불일치 오진 방지)"
export TIKEYTAKA_DIR="$WORK/vault3"
printf 'doc-pass' > "$WORK/pass5"; chmod 600 "$WORK/pass5"
export TKT_PASSPHRASE_FILE="$WORK/pass5"
bash "$TKT" set svc-doc DOCVAL1 >/dev/null 2>&1
check "doctor 정상 상태 exit 0" 'bash "$TKT" doctor >/dev/null 2>&1'
ERR_PERM="$(chmod 000 "$TIKEYTAKA_DIR/secrets.enc"; bash "$TKT" get svc-doc 2>&1 >/dev/null; chmod 600 "$TIKEYTAKA_DIR/secrets.enc")"
check "읽기불가 볼트 → '읽을 수 없음' 보고" 'echo "$ERR_PERM" | grep -q "읽을 수 없음"'
check "읽기불가 볼트 → '암호 불일치'로 오보하지 않음" '! echo "$ERR_PERM" | grep -q "암호 불일치"'
cp "$TIKEYTAKA_DIR/secrets.enc" "$WORK/doc.good"
echo "GARBAGE-NOT-CIPHER" > "$TIKEYTAKA_DIR/secrets.enc"
ERR_MAGIC="$(bash "$TKT" get svc-doc 2>&1 >/dev/null)"
check "매직 없는 볼트 → '암호문이 아님' 보고" 'echo "$ERR_MAGIC" | grep -q "암호문이 아님"'
check "매직 없는 볼트 doctor exit!=0" '! bash "$TKT" doctor >/dev/null 2>&1'
cp "$WORK/doc.good" "$TIKEYTAKA_DIR/secrets.enc"
printf 'WRONG-doc' > "$WORK/pass6"; chmod 600 "$WORK/pass6"
ERR_PASSMM="$(TKT_PASSPHRASE_FILE="$WORK/pass6" bash "$TKT" get svc-doc 2>&1 >/dev/null)"
check "틀린 암호 → '암호 불일치' 보고" 'echo "$ERR_PASSMM" | grep -q "암호 불일치"'
check "help에 doctor 노출" 'bash "$TKT" help 2>/dev/null | grep -q "tkt doctor"'

echo
echo "결과: $PASS_N passed, $FAIL_N failed"
rm -rf "$WORK"
[ "$FAIL_N" = "0" ]
