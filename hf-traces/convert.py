# /// script
# requires-python = ">=3.9"
# dependencies = ["pyarrow"]
# ///
"""Convert a Hugging Face agent-traces dataset into funes turns files.

The Hub derives a parquet branch, `refs/convert/parquet`, for an agent-traces dataset: one row per
session, whose `messages` column lists OpenAI-style chat messages as JSON strings
(`{role, content, reasoning_content?, tool_calls?}`). One session becomes one
`<session id>.funes.jsonl` in the output directory.

The mapping is the one funes's own parquet reader applied when `funes index <org>/<repo>` read these
datasets, so a dataset converted here keeps the turn ids a memory already holds for it, and
re-importing it adds nothing:
  - A message gives thinking (`reasoning_content`), then text (`content`), then one tool_use per
    `tool_calls` entry. A `tool` message's output is its `content`, a text block.
  - A message with no block is dropped, and `seq` counts only the messages kept.
  - `turn_uuid` is `<session id>-<seq>`, and `parent_uuid` the turn before it.
  - Every turn carries the session's `sent_at`, and `harness` and `metadata.cwd` come from its row.

    uv run convert.py <parquet file or directory> <out-dir>
    python3 convert.py <parquet file or directory> <out-dir>    # with pyarrow installed
"""

import json
import os
import re
import sys

import pyarrow.parquet as pq

FORMAT = 1
COLUMNS = ("session_id", "sent_at", "harness", "metadata", "messages")

# Unicode White_Space, which is what Rust's `str::trim` tests. Python's own `str.strip` differs:
# it also strips U+001C–U+001F, and a block is kept or dropped on this test.
WS = (
    "\t\n\v\f\r \u0085\u00a0\u1680"
    "\u2000\u2001\u2002\u2003\u2004\u2005\u2006\u2007\u2008\u2009\u200a"
    "\u2028\u2029\u202f\u205f\u3000"
)


def is_blank(text):
    return text.strip(WS) == ""


def compact(value):
    return json.dumps(value, separators=(",", ":"), ensure_ascii=False)


def string(value):
    return value if isinstance(value, str) else None


def blocks_of(message):
    """A message's blocks: thinking, then text, then one tool_use per `tool_calls` entry. A blank
    text field gives nothing."""
    blocks = []
    for field, block_type in (("reasoning_content", "thinking"), ("content", "text")):
        text = string(message.get(field))
        if text is not None and not is_blank(text):
            blocks.append({"block_type": block_type, "text": text})
    calls = message.get("tool_calls")
    for call in calls if isinstance(calls, list) else []:
        func = call.get("function") if isinstance(call, dict) else None
        func = func if isinstance(func, dict) else {}
        # `arguments` is usually a JSON string already, kept verbatim. Any other value is
        # re-serialized compactly, and a missing one is an empty object.
        if "arguments" not in func:
            text = "{}"
        elif isinstance(func["arguments"], str):
            text = func["arguments"]
        else:
            text = compact(func["arguments"])
        block = {"block_type": "tool_use", "text": text}
        name = string(func.get("name"))
        if name is not None:
            block["tool_name"] = name
        blocks.append(block)
    return blocks


def strict_json(text):
    """`json.loads` as funes parses: `NaN` and `Infinity` are not JSON."""

    def refuse(constant):
        raise ValueError(f"{constant} is not JSON")

    return json.loads(text, parse_constant=refuse)


def messages_of(elements):
    """The messages a row lists, parsed. An element that is null or not JSON is skipped."""
    if not isinstance(elements, list):
        raise ValueError("`messages` is not a list column")
    messages = []
    for element in elements:
        if element is None:
            continue
        if not isinstance(element, str):
            raise ValueError("`messages` elements are not JSON strings")
        try:
            messages.append(strict_json(element))
        except ValueError:
            continue
    return messages


def cwd_of(metadata):
    try:
        value = strict_json(metadata) if isinstance(metadata, str) else None
    except ValueError:
        return None
    return string(value.get("cwd")) if isinstance(value, dict) else None


def turns_of(row):
    """One row's turns, or none when it has no session id, no messages, or no message with a
    block."""
    session_id = string(row.get("session_id"))
    if session_id is None or row.get("messages") is None:
        return []
    ts = string(row.get("sent_at")) or ""
    harness = string(row.get("harness")) or ""
    cwd = cwd_of(row.get("metadata"))
    turns = []
    parent = None
    for message in messages_of(row["messages"]):
        if not isinstance(message, dict):
            continue
        blocks = blocks_of(message)
        if not blocks:
            continue
        turn_uuid = f"{session_id}-{len(turns)}"
        turn = {"format": FORMAT, "session_id": session_id}
        if cwd is not None:
            turn["cwd"] = cwd
        turn["turn_uuid"] = turn_uuid
        if parent is not None:
            turn["parent_uuid"] = parent
        turn["seq"] = len(turns)
        turn["ts"] = ts
        turn["role"] = string(message.get("role")) or ""
        turn["blocks"] = blocks
        turn["harness"] = harness
        turns.append(turn)
        parent = turn_uuid
    return turns


def parquet_files(path):
    if os.path.isfile(path):
        return [path]
    found = []
    for root, _, files in os.walk(path):
        found.extend(os.path.join(root, f) for f in files if f.endswith(".parquet"))
    return sorted(found)


def rows(path):
    """Every row of a parquet file, reading only the columns the mapping uses."""
    reader = pq.ParquetFile(path)
    present = set(reader.schema_arrow.names)
    for column in ("session_id", "messages"):
        if column not in present:
            raise ValueError(f"{path} has no `{column}` column")
    for batch in reader.iter_batches(columns=[c for c in COLUMNS if c in present]):
        yield from batch.to_pylist()


def write(out_dir, session_id, turns, mode):
    """A row's turns into `<out-dir>/<session id>.funes.jsonl`. The id comes out of the dataset and
    names a file, so one that is not a plain name is refused rather than written wherever it
    points."""
    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]*", session_id):
        raise ValueError(f"session id {session_id!r} is not a file name")
    out = os.path.join(out_dir, f"{session_id}.funes.jsonl")
    with open(out, mode, encoding="utf-8") as f:
        f.write("".join(compact(t) + "\n" for t in turns))
    return out


def convert(source, out_dir):
    """Every session under `source` into `out_dir`. A session that cannot be written is named and
    skipped. Returns the paths written.

    The parquet branch can list a session on several rows, a re-upload of it among them. Each row's
    turns are appended to the session's file in row order, and funes keeps the first copy of each
    turn, as its own reader did."""
    os.makedirs(out_dir, exist_ok=True)
    written = {}
    for path in parquet_files(source):
        for row in rows(path):
            turns = turns_of(row)
            if not turns:
                continue
            session_id = turns[0]["session_id"]
            try:
                written[session_id] = write(out_dir, session_id, turns, "a" if session_id in written else "w")
            except ValueError as e:
                print(f"skipped: {e}", file=sys.stderr)
    return list(written.values())


if __name__ == "__main__":
    if len(sys.argv) != 3:
        print("usage: convert.py <parquet file or directory> <out-dir>", file=sys.stderr)
        raise SystemExit(2)
    print(len(convert(sys.argv[1], sys.argv[2])))
