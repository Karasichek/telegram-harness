#!/data/data/com.termux/files/usr/bin/bash
set -e
SELF="$(readlink -f "${BASH_SOURCE[0]}")"
DIR="$(cd "$(dirname "$SELF")" && pwd)"
BIN="${PREFIX:-/data/data/com.termux/files/usr}/bin"
TARGET="$BIN/tg-harness"
RUN="$BIN/tg-harnessd"

cat > "$TARGET" <<EOF
#!/data/data/com.termux/files/usr/bin/bash
exec "$DIR/tg-harness" "\$@"
EOF
cat > "$RUN" <<EOF
#!/data/data/com.termux/files/usr/bin/bash
exec "$DIR/tg-harnessd" "\$@"
EOF
chmod +x "$TARGET" "$RUN" "$DIR/tg-harness" "$DIR/tg-harnessd" "$DIR"/*.lua
echo "installed: $TARGET $RUN"
echo "ensure $BIN is in PATH (Termux default). edit $DIR/.env with TG_TOKEN and GROQ_API_KEY"
