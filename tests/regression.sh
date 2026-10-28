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
mkdir -p "$WORK/tmp"; export TMPDIR="$WORK/tmp"   # tkt 임시파일을 격리 폴더로 — 실제 $TMPDIR 에 테스트 잔여물 금지 + 누출 계수(#14)
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
grep -v "^$E	" "$MAPF" > "$MAPF.n" 2>/dev/null; cat "$MAPF.n" > "$MAPF"; mv "$MAPF.n" "$WORK/map.n.done"   # cat 으로 덮어써 원본 권한(0600) 유지

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
mirror_of() { bash "$TKT" where 2>/dev/null | sed -n 's/^미러: \(.*\.enc\) (.*/\1/p'; }
MIR="$(mirror_of)"
check "정상 읽기 후 미러 생성(정본과 동일 암호문)" '[ -n "$MIR" ] && cmp -s "$TIKEYTAKA_DIR/secrets.enc" "$MIR"'
chmod 000 "$TIKEYTAKA_DIR/secrets.enc"
OUT_PERM="$(bash "$TKT" get svc-doc 2>"$WORK/perm.err")"
check "읽기불가 볼트 + 미러 → 미러로 읽기 성공" '[ "$OUT_PERM" = "DOCVAL1" ]'
check "읽기불가 볼트 + 미러 → stderr에 미러 폴백 안내" 'grep -q "미러" "$WORK/perm.err"'
check "읽기불가 볼트 + 미러 → set 차단(쓰기 중단 안내)" '! bash "$TKT" set svc-doc X 2>"$WORK/w.err" && grep -q "쓰기를 중단" "$WORK/w.err"'
mv "$MIR" "$WORK/mir.bak"
ERR_PERM="$(bash "$TKT" get svc-doc 2>&1 >/dev/null)"
check "읽기불가 볼트 + 미러 없음 → '읽을 수 없음' 보고" 'echo "$ERR_PERM" | grep -q "읽을 수 없음"'
check "읽기불가 볼트 + 미러 없음 → '암호 불일치'로 오보하지 않음" '! echo "$ERR_PERM" | grep -q "암호 불일치"'
check "읽기불가 볼트 + 미러 없음 → '볼트 없음'으로 오보하지 않음" '! echo "$ERR_PERM" | grep -q "볼트 없음"'
mv "$WORK/mir.bak" "$MIR"; chmod 600 "$TIKEYTAKA_DIR/secrets.enc"
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

echo "# 12. requires — 플러그인 keys.json 선언 대조 (v0.5.0)"
PLUGDIR="$WORK/plugs"; mkdir -p "$PLUGDIR/p-one" "$PLUGDIR/p-two" "$PLUGDIR/p-none"
cat > "$PLUGDIR/p-one/keys.json" <<'JSON'
{"keys":[{"service":"svc-doc","env":"SVC_DOC_KEY","required":true,"docs":"https://example.com/doc"},
         {"service":"absent-required","env":"ABSENT_KEY","required":true,"docs":"https://example.com/get"}]}
JSON
cat > "$PLUGDIR/p-two/keys.json" <<'JSON'
{"keys":[{"service":"absent-optional","required":false}]}
JSON
REQ_OUT="$(bash "$TKT" requires "$PLUGDIR/p-one" "$PLUGDIR/p-two" "$PLUGDIR/p-none" 2>&1)"; REQ_RC=$?
check "등록된 키를 ok로 보고" 'echo "$REQ_OUT" | grep -q "^ok   p-one :: svc-doc → SVC_DOC_KEY$"'
check "미등록 필수 키를 MISSING + 발급링크로 보고" 'echo "$REQ_OUT" | grep -q "MISSING p-one :: absent-required → ABSENT_KEY  (발급: https://example.com/get)"'
check "미등록 선택 키는 opt로 분리 보고" 'echo "$REQ_OUT" | grep -q "^opt  p-two :: absent-optional 미등록 (선택 항목)"'
check "필수 미등록 시 exit 4" '[ "$REQ_RC" = "4" ]'
check "집계 라인 정확(3건/1건/1건)" 'echo "$REQ_OUT" | grep -q "선언 3건, 필수 미등록 1건, 선택 미등록 1건"'
REQ_OK="$(bash "$TKT" requires "$PLUGDIR/p-none" 2>&1)"; REQ_OK_RC=$?
check "선언 없는 경로만 주면 exit 0" '[ "$REQ_OK_RC" = "0" ]'
check "선언 없음 안내 출력" 'echo "$REQ_OK" | grep -q "keys.json 선언을 가진 플러그인이 없습니다"'
echo '{"keys":[{"env":"NO_SERVICE"}]}' > "$PLUGDIR/p-none/keys.json"
bash "$TKT" requires "$PLUGDIR/p-none" >/dev/null 2>&1; RC=$?
check "service 누락 keys.json은 실패(조용히 무시 금지)" '[ "$RC" != "0" ]'
printf 'NOT-JSON{' > "$PLUGDIR/p-none/keys.json"
bash "$TKT" requires "$PLUGDIR/p-none" >/dev/null 2>&1; RC=$?
check "깨진 JSON은 실패로 보고" '[ "$RC" != "0" ]'
check "requires는 볼트를 수정하지 않음" '[ "$(bash "$TKT" get svc-doc)" = "DOCVAL1" ]'
check "help에 requires 노출" 'bash "$TKT" help 2>/dev/null | grep -q "tkt requires"'

