#!/bin/sh
# `setup add` installs the skill and hooks plugin, leaves the memory in a file beside its script, and
# registers both surfaces with Claude; `setup remove` takes them back, a pre-registry install with
# them, and never the memory. Run as funes runs it: from the bundle's place in the registry, with
# the contract's environment, against a `claude` that only records what it is asked.
set -eu

HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
BUNDLE=$(CDPATH= cd -- "$HERE/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT INT TERM
fail() {
    echo "claude setup: $*" >&2
    exit 1
}

export HOME="$tmp/home"
mkdir -p "$HOME/.funes/agents" "$tmp/bin"
cat >"$tmp/bin/claude" <<'FAKE'
#!/bin/sh
printf '%s\n' "$*" >>"$FUNES_TEST_CLI_LOG"
FAKE
chmod +x "$tmp/bin/claude"
export PATH="$tmp/bin:/usr/bin:/bin"
export FUNES_TEST_CLI_LOG="$tmp/cli.log"
export FUNES_BIN=funes FUNES_HOME="$HOME/.funes" FUNES_AGENT_ID=claude
# Claude Code's transcripts live under its config directory, wherever the user put it: the
# converter's fixture, for the seed to find, behind 40 records it makes no turn of, so the transcript
# runs longer than the lines the seed reads to find its last turn.
export CLAUDE_CONFIG_DIR="$tmp/claude-config"
mkdir -p "$CLAUDE_CONFIG_DIR/projects/-Users-me-repo"
{
    i=0
    while [ $i -lt 40 ]; do
        echo '{"type":"file-history-snapshot","snapshot":{}}'
        i=$((i + 1))
    done
    cat "$BUNDLE/claude-plugin/funes/test/session.jsonl"
} >"$CLAUDE_CONFIG_DIR/projects/-Users-me-repo/session.jsonl"

cp -R "$BUNDLE" "$HOME/.funes/agents/claude"
setup="$HOME/.funes/agents/claude/setup"
plugin="$HOME/.funes/agents/claude/claude-plugin"
hooks="$plugin/funes/hooks/hooks.json"
run_script='sh "${CLAUDE_PLUGIN_ROOT}/scripts/funes-index.sh"'

# Bound to a memory.
"$setup" add acme/kb >"$tmp/add.out"
grep -q "installed funes into Claude Code" "$tmp/add.out" || fail "add did not report: $(cat "$tmp/add.out")"
[ -f "$plugin/.claude-plugin/marketplace.json" ] || fail "no marketplace manifest"
[ -f "$plugin/funes/.claude-plugin/plugin.json" ] || fail "no plugin manifest"
# The skill Claude loads from the plugin rides beside its hooks.
grep -q "name: funes" "$plugin/funes/skills/funes/SKILL.md" || fail "no skill in the plugin"
[ -x "$plugin/funes/scripts/funes-index.sh" ] || fail "the hook script is not executable"
# The plugin's own script per turn and for a sub-agent; the same script publishes at both boundaries.
[ "$(jq -r '.hooks.Stop[0].hooks[0].command' "$hooks")" = "$run_script" ] || fail "Stop: $(cat "$hooks")"
[ "$(jq -r '.hooks.SubagentStop[0].hooks[0].command' "$hooks")" = "$run_script" ] || fail "SubagentStop: $(cat "$hooks")"
[ "$(jq -r '.hooks.SessionStart[0].hooks[0].command' "$hooks")" = "$run_script --publish" ] || fail "SessionStart: $(cat "$hooks")"
[ "$(jq -r '.hooks.SessionEnd[0].hooks[0].command' "$hooks")" = "$run_script --publish" ] || fail "SessionEnd: $(cat "$hooks")"
# The memory rides in a file, not the hook command, so the hooks stay a static file.
if grep -q acme/kb "$hooks"; then fail "the memory is in the hook command"; fi
[ "$(cat "$plugin/funes/scripts/memory")" = acme/kb ] || fail "no memory file"
[ "$(cat "$plugin/funes/scripts/spool")" = "$FUNES_HOME/spool/claude" ] || fail "the spool is not recorded"
[ -f "$FUNES_HOME/spool/claude/session.funes.jsonl" ] || fail "the history was not seeded"
expected="plugin marketplace add $plugin
plugin uninstall funes@huggingface
plugin install funes@huggingface
mcp remove funes
mcp add funes -s user -e HF_HUB_USER_AGENT_ORIGIN=funes; agent/claude -- funes mcp acme/kb"
[ "$(cat "$FUNES_TEST_CLI_LOG")" = "$expected" ] || fail "claude was asked:
$(cat "$FUNES_TEST_CLI_LOG")"

# A re-run leaves out a transcript whose last turn the local memory holds, and converts one that
# grew since. With no `funes` to ask, as above, everything was converted.
cat >"$tmp/bin/funes" <<'FAKE'
#!/bin/sh
# `funes sessions` on the local memory, a page per offset: the file under $FUNES_TEST_PAGES named
# after it.
[ "$1 $2 $3" = "sessions --memory local" ] || exit 1
offset=0
while [ $# -gt 0 ]; do
    [ "$1" != --offset ] || offset=$2
    shift
done
exec cat "$FUNES_TEST_PAGES/$offset"
FAKE
chmod +x "$tmp/bin/funes"
export FUNES_TEST_PAGES="$tmp/pages"
mkdir -p "$FUNES_TEST_PAGES"
turns="$BUNDLE/claude-plugin/funes/test/expected.funes.jsonl"
id=$(tail -n 1 "$turns" | jq -r .session_id)
first=$(head -n 1 "$turns" | jq -r .ts)
last=$(tail -n 1 "$turns" | jq -r .ts)
# The listing, most recent first: another session, then, on the page the first one's trailer names,
# the fixture's, ending on $1.
listing() {
    cat >"$FUNES_TEST_PAGES/0" <<EOF
[2026-10-01T09:00:00.000Z → 2026-10-01T09:30:00.000Z] claude /Users/me/other 4 turns other
  another ask
---
1 of 2 sessions — 1 older: continue with --offset 1, or narrow with --repo/--since/--until
EOF
    cat >"$FUNES_TEST_PAGES/1" <<EOF
[$first → $1] claude /Users/me/repo 5 turns $id
  the ask it opened with
---
1 of 2 sessions — the oldest match reached
EOF
}
seeded="$FUNES_HOME/spool/claude/session.funes.jsonl"
rm "$seeded"
listing "$last"
"$setup" add acme/kb >/dev/null
[ ! -e "$seeded" ] || fail "a transcript whose last turn is indexed was converted again"
# The rows stay beside the scripts, for the converter.
[ "$(cat "$plugin/funes/scripts/indexed")" = "other 2026-10-01T09:30:00.000Z 4
$id $last 5" ] || fail "the memory's rows were not kept: $(cat "$plugin/funes/scripts/indexed")"
listing "$first"
"$setup" add acme/kb >/dev/null
[ -f "$seeded" ] || fail "a transcript that grew since its last indexed turn was not converted"

# A funes before 1.9.0 opens a row on its day alone, with no stamp to tell how a session it lists
# was numbered: that session is converted without the messages typed while Claude was working (the
# fixture's last two turns), and one it does not list with them.
day_listing() {
    cat >"$FUNES_TEST_PAGES/0" <<EOF
[${first%%T*}] claude /Users/me/repo 5 turns $1
  the ask it opened with
---
1 sessions
EOF
}
rm "$seeded"
day_listing "$id"
"$setup" add acme/kb >/dev/null
[ "$(jq -s length "$seeded")" = 3 ] || fail "a session listed with no span took its queued messages"
rm "$seeded"
day_listing other
"$setup" add acme/kb >/dev/null
[ "$(jq -s length "$seeded")" = 5 ] || fail "a session no listing names left its queued messages out"

# Re-run to bind the local memory: the file goes, and so do the boundary hooks.
"$setup" add >/dev/null
[ ! -e "$plugin/funes/scripts/memory" ] || fail "the memory file was left stale"
jq -e '.hooks | has("SessionEnd") | not' "$hooks" >/dev/null || fail "a local install publishes"

# Remove: the registrations, the spool, a pre-registry install — and never the memory.
legacy="$HOME/.funes/integrations/claude-plugin"
mkdir -p "$legacy" "$HOME/.funes/memory/chunks.lance"
printf owned >"$legacy/marker"
printf memory >"$HOME/.funes/memory/chunks.lance/keep"
: >"$FUNES_TEST_CLI_LOG"
"$setup" remove >/dev/null
[ ! -e "$legacy" ] || fail "the pre-registry install stays"
[ ! -e "$FUNES_HOME/spool/claude" ] || fail "the spool stays"
[ ! -e "$plugin/funes/scripts/spool" ] || fail "the spool record stays"
[ ! -e "$plugin/funes/scripts/indexed" ] || fail "the memory's rows stay"
[ "$(cat "$HOME/.funes/memory/chunks.lance/keep")" = memory ] || fail "the memory was touched"
expected="mcp remove funes -s user
plugin uninstall funes@huggingface
plugin marketplace remove huggingface"
[ "$(cat "$FUNES_TEST_CLI_LOG")" = "$expected" ] || fail "claude was asked:
$(cat "$FUNES_TEST_CLI_LOG")"
# Already absent remains a successful no-op.
"$setup" remove >/dev/null

# With no `claude` on PATH, what is funes's own still goes, and the rest is spelled out.
mkdir -p "$legacy"
printf owned >"$legacy/marker"
PATH=/usr/bin:/bin "$setup" remove >"$tmp/remove.out"
grep -q "remove the registrations manually" "$tmp/remove.out" || fail "no manual steps: $(cat "$tmp/remove.out")"
[ ! -e "$legacy" ] || fail "the pre-registry install stays without claude"
echo "claude setup: ok"
