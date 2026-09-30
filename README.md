# funes-jcode

A [funes](https://github.com/huggingface/funes) integration for
[jcode](https://github.com/1jehuang/jcode). It gives jcode the funes read tools and keeps
your memory current as you work: each finished turn is converted out of jcode's session
journal into funes's spool and indexed, and — with a memory bound — published at session
boundaries.

| Piece | How |
| --- | --- |
| Read tools | `funes mcp` registered in `~/.jcode/mcp.json` (`servers.funes`) |
| Per-turn indexing | jcode's `turn_end` lifecycle hook converts the session's journal, then `funes index` |
| Session-boundary publish | the `session_end` hook runs `funes push` |
| Existing history | `setup add` converts every journal already in `~/.jcode/sessions/` |

Hooks already configured in `[hooks]` are not lost: `setup` records the displaced command
and the dispatcher runs it after funes's work; `setup remove` restores it.

## Install

```bash
funes add jcode <user|org>/funes-memory --from /path/to/this/bundle
funes add jcode                          # or omit the memory for a local one
```

Remove with:

```bash
funes remove jcode
```

which takes the MCP entry, the hook wiring, and the spool away — not your memory or jcode's
own journals.

## Requirements

- `funes` on PATH, jcode with lifecycle hooks (v0.89+)
- `node` or `bun` on PATH — the converter and config editor are JS
- [trufflehog](https://github.com/trufflesecurity/trufflehog) for `funes push`'s secret
  gate, only when a remote memory is bound

Overrides: `JCODE_HOME` (default `~/.jcode`), `FUNES_HOME`. jcode's own
`JCODE_HOOK_*` env vars still win over the config entries — the hooks it calls remain the
dispatcher.

## Converting by hand

```bash
node convert.mjs ~/.jcode/sessions /tmp/turns [session-id]
funes index --check /tmp/turns     # validate
funes index /tmp/turns             # or index directly
```

## Coverage

Reads `~/.jcode/sessions/*.journal.jsonl` — each entry's `append_messages` replayed in order,
re-appends of a message id resolve to its last content. `text`/`reasoning`/`tool_use`/
`tool_result` content becomes `text`/`thinking`/`tool_use`/`tool_result` blocks; `cwd` comes
from `meta.working_dir`. Sessions flagged `is_debug` or `is_canary` are skipped.

## Test

```bash
sh test/run.sh
```

converts the fixture journals, diffs against `test/expected.funes.jsonl`, validates with
`funes index --check`, and smokes `setup add`/`remove` against a sandboxed jcode home.

## Layout

- `manifest.json`, `setup`, `edit-config.mjs` — the
  [integration contract](https://github.com/huggingface/funes/blob/main/docs/add.md#the-integration-contract)
- `convert.mjs` — journal → `.funes.jsonl`
- `hooks/funes.sh` — the lifecycle-hook dispatcher (convert → index/publish, then chain)
- `scripts/funes-index.sh` — index/publish automation the dispatcher spawns
- `test/` — fixture journals and expectations
