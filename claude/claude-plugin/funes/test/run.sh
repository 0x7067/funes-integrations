#!/bin/sh
# The converter's acceptance test: a real Claude Code transcript, trimmed and secret-scanned, and
# the turns file it must produce. `expected.funes.jsonl` is what funes's own Claude parser emitted
# while it had one, so a change here that moves a chunk id re-keys sessions users already hold. Its
# last two turns are the exception: messages typed while Claude was working, which that parser
# dropped.
#
#   sh <plugin>/test/run.sh
set -eu

HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT INT TERM

"$HERE/../convert" "$HERE/session.jsonl" "$out/got.funes.jsonl"
if ! diff -u "$HERE/expected.funes.jsonl" "$out/got.funes.jsonl"; then
    echo "claude converter: output changed — see the diff above" >&2
    exit 1
fi
if [ "$out/got.funes.jsonl" -nt "$HERE/session.jsonl" ] || [ "$out/got.funes.jsonl" -ot "$HERE/session.jsonl" ]; then
    echo "claude converter: the turns file does not carry the transcript's own time" >&2
    exit 1
fi

# The numbering of a session the memory already holds, from its row in `--indexed`. In
# `queued.jsonl`, q1 and q2 were typed while Claude was working, and a2 and a3 are one reply written
# as two lines with one stamp.
all="u1 a1 q1 a2 a3 u2 q2 a4"
without="u1 a1 a2 a3 u2 a4"
check() {
    printf '%s\n' "$1" >"$out/rows"
    got=$("$HERE/../convert" --indexed "$out/rows" "$HERE/queued.jsonl" | jq -r .turn_uuid | paste -s -d ' ' -)
    if [ "$got" != "$2" ]; then
        echo "claude converter: with the row \"$1\", the turns are $got, not $2" >&2
        exit 1
    fi
}
# Not held.
check "other 2026-10-01T10:00:10.000Z 4" "$all"
# Held without q1 up to u2, or with it.
check "queued 2026-10-01T10:01:00.000Z 5" "$without"
check "queued 2026-10-01T10:01:00.000Z 6" "$all"
# Held up to a1, before either: the two counts agree.
check "queued 2026-10-01T10:00:05.000Z 2" "$all"
# Up to a3 without q1, or up to a2 with it: read as held without.
check "queued 2026-10-01T10:00:10.000Z 4" "$without"
# No stamp to compare (funes before 1.9.0), or one neither count matches.
check "queued" "$without"
check "queued 2026-10-01T10:00:00.000Z 2" "$without"
echo "claude converter: ok"
