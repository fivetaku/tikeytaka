# Changelog

## 0.5.0 — 2026-09-01

- **New `tkt requires`**: plugins declare the API keys they need in a `keys.json` at their root; `requires` scans installed plugins (marketplace clones + cache, or explicit paths) and diffs those declarations against the vault. Reports `ok` / `MISSING` (required, exit 4, with the issuing URL) / `opt` (optional, no exit impact). Read-only — never registers keys or touches `.env`. Removes the manual "which keys does this plugin need again?" step. New **requires skill** documents the `keys.json` schema; declarations live beside `plugin.json`, never inside it (unknown keys there fail `claude plugin validate`).
- Implementation note: `IFS=$'\t' read` collapses consecutive tabs because tab is IFS whitespace, so an omitted optional field shifted every later field. Optional fields are emitted with a `-` sentinel and restored in bash.
- Regression suite: 53 cases (11 new — declaration diffing, exit codes, malformed/incomplete `keys.json`, read-only guarantee).

## 0.4.0 — 2026-08-31

- **New `tkt doctor`**: staged self-diagnosis (passphrase source → vault folder/file reachability → `Salted__` magic → decrypt + TKT2 integrity → mappings) with per-stage FAIL guidance and exit code. Motivated by a real misdiagnosis loop: sandbox/TCC denial of the iCloud vault folder was reported as "passphrase mismatch", sending two sessions down a wrong "LibreSSL vs OpenSSL 3 KDF difference" theory (cross-implementation decryption was re-verified compatible on 2026-08-31).
- **Failure causes are now distinguished instead of collapsed into one message**: unreadable vault (sandbox·TCC·permissions) / iCloud dataless placeholder (auto `brctl download` + wait, then retry) / non-ciphertext file (missing `Salted__` magic — conflict copy/truncation) / genuine passphrase mismatch (openssl stderr now captured and shown). Passphrase-lookup failure message no longer blindly suggests `tkt init` when the secret store itself is unreachable.
- Regression suite: 42 cases (7 new — cause-separation reporting and doctor exit codes).

## 0.3.0 — 2026-08-24

- New **verify skill**: live-checks keys against no-cost official endpoints before they enter the vault (dead keys are never registered) and on demand for the whole vault. Ships probe recipes for Gemini/OpenAI/Anthropic/OpenRouter/Perplexity/Telegram/data.go.kr/DashScope plus HTTP-code interpretation rules (401=dead, 403=valid-but-unentitled, 000=retry without proxy) and two real misjudgment traps (proxy-blocked 000, `$(command)` reference values in rc files). Unknown providers get their probe designed from official docs via the docs-guide skill (web-search fallback).
- add/scan now require the verify pass before `set-stdin`; commands router and READMEs updated.

## 0.2.3 — 2026-08-24

- scan skill now also sweeps shell rc files (`~/.zshrc`, `~/.zprofile`, `~/.bashrc`, `~/.bash_profile`) for plaintext `export *_KEY/*_TOKEN/*_SECRET=` lines — a classic leak path the `.env`-only sweep missed (real case: a dead Perplexity key sat in `.zshrc` untouched by the first scan). Keys found in rc files are vaulted and the rc line is removed, not propagated.


## 0.2.2 — 2026-08-24

- **Fix: first-run setup could wipe `settings.json`** — if the file was corrupted or contained comments (JSONC), the shared update-notifier installer re-wrote it as an empty object plus the hook, silently destroying all user settings. It now refuses to write when parsing fails and writes atomically (tmp + rename). Marketplace-wide propagation of the fix found in the ddiring v0.1.1 external review; reproduction-verified.

## 0.2.1 — 2026-08-23

- Fix: `init` wrote an empty `vault.path` (shell self-referential redirect — the redirection created the empty file before `vault_dir` read it back), which made every later command resolve the vault to `/secrets.enc`. Path is now computed into a variable before writing, and empty `vault.path` files are ignored on read. Caught in the first real-environment run right after v0.2.0.
- Regression suite now covers the `vault.path` pinning path without `TIKEYTAKA_DIR` (35 cases).

## 0.2.0 — 2026-08-23

- **Vault engine rewritten (TKT2)** after an internal audit + GPT-5.6 Sol (Pro) review found the v0.1.0 streaming pipeline could overwrite the vault with empty content on a corrupted/half-synced file or a malformed service name. Writes are now transactional: decrypt → integrity-verify → edit → re-encrypt → round-trip compare → conflict check → keep a `.bak` generation → atomic rename. The original vault is never touched until every step succeeds.
- Encryption parameters made explicit and cross-platform: AES-256-CBC + PBKDF2 (600k iterations, SHA-256), verified round-trip between LibreSSL (macOS) and OpenSSL 3.
- Vault plaintext now carries a `#TKT2` magic + SHA-256 integrity hash — corruption and tampering are detected instead of silently accepted.
- Secrets no longer pass through process argv: openssl passphrase via stdin, new `set-stdin` command for automation, `setp` no longer re-executes a child process, `.env` rewriting moved from awk to pure bash.
- Input validation before any write: service/variable whitelists, tab/newline/quote rejection.
- `init` verifies the passphrase **before** storing it; the chosen cloud path is pinned in `vault.path`.
- `sync` preserves original `.env` permissions (0600 stays 0600), normalizes duplicate variable definitions, and distinguishes "vault unreadable" from "0 keys".
- New **`use` skill**: when a task needs an API key, the vault is checked first and the key is wired + live-tested automatically — the user is only asked if the vault doesn't have it. Official docs (via docs-guide, web-search fallback) are consulted for env var names and current model ids.
- Platform branches: Windows (Git Bash + DPAPI passphrase store, OneDrive/Google Drive/iCloud path detection incl. WSL `/mnt/c`), Linux (secret-tool). macOS verified; Windows/Linux provisional.
- Regression suite `tests/regression.sh` (31 cases) covering vault-destruction scenarios, ps exposure, permission preservation, and cross-implementation decryption.

## 0.1.0 — 2026-08-23

- Initial release: encrypted cloud-synced API key vault (`bin/tkt`) with scan / add / list / sync skills, zero-signup design (existing cloud folder + OS secret store).
