# funes-integrations

The agent integrations Hugging Face maintains for [funes](https://github.com/huggingface/funes) —
`claude`, `codex`, `hermes` and `pi` — and the catalog `funes add <id>` installs them from.
Integrations maintained by their authors live wherever their authors put them;
[COMMUNITY.md](COMMUNITY.md) is where they are listed.

## Layout

One directory per integration, each a bundle as funes's
[integration contract](https://github.com/huggingface/funes/blob/main/docs/add.md#the-integration-contract)
describes it: a `manifest.json`, a `setup` executable, whatever the integration needs beside them,
and its own tests under `test/`. What each one installs into its agent, which of its events it
hooks, and what it needs on the box is in its README; what they share is below.

`hf-traces/` is the one directory that is not an integration. It converts Hugging Face agent-traces
datasets, and installs nothing.

## How the bundles automate

Each bundle gives its agent the funes read tools — `funes mcp` registered as an MCP server, or
fronted by the extension where the agent has no MCP client — and drives one script of its own,
`funes-index.sh`, in two modes. Per turn, it converts the session that just changed into funes's
spool and runs `funes index --harness <id>`, then converts any other session changed since it last
ran, so a session whose own hook never fired — untrusted, timed out, a host that died mid-turn — is
caught at the next turn; the run is time-boxed, so a backlog fills in a bounded step per turn. At
the session boundaries, as `funes-index.sh --publish` and only with a memory bound, it converts,
indexes — waiting out a per-turn run's lock — and pushes; it runs at the session's end and again at
the next start, catching up whatever a missed end left behind. The conversion is the bundle's own
converter: a script for Claude Code and Codex, the extension or plugin itself for pi and Hermes. The
work runs detached, so a hook returns in well under a second and never blocks the turn or trips a
timeout. The memory rides in a file beside the scripts, so every hooks file is static.

| Bundle | Per turn | Publish, with a memory bound |
| --- | --- | --- |
| `claude` | `Stop`, `SubagentStop` | `SessionEnd`, `SessionStart` |
| `codex` | `Stop` | `SessionEnd`, `SessionStart` |
| `hermes` | `post_llm_call` | `on_session_finalize`, `on_session_start` |
| `pi` | `turn_end` | `session_shutdown`, and `session_start` when the process is fresh |

At install, `setup add` converts the sessions the agent has already written. The `claude` and
`codex` setups leave out each one whose last turn the local memory holds, as its `funes sessions`
row says (funes 1.9.0 and newer), so a re-add converts only what changed since. The `claude` setup
also keeps those rows beside its scripts: a session the memory holds without the messages typed
while Claude was working keeps that numbering, and never gets them.

What funes guarantees around these — local-first indexing, one writer at a time, the secrets gate,
the wrong-memory guard — is in funes's
[automation docs](https://github.com/huggingface/funes/blob/main/docs/automation.md).

## Converting by hand

Indexing an agent's history on a machine that never ran the automation — an archive, a colleague's
export — is the bundle's converter into a directory of your own, then `funes index` on that
directory, as funes's [add docs](https://github.com/huggingface/funes/blob/main/docs/add.md#converting-by-hand)
describe. Each converter is its bundle's own, and emits the session and turn ids the hooks do.
`<bundle>` is `~/.funes/agents/<id>` once `funes add <id>` has run on any machine, or `<id>/` in
this checkout:

| Bundle | Converter |
| --- | --- |
| `claude` | `<bundle>/claude-plugin/funes/convert <transcript.jsonl> [out.funes.jsonl]` — needs jq; one argument prints to stdout |
| `codex` | `<bundle>/codex-plugin/plugins/funes/convert <rollout.jsonl> [out.funes.jsonl]` — needs jq; one argument prints to stdout |
| `pi` | `node <bundle>/convert.mjs <session.jsonl \| sessions-root> <out-dir>` — a root converts every session under it |
| `hermes` | `python3 <bundle>/plugin/convert.py <state.db> <out-dir> [session-id]` — every session in the store unless one is named |

```bash
for t in /archive/.claude/projects/*/*.jsonl; do
    ~/.funes/agents/claude/claude-plugin/funes/convert "$t" ~/imports/"$(basename "$t" .jsonl)".funes.jsonl
done
funes index ~/imports
```

### Hugging Face agent-traces datasets

The Hub keeps a parquet copy of an agent-traces dataset on its `refs/convert/parquet` branch.
`hf-traces/convert.py` turns it into one turns file per session. It needs pyarrow, which `uv run`
installs from the script's own header:

```bash
hf download <org>/<repo> --repo-type dataset --revision refs/convert/parquet --local-dir traces
uv run hf-traces/convert.py traces ~/imports
funes index ~/imports
```

It maps a session as funes's own reader did when `funes index <org>/<repo>` read these datasets, so
a dataset a memory already holds keeps its turn ids and a re-import adds nothing. A session id that
is not a plain file name is reported and skipped.

## Developing

A working copy installs into funes straight from the checkout:

```sh
funes add pi --from ./pi
```

funes confirms at the terminal before running files it did not publish — once, until they change.
Each bundle's tests run without a funes binary, against fakes:

```sh
sh pi/test/run.sh
```

The `hf-traces` test needs pyarrow. `PYTHON` names the interpreter that has it:

```sh
PYTHON="uv run --with pyarrow python" sh hf-traces/test/run.sh
```

## Releasing

A release is an integration's directory packed as `<id>.tar.gz`, published under `<id>/<version>/`
in the `huggingface/funes-integrations` bucket with a `SHA256SUMS` beside it, and listed in the
bucket's `catalog.json`. Versions are the integration's own — `version` in its manifest,
`MAJOR.MINOR.PATCH` — independent of funes's, and a published version is never replaced.

1. Bump `version` in `<id>/manifest.json` and merge.
2. Tag `<id>-v<version>` — `pi-v1.0.1` — and push the tag, or run the Release workflow by hand
   with the id and version.

The workflow checks the manifest against the tag, runs the bundle's tests, packs and publishes the
archive, and adds the release to the catalog. It needs `HF_FUNES_INTEGRATIONS_RELEASE_TOKEN`: a token
that can write that bucket, and nothing else. Releases run one at a time, since the catalog is
read, amended and written back.

### The catalog

`catalog.json`, `catalog_version` 1:

```json
{
  "catalog_version": 1,
  "integrations": {
    "pi": {
      "repo": "huggingface/funes-integrations",
      "releases": [
        {
          "version": "1.0.0",
          "contract_version": 1,
          "url": "hf://buckets/huggingface/funes-integrations/pi/1.0.0/pi.tar.gz",
          "sha256": "…"
        }
      ]
    }
  }
}
```

For the id it was asked for, funes takes the newest release whose `contract_version` is the one it
speaks, fetches the archive at `url` with the `SHA256SUMS` beside it, and refuses it unless its
digest is `sha256` and its manifest declares `version`. Fields funes does not know are ignored.
