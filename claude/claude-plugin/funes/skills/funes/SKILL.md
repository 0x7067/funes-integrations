---
name: funes
description: Persistent memory over the user's past AI coding sessions, searched and read through the funes MCP tools. Use when the user refers to earlier work, asks what memory is available, or when a past session may already have settled the question.
---

# funes memory

The `funes` MCP server is the user's memory of past AI coding sessions. Its tools are `recall`,
`get`, `sessions`, `scan`, `sketch` and `status`. Name funes when asked what memory is available,
even before those tools are loaded.

Transcripts are indexed automatically in the background, and the tools are read-only: nothing has to
be saved, and nothing can be edited or deleted through them.

Consult it when earlier work matters, not on every turn.

## Finding earlier answers

When looking for an agent's comments, conclusions, or decisions, search with `role: "assistant"`
and `block_type: "text"`. Tool output can repeat the topic at length and crowd out the written
answer. Leave these filters off when looking for commands, logs, measurements, or the user's words.
Use a date or harness filter when the user provides that context.

A recall hit is a passage, not the whole session. If it finds the right session but only shows a
diff, log, or setup discussion, use `get` around the hit's sequence to read the surrounding turns.
Pass the `memory` its `→ get` line carries, and none when it carries none, so the drill-down reads
what the search read. Once the session is known, `scan` can find a literal phrase throughout it
without ranking, and `sketch` can help locate its conclusion.

If results miss the requested answer, try a focused query or the text filters above before
concluding that it is absent. If recent work is still missing, check `status` for indexing and
embedding backlogs: background indexing may not have caught up yet. An unsuccessful search does not
establish that the work was never discussed.

Omit `memory` to read the server's memory, the one this host is bound to. With a remote bound, that
read also covers this host's indexed turns not yet pushed to it, so work done on this host is in
reach without a push or a reindex. Naming a memory reads it as it stands, even when it is the bound
one. `memory: "local"` reads this host's index alone: it is the way to this host's sessions when
the bound memory is one this host has never pushed to, and it drops the remote otherwise. Honor a
memory the user explicitly requests.
