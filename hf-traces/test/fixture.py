"""Write the test's agent-traces parquet: the columns the Hub's parquet branch carries for such a
dataset, with one of each row and message the mapping treats differently.

    python3 fixture.py <out.parquet>
"""

import json
import sys

import pyarrow as pa
import pyarrow.parquet as pq


def msg(**fields):
    return json.dumps(fields)


MAIN = [
    msg(role="user", content="how does this project work"),
    # Thinking, a blank text, and a call whose arguments are a JSON string.
    msg(
        role="assistant",
        content="",
        reasoning_content="Let me look at the tree first.",
        tool_calls=[{"id": "call_1", "type": "function", "function": {"name": "bash", "arguments": '{"command":"ls"}'}}],
    ),
    # A tool's output is a text block of a `tool` turn.
    msg(role="tool", tool_call_id="call_1", name="bash", content="README.md\nsrc"),
    # Blank in Unicode White_Space only: no block, so no turn, and `seq` does not advance.
    msg(role="assistant", content="\u3000\n", reasoning_content=" "),
    "not json",
    None,
    "[1, 2]",
    # Arguments as an object, re-serialized compactly in key order. Then a call with no arguments,
    # an entry that is not a call, and arguments that are null.
    msg(
        role="assistant",
        content="Two edits.",
        tool_calls=[
            {"function": {"name": "edit", "arguments": {"path": "src/main.rs", "line": 3, "ok": True}}},
            {"function": {"name": "noop"}},
            "not a call",
            {"function": {"arguments": None}},
        ],
    ),
    # U+001F is not Unicode White_Space, though Python's `str.strip` removes it: the block stays.
    msg(role="assistant", content="\u001f"),
    # `NaN` is not JSON, so the message is skipped.
    '{"role":"user","content":"not this one","score":NaN}',
    msg(content="no role"),
]

ROWS = [
    ("pi", "s-main", MAIN, json.dumps({"cwd": "/home/me/project", "model": "m"}), "2026-04-13T09:29:18.815Z"),
    ("codex", "s-nocwd", [msg(role="user", content="hi")], None, "2026-04-14T10:00:00Z"),
    ("pi", None, [msg(role="user", content="no session id")], None, "2026-04-15T10:00:00Z"),
    ("pi", "s-nomessages", None, None, "2026-04-15T10:00:00Z"),
    ("pi", "s-blank", [msg(role="assistant", content="  ")], None, "2026-04-15T10:00:00Z"),
    ("pi", "../escape", [msg(role="user", content="a session id that is not a file name")], None, "2026-04-15T10:00:00Z"),
    # One session on two rows: the first copy of each turn wins, and the second row's extra turn
    # is added.
    (
        "pi",
        "s-twice",
        [msg(role="user", content="first upload"), msg(role="assistant", content="the first copy wins")],
        None,
        "2026-04-16T10:00:00Z",
    ),
    (
        "pi",
        "s-twice",
        [
            msg(role="user", content="first upload"),
            msg(role="assistant", content="a later copy is dropped"),
            msg(role="user", content="a turn only the second row has"),
        ],
        None,
        "2026-04-16T11:00:00Z",
    ),
]

if __name__ == "__main__":
    harness, session_id, messages, metadata, sent_at = zip(*ROWS)
    table = pa.table(
        {
            "harness": pa.array(harness, pa.string()),
            "session_id": pa.array(session_id, pa.string()),
            "messages": pa.array(messages, pa.list_(pa.string())),
            "metadata": pa.array(metadata, pa.string()),
            "sent_at": pa.array(sent_at, pa.string()),
        }
    )
    pq.write_table(table, sys.argv[1])
