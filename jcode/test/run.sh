#!/bin/sh
# Converter test: convert the fixture journals, diff against the expected turns, validate
# with funes itself when a binary is on PATH, then smoke setup add/remove against a
# sandboxed JCODE_HOME and FUNES_HOME.
set -eu

HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

js=
for c in node bun; do
    command -v "$c" >/dev/null 2>&1 && { js=$c; break; }
done
[ -n "$js" ] || { echo "no JS runtime on PATH" >&2; exit 1; }

"$js" "$HERE/../convert.mjs" "$HERE/fixture" "$TMP/out"

SID=session_fox_1000000000000_abcdef
diff -u "$HERE/expected.funes.jsonl" "$TMP/out/$SID.funes.jsonl"
if ls "$TMP/out" | grep -q canary; then echo "debug session produced a file" >&2; exit 1; fi

# A re-run is a no-op: identical content is not rewritten.
before=$(stat -f %m "$TMP/out/$SID.funes.jsonl")
sleep 1
"$js" "$HERE/../convert.mjs" "$HERE/fixture" "$TMP/out" >/dev/null
after=$(stat -f %m "$TMP/out/$SID.funes.jsonl")
[ "$before" = "$after" ] || { echo "unchanged session was rewritten" >&2; exit 1; }

if command -v funes >/dev/null 2>&1; then
    funes index --check "$TMP/out"
fi

# setup add/remove against a fake jcode home holding one journal.
export FUNES_HOME="$TMP/funes" FUNES_AGENT_ID=jcode FUNES_BIN=funes
export JCODE_HOME="$TMP/jcode"
mkdir -p "$JCODE_HOME/sessions"
cp "$HERE/fixture/$SID.journal.jsonl" "$JCODE_HOME/sessions/"
cat >"$JCODE_HOME/config.toml" <<'EOF'
[keybindings]
scroll_up = "ctrl+k"

[hooks]
pre_tool_timeout_ms = 5000
turn_end = "~/bin/notify-me"
EOF
printf '{}' >"$JCODE_HOME/mcp.json"

sh "$HERE/../setup" add 0x7067/funes-memory

grep -q '"funes"' "$JCODE_HOME/mcp.json" || { echo "MCP server not registered" >&2; exit 1; }
grep -q 'turn_end = .*funes.sh' "$JCODE_HOME/config.toml" || { echo "turn_end not wired" >&2; exit 1; }
grep -q 'session_end = .*funes.sh' "$JCODE_HOME/config.toml" || { echo "session_end not wired" >&2; exit 1; }
grep -q 'notify-me' "$HERE/../previous/turn_end" || { echo "previous hook not recorded" >&2; exit 1; }
[ -f "$FUNES_HOME/spool/jcode/$SID.funes.jsonl" ] || { echo "seed did not convert" >&2; exit 1; }

sh "$HERE/../setup" remove
! grep -q '"funes"' "$JCODE_HOME/mcp.json" || { echo "MCP server left behind" >&2; exit 1; }
grep -q 'turn_end = .*notify-me' "$JCODE_HOME/config.toml" || { echo "previous hook not restored" >&2; exit 1; }
! grep -q 'session_end' "$JCODE_HOME/config.toml" || { echo "session_end left behind" >&2; exit 1; }
[ ! -d "$FUNES_HOME/spool/jcode" ] || { echo "spool not removed" >&2; exit 1; }

echo "ok"
