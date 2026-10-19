#!/bin/sh
# The converter's acceptance test: a synthetic agent-traces parquet, written by `fixture.py` with one
# of each row and message the mapping treats differently, and the turns files it must produce.
#
# `expected/` matches funes's own parquet reader, the one `funes index <org>/<repo>` ran: indexed
# from the parquet or from these files, every session reads back the same in `funes get`.
#
#   sh hf-traces/test/run.sh
#
# PYTHON names an interpreter that has pyarrow, `python3` by default. With uv:
# PYTHON="uv run --with pyarrow python" sh hf-traces/test/run.sh
set -eu

HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PYTHON=${PYTHON:-python3}
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT INT TERM

# PYTHON may be a command with arguments, so it is split on purpose.
$PYTHON "$HERE/fixture.py" "$out/fixture.parquet"
$PYTHON "$HERE/../convert.py" "$out/fixture.parquet" "$out/turns" >/dev/null 2>"$out/stderr"
if ! diff -ru "$HERE/expected" "$out/turns"; then
    echo "hf-traces converter: output changed, see the diff above" >&2
    exit 1
fi
# A session id names the file it becomes, so one that is not a plain name is refused.
if ! grep -q "'../escape' is not a file name" "$out/stderr"; then
    echo "hf-traces converter: a session id that is not a file name was not refused" >&2
    exit 1
fi
echo "hf-traces converter: ok"
