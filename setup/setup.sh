#!/usr/bin/env bash
# First-run setup for tikeytaka. Idempotent, non-blocking.
#   setup.sh            -> env checks + update-notifier hook (once). SILENT: no star prompt.
#                          Used by skill / auto-trigger Step 0 (output is discarded).
#   setup.sh ask        -> same first-run setup, then — iff no star decision is on record —
#                          atomically records an "asked" marker AND prints "STAR_ASK <lang>".
#                          Recording the marker HERE (not via a model follow-up) guarantees
#                          the question is shown at most once per plugin, even if the caller
#                          never reports the answer back. <lang> is a best-effort fallback
#                          language code (ko/ja/en) detected from past Claude session
#                          transcripts — used only when the live conversation has no signal.
#   setup.sh star yes   -> record "yes" and star both repos (own + marketplace hub).
#   setup.sh star no    -> record "no"; star nothing.
# The star question itself is asked by the command flow (AskUserQuestion is Claude-only and
# cannot be issued from bash); this script never stars without an explicit "star yes".
set -uo pipefail

PLUGIN="tikeytaka"
OWN_REPO="fivetaku/tikeytaka"
HUB_REPO="fivetaku/gptaku_plugins"

CONFIG_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
HERE="$(cd "$(dirname "$0")" && pwd)"
MARKER_DIR="$HOME/.gptaku-setup"
SETUP_MARKER="$MARKER_DIR/$PLUGIN.json"
STAR_MARKER="$MARKER_DIR/$PLUGIN.star.json"
mkdir -p "$MARKER_DIR"

# --- detect a fallback UI language from past Claude session transcripts (best-effort) ---
# Counts Hangul / Kana / Latin letters in HUMAN-typed user text only (skips tool results,
# assistant turns and JSON structure, which are ASCII-heavy and would skew to English).
detect_lang() {
  command -v python3 >/dev/null 2>&1 || { echo en; return; }
  python3 - "$CONFIG_DIR/projects" 2>/dev/null <<'PY' || echo en
import sys, os, glob, json
base = sys.argv[1]
try:
    files = sorted(glob.glob(os.path.join(base, "**", "*.jsonl"), recursive=True),
                   key=os.path.getmtime, reverse=True)[:20]
except Exception:
    files = []
# Vote per message (presence of script), not per char — so a few large ASCII
# pastes (code, logs, specs) don't drown out many short typed Korean turns.
ko = ja = en = 0
msgs = 0
def vote(s):
    global ko, ja, en, msgs
    hk = hj = hl = False
    for ch in s:
        o = ord(ch)
        if 0xAC00 <= o <= 0xD7A3: hk = True
        elif 0x3040 <= o <= 0x30FF: hj = True
        elif 65 <= o <= 90 or 97 <= o <= 122: hl = True
    if hk: ko += 1
    elif hj: ja += 1
    elif hl: en += 1
    if hk or hj or hl: msgs += 1
for f in files:
    if msgs >= 400: break
    try:
        fh = open(f, encoding="utf-8", errors="ignore")
    except Exception:
        continue
    for line in fh:
        if msgs >= 400: break
        try:
            m = json.loads(line).get("message")
        except Exception:
            continue
        if not isinstance(m, dict) or m.get("role") != "user":
            continue
        c = m.get("content")
        if isinstance(c, str):
            vote(c)
        elif isinstance(c, list):
            for part in c:
                if isinstance(part, dict) and part.get("type") == "text":
                    vote(part.get("text", ""))
    fh.close()
if ko and ko >= ja and ko >= en: print("ko")
elif ja and ja >= ko and ja >= en: print("ja")
else: print("en")
PY
}

# --- record the star decision (and star the repos on "yes") ---
write_star() {  # $1 = decision (yes|no|asked)
  ts=$(date +%s 2>/dev/null || echo 0)
  printf '{"star_decision":"%s","plugin":"%s","ts":%s}\n' "$1" "$PLUGIN" "$ts" > "$STAR_MARKER"
}

