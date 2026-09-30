#!/bin/sh
# jcode lifecycle hook for funes — installed as `turn_end` and `session_end` in
# [hooks] of ~/.jcode/config.toml. Observer hooks run detached, so this converts the firing
# session's journal into the funes spool and indexes it; session_end also publishes when a
# memory is bound. A hook the install displaced is recorded under previous/ and chained last.
set -u

HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
BUNDLE=$(CDPATH= cd -- "$HERE/.." && pwd)
LOG="$BUNDLE/scripts/funes-sync.log"

log() { printf '%s %s\n' "$(date +%Y-%m-%dT%H:%M:%S%z)" "$*" >>"$LOG"; }

js_runtime() {
    for js in node bun deno; do
        command -v "$js" >/dev/null 2>&1 && { printf '%s\n' "$js"; return 0; }
    done
    for d in "$HOME/.local/bin" /opt/homebrew/bin /usr/local/bin "$HOME/.bun/bin"; do
        [ -x "$d/node" ] && { printf '%s\n' "$d/node"; return 0; }
    done
    return 1
}

run_convert() {
    js=$(js_runtime) || { log "convert ABORT: no JS runtime"; return 0; }
    sessions=$(head -n 1 "$BUNDLE/sessions" 2>/dev/null)
    spool=$(head -n 1 "$BUNDLE/spool" 2>/dev/null)
    [ -n "$sessions" ] && [ -n "$spool" ] || { log "convert ABORT: no sessions/spool markers"; return 0; }
    "$js" "$BUNDLE/convert.mjs" "$sessions" "$spool" "${JCODE_HOOK_SESSION_ID:-}" >>"$LOG" 2>&1
}

case "${JCODE_HOOK_EVENT:-}" in
turn_end)
    run_convert
    sh "$BUNDLE/scripts/funes-index.sh" >>"$LOG" 2>&1 &
    ;;
session_end)
    run_convert
    sh "$BUNDLE/scripts/funes-index.sh" --publish >>"$LOG" 2>&1 &
    ;;
esac

# Whatever was configured before funes still runs.
prev=$(head -n 1 "$BUNDLE/previous/${JCODE_HOOK_EVENT:-none}" 2>/dev/null || true)
[ -n "$prev" ] && "$prev" >/dev/null 2>&1
exit 0