echo "# 13. 실제 샌드박스(sandbox-exec) — 정본 폴더 접근 거부 환경에서 미러 폴백·쓰기 차단 (v0.6.0)"
if command -v sandbox-exec >/dev/null 2>&1; then
  SBX_DIR="$(mktemp -d "$HOME/.tkt-sbx.XXXXXX")"; SBX_DIR="$(cd "$SBX_DIR" && pwd -P)"   # /var→/private/var 심링크는 deny 매칭 실패 — 실경로 필수
  export TIKEYTAKA_DIR="$SBX_DIR/v"
  printf 'sbx-pass' > "$WORK/pass7"; chmod 600 "$WORK/pass7"; export TKT_PASSPHRASE_FILE="$WORK/pass7"
  bash "$TKT" set svc-sbx SBXVAL >/dev/null 2>&1
  SBX_MIR="$(mirror_of)"
  DENY="(version 1)(allow default)(deny file-read* (subpath \"$SBX_DIR/v\"))(deny file-write* (subpath \"$SBX_DIR/v\"))"
  check "샌드박스가 실제로 정본을 가림" '! sandbox-exec -p "$DENY" ls "$SBX_DIR/v" >/dev/null 2>&1'
  check "샌드박스 get → 미러로 값 회수" '[ "$(sandbox-exec -p "$DENY" bash "$TKT" get svc-sbx 2>/dev/null)" = "SBXVAL" ]'
  check "샌드박스 list → 미러로 목록" '[ "$(sandbox-exec -p "$DENY" bash "$TKT" list 2>/dev/null)" = "svc-sbx" ]'
  check "샌드박스 set → 차단" '! sandbox-exec -p "$DENY" bash "$TKT" set svc-sbx NEW >/dev/null 2>&1'
  check "샌드박스 init → 분기 볼트 생성 차단" '! sandbox-exec -p "$DENY" bash "$TKT" init </dev/null >/dev/null 2>&1'
  check "샌드박스 doctor → 미러 사용 중 표시" 'sandbox-exec -p "$DENY" bash "$TKT" doctor 2>/dev/null | grep -q "미러 사용 중"'
  mv "$SBX_MIR" "$WORK/sbxmir.bak"
  check "샌드박스 + 미러 없음 → '읽을 수 없음'(볼트 없음 오보 아님)" 'sandbox-exec -p "$DENY" bash "$TKT" get svc-sbx 2>&1 >/dev/null | grep -q "읽을 수 없음"'
  mv "$WORK/sbxmir.bak" "$SBX_MIR"
  check "샌드박스 밖 정본 값 불변" '[ "$(bash "$TKT" get svc-sbx 2>/dev/null)" = "SBXVAL" ]'
  rm -f "$SBX_MIR"; rm -rf "$SBX_DIR"
else
  echo "  skip - sandbox-exec 없음(macOS 전용)"
fi

