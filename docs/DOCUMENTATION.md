# tg-harness Documentation

## 1. Overview
`tg-harness` automates channel posts for Minecraft Bedrock addons/content:
- Input (bot DM or CLI): image, caption/description, addon file, optional page URL.
- Processing: overlay on image, page text extraction, Groq-based name extraction and post formatting, optional RAG context.
- Output: photo with formatted HTML caption to channel, addon document as reply with footer/caption.

Components:
| File | Role |
|---|---|
| `config.lua` | Central config table (`C`), env-driven |
| `tg.lua` | Telegram Bot API wrapper over `curl` |
| `harness.lua` | Long-polling bot and full posting pipeline |
| `harness_tui.lua` | CLI/TUI (argparse), in-process commands |
| `rag.lua` | Local BM25-ish index and retrieval |
| `tg-harness` / `tg-harnessd` | Launchers (load `.env`, run TUI/daemon) |
| `install.sh` | Installs wrappers into `$PREFIX/bin` |

## 2. Requirements & installation
**Runtime:** `lua5.4`, `curl`, ImageMagick `magick`.  
**Lua libs:** `dkjson` (required), `argparse` (required for TUI). Vendor/LuaRocks paths are added by scripts.

```sh
./install.sh
cp .env.example .env
# edit .env: TG_TOKEN, GROQ_API_KEY, ALLOWED_USERS
set -a; . ./.env; set +a
tg-harness --help
```

`tg-harness` and `tg-harnessd` source `<package>/.env` if present, so keys can stay in that file.

## 3. Configuration (`config.lua`)
All behavior is defined in `config.lua` and exported as `return C`. Secrets are read from env (do not hardcode).

| Key | Env | Default | Description |
|---|---|---|---|
| `tg_token` | `TG_TOKEN` | — | Bot token (required for bot/API posting) |
| `groq_key` | `GROQ_API_KEY` | — | Groq API key (required for Groq calls) |
| `allowed_users` | `ALLOWED_USERS` | empty set | CSV of Telegram user IDs allowed to use bot; empty = allow all |
| `out_chat` | `TG_CHAT` | `-1003627991849` | Target channel/chat id |
| `model` | `GROQ_MODEL` | `openai/gpt-oss-120b` | Groq chat model |
| `temperature` | — | `0.3` | Groq temperature |
| `debug` | `DEBUG` / `HARNESS_DEBUG` | false | Debug logging to stderr (`1/t/y`) |
| `home`, `dir` | — | resolved | Home and package directory |
| `overlay` | `OVERLAY` | `$HOME/downloads/overlay.png` | Overlay image (bottom-right) |
| `tmp` | `HARNESS_TMP` | `/data/data/com.termux/files/usr/tmp` | Temp files |
| `kb_dir` | `KB_DIR` | `$HOME/kb` | Knowledge base directory |
| `rag_store` | `RAG_STORE` | `$HOME/rag_index.json` | RAG index path |
| `log` | `HARNESS_LOG` | `/data/data/com.termux/files/usr/tmp/harness.log` | Log file |
| `mc_ver` | `MC_VERSION` | `26.30` | Default Minecraft version in posts |
| `author` | — | `@karasichekMC` | Author tag in formatted text |
| `prompt_extract_name` | — | (built-in) | Prompt to extract addon filename |
| `prompt_format` | — | (built-in, uses `mc_ver`) | Prompt to produce JSON (name/type/description/version) |
| `footer` | — | (built-in HTML) | Caption appended to document post |
| `page_max` | — | `12000` | Max parsed page chars |
| `rag_k` | — | `3` | RAG top-k chunks |
| `rag_max` | — | `3000` | RAG context char budget |
| `groq_timeout` | — | `90` | Groq curl timeout (s) |
| `tg_timeout` | — | `30` | Base TG timeout (s) |
| `max_pending_kb` | — | `8000` | Max buffered KB text per chat (chars) |
| `pending_ttl` | — | `3600` | Pending state TTL (s) |
| `max_redirects` | — | `3` | Page fetch redirect limit |

Helpers: `C.is_allowed(user_id)`, `C.dbg(...)`.

## 4. CLI / TUI (`tg-harness`)
Global options: `--groq-key --tg-token --chat --model --overlay --mc-ver --log --debug -h -v`

| Command | Description |
|---|---|
| `run [--fg]` | Start polling bot (`harness.lua`). Foreground with `--fg`, else background + log tail. Needs `GROQ_API_KEY` (and `TG_TOKEN`). |
| `once -i IMG [-d DOC] [-n NAME] [-c CAPTION] [-u URL] [--post]` | One-shot: overlay + (optional page/RAG) + Groq format; print result, optionally post to channel. |
| `format <filename> <caption...>` | Groq: extract clean addon name and format post text. |
| `index [dir]` | (Re)build RAG index from dir (default `kb_dir`) into `rag_store`. |
| `ask <query...>` | Ask Groq with RAG context from `rag_store`. |
| `status` | Show harness lua processes and recent log lines. |
| `stop` | Stop polling harness processes. |