if [ "${1:-}" = "star" ]; then
  DECISION="${2:-no}"
  write_star "$DECISION"
  if [ "$DECISION" = "yes" ] && command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
    for repo in "$OWN_REPO" "$HUB_REPO"; do
      gh api "user/starred/$repo" >/dev/null 2>&1 || gh api -X PUT "user/starred/$repo" >/dev/null 2>&1 || true
    done
  fi
  exit 0
fi

# --- first-run env checks + update-notifier hook (silent, once per machine) ---
if [ ! -f "$SETUP_MARKER" ]; then
  HAVE_NODE=0; command -v node >/dev/null 2>&1 && HAVE_NODE=1
  if [ "$HAVE_NODE" = "1" ]; then
    SCRIPTS_DIR="$CONFIG_DIR/scripts"
    mkdir -p "$SCRIPTS_DIR"
    [ -f "$HERE/gptaku-update-check.cjs" ] && cp -f "$HERE/gptaku-update-check.cjs" "$SCRIPTS_DIR/gptaku-update-check.cjs" 2>/dev/null
    CLAUDE_CONFIG_DIR="$CONFIG_DIR" node -e '
      const fs=require("fs"),path=require("path"),os=require("os");
      const cfg=process.env.CLAUDE_CONFIG_DIR||path.join(os.homedir(),".claude");
      const p=path.join(cfg,"settings.json");
      // settings.json이 존재하는데 파싱이 안 되면(손상/JSONC) 절대 덮어쓰지 않고 포기한다.
      // 빈 객체로 재작성하면 사용자 설정 전체가 증발한다 (2026-08-23 ddiring 리뷰 High).
      let d={};
      try{
        const raw=fs.readFileSync(p,"utf8");
        if(raw.trim()) d=JSON.parse(raw);
      }catch(e){
        if(e && e.code==="ENOENT") d={};
        else process.exit(0);
      }
      if(typeof d!=="object"||d===null||Array.isArray(d)) process.exit(0);
      d.hooks=d.hooks||{};
      const ss=d.hooks.SessionStart=Array.isArray(d.hooks.SessionStart)?d.hooks.SessionStart:[];
      const has=ss.some(e=>((e&&e.hooks)||[]).some(h=>String((h&&h.command)||"").includes("gptaku-update-check")));
      if(!has){
        const cmd="node "+JSON.stringify(path.join(cfg,"scripts","gptaku-update-check.cjs"));
        ss.push({matcher:"*",hooks:[{type:"command",command:cmd,timeout:5}]});
        // 임시파일 + rename으로 원자적 쓰기(부분 쓰기로 인한 파손 방지)
        try{
          const tmp=p+".tmp-gptaku-"+process.pid;
          fs.writeFileSync(tmp,JSON.stringify(d,null,2));
          fs.renameSync(tmp,p);
        }catch{}
      }
    ' >/dev/null 2>&1 || true
  fi
  ts=$(date +%s 2>/dev/null || echo 0)
  printf '{"setup":true,"plugin":"%s","ts":%s}\n' "$PLUGIN" "$ts" > "$SETUP_MARKER"
fi