echo "# 14. 임시파일 누출 — 정상·실패·신호 종료 뒤 tkt.* 0개 (이슈 #2)"
export TIKEYTAKA_DIR="$WORK/vault4"
export HOME="$WORK/home14"; mkdir -p "$HOME"   # 실제 ~/.config/tikeytaka(map.tsv·미러)를 건드리지 않게 격리
printf 'leak-pass' > "$WORK/pass8"; chmod 600 "$WORK/pass8"; export TKT_PASSPHRASE_FILE="$WORK/pass8"
LEAKENV="$WORK/envdir"; mkdir -p "$LEAKENV"; printf 'LEAK_KEY=old\n' > "$LEAKENV/.env"; chmod 600 "$LEAKENV/.env"
leaks() { find "$TMPDIR" "$TIKEYTAKA_DIR" "$LEAKENV" -maxdepth 1 -name 'tkt.*' 2>/dev/null | wc -l | tr -d ' '; }
bash "$TKT" set leak-svc CANARY-LEAK-0 >/dev/null 2>&1
bash "$TKT" map-add "$LEAKENV/.env" LEAK_KEY leak-svc >/dev/null 2>&1
check "시작 시점 잔여물 0" '[ "$(leaks)" = "0" ]'
i=0; while [ "$i" -lt 20 ]; do
  printf '%s' "CANARY-LEAK-$i" | bash "$TKT" set-stdin leak-svc >/dev/null 2>&1
  bash "$TKT" set leak-tmp "CANARY-T$i" >/dev/null 2>&1
  bash "$TKT" get leak-svc >/dev/null 2>&1
  bash "$TKT" list >/dev/null 2>&1
  bash "$TKT" sync >/dev/null 2>&1
  bash "$TKT" del leak-tmp >/dev/null 2>&1
  i=$((i+1))
done
bash "$TKT" requires "$PLUGDIR/p-one" >/dev/null 2>&1
bash "$TKT" doctor >/dev/null 2>&1
check "정상 종료 20회 반복(set·set-stdin·get·list·sync·del·requires·doctor) 뒤 잔여물 0" '[ "$(leaks)" = "0" ]'
check "sync가 마지막 값으로 갱신(반복이 실제로 돌았음)" 'grep -q "^LEAK_KEY=CANARY-LEAK-19$" "$LEAKENV/.env"'
bash "$TKT" get no-such-svc >/dev/null 2>&1; RC=$?
check "실패 종료(없는 서비스 get) exit!=0 + 잔여물 0" '[ "$RC" != "0" ] && [ "$(leaks)" = "0" ]'
# sync 가 .env 옆 임시파일을 만든 뒤 실패하는 경로 — 가짜 stat 으로 chmod 를 실패시킨다
FAKEBIN="$WORK/fakebin"; mkdir -p "$FAKEBIN"
printf '#!/bin/sh\necho 999\n' > "$FAKEBIN/stat"; chmod +x "$FAKEBIN/stat"
bash "$TKT" set leak-svc CANARY-LEAK-SYNCFAIL >/dev/null 2>&1
PATH="$FAKEBIN:$PATH" bash "$TKT" sync >/dev/null 2>&1; RC=$?
check "실패 종료(sync 중 chmod 실패) exit!=0 + .env 옆 잔여물 0" '[ "$RC" != "0" ] && [ "$(leaks)" = "0" ]'
check "실패한 sync는 .env 원본을 바꾸지 않음" 'grep -q "^LEAK_KEY=CANARY-LEAK-19$" "$LEAKENV/.env"'
# 신호 종료 — openssl 을 느리게 감싸 복호화·암호화 도중에 TERM/INT 를 보낸다
mv "$FAKEBIN/stat" "$WORK/stat.off"
REAL_OSSL="$(command -v openssl)"
printf '#!/bin/sh\nsleep 1\nexec "%s" "$@"\n' "$REAL_OSSL" > "$FAKEBIN/openssl"; chmod +x "$FAKEBIN/openssl"
PATH="$FAKEBIN:$PATH" bash "$TKT" list >/dev/null 2>&1 & BGP=$!; sleep 0.5; kill -TERM "$BGP"; wait "$BGP"; RC=$?
check "TERM 중단(list 복호화 도중) exit 143 + 잔여물 0" '[ "$RC" = "143" ] && [ "$(leaks)" = "0" ]'
# 비대화형 셸의 백그라운드 작업은 SIGINT 가 무시된 채 시작돼 트랩할 수 없다 — 작업 제어(set -m)로 실제 Ctrl-C 와 같은 조건을 만든다
set -m
PATH="$FAKEBIN:$PATH" bash "$TKT" set leak-sig CANARY-SIG >/dev/null 2>&1 & BGP=$!; sleep 2.5; kill -INT "$BGP"; wait "$BGP"; RC=$?
check "INT 중단(set 암호화 도중 — 볼트 폴더에 임시 암호문이 있는 구간) exit 130 + 잔여물 0" '[ "$RC" = "130" ] && [ "$(leaks)" = "0" ]'
PATH="$FAKEBIN:$PATH" bash "$TKT" set leak-sig CANARY-SIG >/dev/null 2>&1 & BGP=$!; sleep 2.5; kill -HUP "$BGP"; wait "$BGP"; RC=$?
check "HUP 중단(set 암호화 도중) exit 129 + 잔여물 0" '[ "$RC" = "129" ] && [ "$(leaks)" = "0" ]'
set +m
check "중단된 set은 볼트를 바꾸지 않음" '! bash "$TKT" get leak-sig >/dev/null 2>&1'
export HOME="$HOME_REAL"