Examples:
```sh
tg-harness --debug format "tacz 1.5.mcaddon" "оружие и анимации"
tg-harness once -i shot.png -d mod.mcaddon -c "описание" -u "https://..." --post
tg-harness index ~/kb && tg-harness ask "как описать аддон с машинами?"
```

`tg-harnessd` runs `harness.lua` directly (daemon loop), also loading `.env`.

## 5. Bot behavior (`harness.lua`)
- Long-polls `getUpdates` and processes messages from allowed users only (`ALLOWED_USERS`; empty = all). Unauthorized messages ignored.
- Per-chat pending state: photo, caption, document/name, URL; buffered KB text. States expire by `pending_ttl`; KB buffer capped by `max_pending_kb`.

**DM commands:**
| Command | Action |
|---|---|
| `/start` | Help text |
| `/post` | Force processing if photo+caption available |
| `/kb`, `/savekb` | Save buffered text (or replied message text/caption) to `kb_dir/tg_<chat>_<ts>.txt` and reindex RAG |
| `/clear` | Clear pending post state and KB buffer |
| `/debug` | Toggle runtime debug |
| `/status` | Show debug/out/model/allowed/pending/KB buffer size |

**Posting pipeline:**
1. Require image + caption (and doc/name when available).
2. Download photo; composite `overlay` bottom-right (`magick`).
3. Extract clean addon name via Groq from filename.
4. If URL present (caption/text) and safe, fetch and parse page to text.
5. Retrieve RAG context (`rag_k`, `rag_max`) for `name + caption`.
6. Groq returns JSON `{name,type,description,version}` → rendered as HTML post:
   `『 <b>name</b> • #<b>type</b> 』<blockquote expandable>description+author</blockquote><b>— Вᴇᴩᴄия: </b><code>ver</code>+​`
7. Send photo with caption to `out_chat`; send document as reply with `config.footer` (HTML). Reports doc-send failure if it occurs.

## 6. RAG (`rag.lua`)
- Tokenizes and indexes `.txt`, `.md`, `.lua` files under a directory (`index_dir` resets docs each run).
- Stores index at `rag_store` (`save`/`load`), searches with a simple BM25-like score.
- CLI: `lua5.4 rag.lua index [dir] | search <query>`.
- Used by bot/TUI to add context to Groq prompts; `/kb` appends knowledge and triggers reindex of `kb_dir`.

## 7. Telegram & API clients
- `tg.lua`: Bot API calls via `curl -K` config files (token in config file, not argv). Large/text fields sent as form files; temp files restricted/removed. Methods used: `sendMessage`, `sendPhoto`, `sendDocument`, `getUpdates`, `getFile`/download.
- Groq: chat completions called via `curl` with auth header/body in temp files (restricted/removed).

## 8. Debugging
- Enable: `--debug` flag, `DEBUG=1` / `HARNESS_DEBUG=1`, or bot `/debug`.
- Output: stderr lines `[debug]` (harness state: updates, from/chat, readiness, denied, API errors) and `[debug][tg]` (method/error summaries). No tokens/keys printed.
- Check: `tg-harness status`, log file (`HARNESS_LOG`), bot `/status`. Run `lua5.4 test.lua` for basic checks.

## 9. Security notes
- Never commit `.env`, tokens, or keys. Prefer `ALLOWED_USERS`.
- Bot/Groq credentials are not passed on command line; curl configs/headers use temp files (mode 600) and are cleaned up.
- URL fetch allows only `http/https` to public hosts and blocks localhost/private/link-local ranges; redirect/size limits apply.
- If keys were exposed, rotate them immediately.

## 10. Troubleshooting
| Symptom | Check |
|---|---|
| `set TG_TOKEN` / `set GROQ_API_KEY` | Env/.env loaded, values set |
| Groq errors/timeouts | Key/model access, network, `groq_timeout`, try smaller context |
| No post from bot | Need photo+caption (+doc/name), or use `/post`; verify `ALLOWED_USERS`, debug logs |
| Overlay missing/wrong | `magick` installed, `overlay` path exists |
| Page not used | URL must be public http/https; private/local blocked |
| RAG empty/irrelevant | `tg-harness index <dir>` or `/kb`, check `rag_store`/`kb_dir` |
| Entity/HTML parse issues | `tg.lua` sends text/caption as form files; keep footer/prompts valid HTML |
