# tg-harness

Lua 5.4 Telegram post harness for a channel: takes photo+caption(+page URL)+addon file from bot DM (long polling), overlays `overlay.png`, parses page, asks Groq to extract addon name and format a post, posts photo + document to the channel. Includes a tiny local BM25 RAG.

## Requirements
- `lua5.4`, `dkjson` (LuaRocks/vendor path used), `argparse` (for TUI)
- `curl`, ImageMagick `magick`
- env: `TG_TOKEN`, `GROQ_API_KEY`

## Setup
```sh
cp .env.example .env   # fill TG_TOKEN, GROQ_API_KEY
set -a; . ./.env; set +a
lua5.4 harness_tui.lua --help
```

## Usage
```sh
lua5.4 harness_tui.lua run --fg     # polling bot
lua5.4 harness_tui.lua format "Create Coasters.mcaddon" "описание"
lua5.4 harness_tui.lua once -i img.png -d addon.mcaddon -c "текст" [-u URL] [--post]
lua5.4 harness_tui.lua index ./kb   # (re)build RAG index
lua5.4 harness_tui.lua ask "вопрос по базе знаний"
```

Bot DM: send photo with caption (+ optional URL) and addon document, then `/post` if needed. `/kb` saves buffered text to KB and reindexes RAG. `/clear` resets.

## Security
Never commit `.env`, tokens, or API keys. Rotate any key that was exposed.
