# tg-harness

Lua 5.4 tool for Telegram: it turns a DM with a photo, caption, and addon file into a ready channel post.

Flow: receive photo+caption (+page URL) + document in bot DM → overlay image (`magick`) → parse page → Groq extracts addon name and formats post → post photo + document (with footer) to channel. Includes a small local BM25 RAG (no embeddings).

## Features
- Telegram Bot API long-polling bot (`harness.lua`) and CLI/TUI (`harness_tui.lua`, `argparse`)
- One-shot generation from local files (`once`) or text-only formatting (`format`)
- Page parsing in Lua (no Python) with SSRF guard (http/https, public hosts only)
- Local RAG over `.txt/.md/.lua` (`rag.lua`), used as context for Groq
- Single config table in `config.lua`; secrets only from env
- Debug mode, auth allowlist, request/size limits

## Requirements
- `lua5.4`
- Lua: `dkjson`, `argparse` (LuaRocks/vendor paths supported)
- CLI: `curl`, ImageMagick `magick`
- Env: `TG_TOKEN`, `GROQ_API_KEY`

## Install
```sh
cd ~/projects/tg-harness-tools   # or package dir
./install.sh                     # installs tg-harness, tg-harnessd to $PREFIX/bin
cp .env.example .env             # set TG_TOKEN, GROQ_API_KEY (and ALLOWED_USERS)
```
Load env for a session: `set -a; . ./.env; set +a` (`tg-harness`/`tg-harnessd` auto-load `.env` from the package dir).

## Quick start
```sh
tg-harness --help
tg-harness format "Create Coasters.mcaddon" "американские горки в стиле Create"
tg-harness once -i img.png -d addon.mcaddon -c "описание" [-u https://...] [--post]
tg-harness index ~/kb
tg-harness ask "что добавить в описание аддона с горками?"
tg-harness run --fg              # polling bot (foreground; use interactive shell/tmux)
```

## Bot DM usage
1. Send **photo with caption** (description; may include a URL) and the **addon document** (any order).
2. Bot reports missing parts; when photo+caption(+doc/name) ready it processes and posts to `out_chat`, or send `/post` to force (photo+caption required).

Commands: `/start`, `/post`, `/clear`, `/kb` or `/savekb` (save buffered text / replied message to KB and reindex), `/debug` (toggle), `/status`.

## Repository layout
- `config.lua` — all configuration (key=value), reads env
- `tg.lua` — Telegram Bot API client (curl config files, no secrets in argv)
- `harness.lua` — polling bot / posting pipeline
- `harness_tui.lua` — CLI (argparse/glowberry-style headers)
- `rag.lua` — local BM25 index/search
- `tg-harness`, `tg-harnessd`, `install.sh` — launchers/installer
- `test.lua` — basic checks
- `docs/DOCUMENTATION.md` — detailed reference

## Security
- Keep secrets in `.env` (gitignored). Rotate any exposed `TG_TOKEN`/`GROQ_API_KEY`.
- Set `ALLOWED_USERS` (comma-separated Telegram user IDs); empty means anyone can DM the bot.
- Page fetch blocks localhost/private/link-local hosts. Temp/curl-config files are restricted and cleaned.

See [docs/DOCUMENTATION.md](docs/DOCUMENTATION.md) for full config, pipeline, RAG, and debugging details.
