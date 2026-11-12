# tg-harness

Lua 5.4 Telegram post harness: photo+caption(+page URL)+addon file from bot DM → overlay → parse page → Groq formats post → posts photo + document (with footer) to channel. Includes tiny local BM25 RAG.

## Requirements
- `lua5.4`, `dkjson`, `argparse` (LuaRocks/vendor)
- `curl`, ImageMagick `magick`
- env: `TG_TOKEN`, `GROQ_API_KEY` (keep in `.env`)

## Setup
```sh
./install.sh            # installs tg-harness, tg-harnessd into $PREFIX/bin
cp .env.example .env    # set TG_TOKEN, GROQ_API_KEY, ALLOWED_USERS (recommended)
set -a; . ./.env; set +a
tg-harness --help
```

## Config
All behavior lives in `config.lua` (key=value table): model/temps/prompts/footer/paths/limits and `ALLOWED_USERS` (comma-separated Telegram user ids, empty = allow all). Secrets only from env.

## Usage
```sh
tg-harness run --fg                 # polling bot
tg-harness once -i img.png -d x.mcaddon -c "text" [-u URL] [--post]
tg-harness format "file.mcaddon" "desc"
tg-harness index ./kb               # (re)build RAG index
tg-harness ask "question"
tg-harness status | stop
```
DM: photo+caption(+URL)+document, `/post` if needed. `/kb` saves buffered text to KB and reindexes. `/clear` resets.

## Security
Never commit `.env`/keys. Set `ALLOWED_USERS`. Bot token/Groq key stay out of argv (curl config files) and temp files are mode 600/cleaned. Rotate exposed keys.