# --- per-project memory note (idempotent, once per Claude Code project) ---
# Writes a short "how this project uses tikeytaka" note into the project's auto-memory
# (~/.claude/projects/<slug>/memory/) so later sessions don't re-learn the vault→map→sync
# flow or misread an auth 401/403 as a broken key. Runs only when the project dir already
# exists (i.e. a real Claude Code project), never overwrites an existing note, and never
# contains secret values — only service names and commands.
write_project_memory() {
  [ -n "${PWD:-}" ] || return 0
  slug="$(printf '%s' "$PWD" | sed 's/[^A-Za-z0-9]/-/g')"
  proj_dir="$CONFIG_DIR/projects/$slug"
  [ -d "$proj_dir" ] || return 0
  mem_dir="$proj_dir/memory"
  note="$mem_dir/tikeytaka-usage.md"
  [ -f "$note" ] && return 0
  mkdir -p "$mem_dir" 2>/dev/null || return 0
  lang="$(detect_lang)"
  if [ "$lang" = "ko" ]; then
    cat > "$note" <<'MD'
---
name: tikeytaka-usage
description: 이 프로젝트에서 API 키를 다루는 방법 — tikeytaka 볼트 → map-add → sync. 키 값 인라인·채팅 노출 금지, 401/403은 헤더·URL 먼저 점검
metadata:
  type: project
---

- **CLI 경로**: PATH에 없다. `TKT="$(ls -d "$HOME/.claude/plugins/cache/gptaku-plugins/tikeytaka/"*/bin/tkt | sort -V | tail -1)"`로 최신 버전 절대경로를 잡아 `bash "$TKT" <cmd>`로 부른다.
- **정본은 볼트**(`tkt list`로 서비스명 확인). 프로젝트 `.env`는 볼트에서 채워지는 사본이다. 키를 쓰는 파일마다 `map-add '<절대경로 .env>' <VAR> <service>` 뒤 `sync --check` → `sync`. 등록만으로는 아무 데도 전파되지 않는다.
- **값은 셸 변수로만**: `K="$(bash "$TKT" get <service>)"`. 명령행 인라인(`VAR=<값> cmd`), echo, 로그, 채팅 출력 금지. 새 키 등록은 별도 터미널에서 `setp <service>`(숨김 입력) 또는 `/tikeytaka:add`.
- **볼트 오류는 `tkt doctor`가 정본**. "암호 불일치"로 추측 진단하지 않는다(샌드박스·TCC·iCloud dataless가 흔한 원인).
- **API가 401/403을 내면 키 교체 전에 헤더 이름·base URL 경로 중복(`/v1` 이중 부착 등)·키 용도(소비자 키 vs 관리자 키)를 먼저 점검**한다. 정상 키도 잘못된 헤더로 보내면 401이 난다.
MD
  else
    cat > "$note" <<'MD'
---
name: tikeytaka-usage
description: How this project handles API keys — tikeytaka vault → map-add → sync. Never inline or print key values; on 401/403 check header and URL before rotating
metadata:
  type: project
---

- **CLI path**: not on PATH. Resolve the newest installed version with `TKT="$(ls -d "$HOME/.claude/plugins/cache/gptaku-plugins/tikeytaka/"*/bin/tkt | sort -V | tail -1)"` and call `bash "$TKT" <cmd>`.
- **The vault is the source of truth** (`tkt list` for service names). The project `.env` is a copy filled from the vault: for each file that consumes a key run `map-add '<absolute .env path>' <VAR> <service>`, then `sync --check` → `sync`. Registering a key alone propagates nothing.
- **Values only in shell variables**: `K="$(bash "$TKT" get <service>)"`. No inline `VAR=<value> cmd`, no echo, no logs, no chat output. Register new keys in a separate terminal with `setp <service>` (hidden prompt) or `/tikeytaka:add`.
- **`tkt doctor` is the authority on vault errors.** Do not guess "passphrase mismatch" — sandbox/TCC denial and iCloud dataless files are the usual causes.
- **On an API 401/403, check the header name, duplicated base-URL paths (e.g. `/v1` twice) and the key's purpose (consumer vs admin key) before rotating anything.** A valid key sent with the wrong header also returns 401.
MD
  fi
  idx="$mem_dir/MEMORY.md"
  if ! grep -q 'tikeytaka-usage.md' "$idx" 2>/dev/null; then
    if [ "$lang" = "ko" ]; then
      printf -- '- [tikeytaka 키 사용법](tikeytaka-usage.md) — 볼트→map-add→sync, 값 출력 금지, 401/403은 헤더·URL 먼저\n' >> "$idx"
    else
      printf -- '- [tikeytaka key usage](tikeytaka-usage.md) — vault→map-add→sync, never print values, check header/URL before rotating on 401/403\n' >> "$idx"
    fi
  fi
}
write_project_memory 2>/dev/null || true

# --- ask mode: emit the star prompt EXACTLY ONCE, recording it deterministically ---
# Only the command flow passes "ask". Bare / silent skill invocations never reach here,
# so they neither prompt nor record — the prompt is shown at most once, by a command,
# and the "asked" marker is written by bash regardless of any model follow-up.
if [ "${1:-}" = "ask" ] && [ ! -f "$STAR_MARKER" ]; then
  write_star "asked"
  echo "STAR_ASK $(detect_lang)"
fi
exit 0