echo "# 15. verify 레시피 패턴 — 키가 ps(argv)에 안 보임 (skills/verify)"
CAN="CANARY-VERIFY-$$"
pscap() { local i=0; while [ "$i" -lt 15 ]; do ps -axo command= 2>/dev/null; sleep 0.1; i=$((i+1)); done; }
# 대조군: -H 로 직접 넘기면 ps 에 보여야 한다(표본 수집이 실제로 동작하는지 확인)
curl -s -m 3 --noproxy "*" -o /dev/null -H "Authorization: Bearer $CAN-H" http://10.255.255.1/x & CP=$!
pscap > "$WORK/ps.ctl"; wait "$CP" 2>/dev/null
check "대조군: -H 직접 전달은 ps 에 노출됨(표본 수집 동작)" 'grep -q "$CAN-H" "$WORK/ps.ctl"'
printf 'url = "http://10.255.255.1/x"\nheader = "Authorization: Bearer %s"\n' "$CAN" | curl -s -m 3 --noproxy "*" -o /dev/null --config - & CP=$!
pscap > "$WORK/ps.cfg"; wait "$CP" 2>/dev/null
check "레시피: printf | curl --config - 는 ps 에 키 미노출" '! grep -q "$CAN" "$WORK/ps.cfg"'
check "레시피 문서에 쿼리 키(?key=) 프로브 없음" '! grep -q "?key=K" "$(dirname "$TKT")/../skills/verify/SKILL.md"'

echo "# 16. doctor 위생 블록 — 평문 잔여물·위험 설정 보고(읽기 전용)"
export HOME="$WORK/home14"
: > "$TMPDIR/tkt.fake1"
DOC_OUT="$(bash "$TKT" doctor 2>&1)"; DOC_RC=$?
check "잔여 tkt.* 파일이 있으면 WARN + 처방" 'echo "$DOC_OUT" | grep -q "WARN \$TMPDIR 에 이전 버전이 남긴 tkt.\* 파일 1개"'
check "위생 WARN 은 doctor 종료 코드에 반영 안 됨(볼트 정상 → exit 0)" '[ "$DOC_RC" = "0" ]'
check "doctor 는 잔여물을 지우지 않음" '[ -f "$TMPDIR/tkt.fake1" ]'
mv "$TMPDIR/tkt.fake1" "$WORK/fake1.off"
check "잔여물이 없으면 ok" 'bash "$TKT" doctor 2>/dev/null | grep -q "ok   \$TMPDIR 잔여 tkt.\* 없음"'
mkdir -p "$HOME/.config/tikeytaka"; printf 'FAKE_TOKEN=x\n' > "$HOME/.config/tikeytaka/shell.env"
check "shell.env 에 비밀이 있으면 WARN" 'bash "$TKT" doctor 2>/dev/null | grep -q "WARN shell.env 의 비밀 1개"'
export HOME="$HOME_REAL"

# 테스트 볼트들의 미러 정리 (경로 해시별 파일 — 실사용 미러는 경로가 달라 건드리지 않음)
for d in "$WORK/vault" "$WORK/vault2" "$WORK/vault3" "$WORK/vault4" "$FAKEHOME/.tikeytaka"; do
  h="$(printf '%s' "$d/secrets.enc" | shasum -a 256 | cut -c1-16)"; rm -f "$HOME/.config/tikeytaka/mirror/$h.enc"
done

echo
echo "결과: $PASS_N passed, $FAIL_N failed"
rm -rf "$WORK"
[ "$FAIL_N" = "0" ]
