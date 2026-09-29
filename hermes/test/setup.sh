#!/bin/sh
# `setup add` installs the plugin whose hooks drive the automation under hermes's own home, leaves
# the memory in a file beside it, has hermes enable it and register the MCP server, and clears the
# shell hooks of an install from before the plugin — scripts, approvals, and their entries in the
# user's own config.yaml, which is otherwise left as it is. `setup remove` takes it all back the
# same way. Run as funes runs it: from the bundle's place in the registry, with the contract's
# environment, against a `hermes` that only records what it is asked.
set -eu

HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
BUNDLE=$(CDPATH= cd -- "$HERE/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT INT TERM
fail() {
    echo "hermes setup: $*" >&2
    exit 1
}

export HOME="$tmp/home"
mkdir -p "$HOME/.funes/agents" "$tmp/bin"
cat >"$tmp/bin/hermes" <<'FAKE'
#!/bin/sh
printf '%s\n' "$*" >>"$FUNES_TEST_CLI_LOG"
# `mcp remove` asks before it acts and reads the answer from stdin; hermes would wait where the
# fake fails.
case "$1 ${2:-}" in
"mcp remove") IFS= read -r answer || { echo "hermes: no answer to the removal prompt" >&2; exit 3; } ;;
esac
# `mcp add` takes an environment for its server, unless this is an older hermes.
[ "$*" != "mcp add --help" ] || [ -n "${FAKE_HERMES_NO_MCP_ENV:-}" ] || echo "  --env [ENV ...]       Environment variables for stdio servers (KEY=VALUE)"
FAKE
chmod +x "$tmp/bin/hermes"
export PATH="$tmp/bin:/usr/bin:/bin"
export FUNES_TEST_CLI_LOG="$tmp/cli.log"
export FUNES_BIN=funes FUNES_HOME="$HOME/.funes" FUNES_AGENT_ID=hermes
# hermes answers for its own home; the fake says nothing, so the default lands in the fake one.
unset HERMES_HOME

cp -R "$BUNDLE" "$HOME/.funes/agents/hermes"
setup="$HOME/.funes/agents/hermes/setup"
hermes_dir="$HOME/.hermes"
hooks="$hermes_dir/hooks"
config="$hermes_dir/config.yaml"
plugin="$hermes_dir/plugins/funes"

# hermes's store, holding the converter's fixture session: the seed converts it.
cp "$BUNDLE/plugin/test/state.db" "$hermes_dir/state.db" 2>/dev/null || { mkdir -p "$hermes_dir" && cp "$BUNDLE/plugin/test/state.db" "$hermes_dir/state.db"; }
# An install from before the plugin: its hook entries in the file that also holds the user's
# configuration — one folded over two lines, as funes wrote a long path, beside a hook of the
# user's — and its scripts beside a script of the user's.
mkdir -p "$hooks"
printf owned >"$hooks/funes-index.sh"
printf keep >"$hooks/user-hook.sh"
before='model: hermes-4
hooks:
  post_llm_call:
  - command: make lint
  - command: bash "/old/funes-index.sh"
      "hermes"
    timeout: 10
  on_session_finalize:
  - command: bash "/old/funes-push.sh" "acme/kb" "hermes"
    timeout: 10
hooks_auto_accept: false'
after='model: hermes-4
hooks:
  post_llm_call:
  - command: make lint
hooks_auto_accept: false'
printf '%s\n' "$before" >"$config"

"$setup" add acme/kb >"$tmp/add.out" 2>"$tmp/add.err"
grep -q "installed funes into hermes" "$tmp/add.out" || fail "add did not report: $(cat "$tmp/add.out")"
# hermes discovers user plugins under its own home only, so funes's lives there.
for event in post_llm_call on_session_start on_session_finalize; do
    grep -q "$event" "$plugin/plugin.yaml" || fail "the plugin does not declare $event"
done
grep -q "def register(ctx)" "$plugin/__init__.py" || fail "no plugin entry point"
[ -x "$plugin/funes-index.sh" ] || fail "the hook script is not executable"
# The memory rides in a file the plugin reads, so the plugin stays a static file.
[ "$(cat "$plugin/memory")" = acme/kb ] || fail "no memory file"
[ "$(cat "$plugin/spool")" = "$FUNES_HOME/spool/hermes" ] || fail "the spool is not recorded"
[ -f "$FUNES_HOME/spool/hermes/20260101_000000_fixture.funes.jsonl" ] || fail "the history was not seeded"
# The pre-plugin hooks come out of the user's own file, their approvals revoked by their whole
# command and their scripts gone; the user's hook and the rest of the file stay as they were.
[ "$(cat "$config")" = "$after" ] || fail "config.yaml after add: $(cat "$config")"
[ ! -e "$config.funes-tmp" ] || fail "the edit's temp file stays"
grep -q "removed funes's own shell hooks" "$tmp/add.out" || fail "the edit was not reported: $(cat "$tmp/add.out")"
[ ! -e "$hooks/funes-index.sh" ] || fail "funes's own script stays"
[ -f "$hooks/user-hook.sh" ] || fail "the user's script went"
expected="config path
hooks revoke bash \"/old/funes-index.sh\" \"hermes\"
hooks revoke bash \"/old/funes-push.sh\" \"acme/kb\" \"hermes\"
plugins enable funes
mcp add --help
mcp add funes --env HF_HUB_USER_AGENT_ORIGIN=funes; agent/hermes --command funes --args mcp acme/kb"
[ "$(cat "$FUNES_TEST_CLI_LOG")" = "$expected" ] || fail "hermes was asked:
$(cat "$FUNES_TEST_CLI_LOG")"

# Remove, with a pre-plugin install whose hooks were the only ones: the plugin goes, the approvals
# are revoked, funes's scripts and log go, and the block they emptied is left as hermes writes an
# empty one.
printf owned >"$hooks/funes-index.sh"
printf owned >"$hooks/funes-sync.log"
printf '%s\n' 'model: hermes-4' 'hooks:' '  post_llm_call:' '  - command: bash "/old/funes-index.sh" "hermes"' '    timeout: 10' >"$config"
: >"$FUNES_TEST_CLI_LOG"
"$setup" remove >"$tmp/remove.out" 2>"$tmp/remove.err"
[ ! -e "$plugin" ] || fail "the plugin stays"
[ ! -e "$hooks/funes-index.sh" ] || fail "funes's own script stays"
[ ! -e "$hooks/funes-sync.log" ] || fail "funes's log stays"
[ -f "$hooks/user-hook.sh" ] || fail "the user's script went"
[ "$(cat "$config")" = 'model: hermes-4
hooks: {}' ] || fail "config.yaml after remove: $(cat "$config")"
grep -q "removed funes's own shell hooks" "$tmp/remove.out" || fail "the edit was not reported: $(cat "$tmp/remove.out")"
[ ! -e "$FUNES_HOME/spool/hermes" ] || fail "the spool stays"
expected="config path
plugins disable funes
hooks revoke bash \"/old/funes-index.sh\" \"hermes\"
mcp remove funes"
[ "$(cat "$FUNES_TEST_CLI_LOG")" = "$expected" ] || fail "hermes was asked:
$(cat "$FUNES_TEST_CLI_LOG")"

# A hooks block of a shape funes does not know is left whole and named instead.
flow='model: hermes-4
hooks: {post_llm_call: [{command: bash "/old/funes-index.sh" "hermes"}]}'
printf '%s\n' "$flow" >"$config"
"$setup" remove >/dev/null 2>"$tmp/remove.err"
[ "$(cat "$config")" = "$flow" ] || fail "an unknown shape was edited: $(cat "$config")"
grep -q "delete the entries" "$tmp/remove.err" || fail "the entries were not named: $(cat "$tmp/remove.err")"
# A block with none of funes's hooks is not touched, nor reported on.
mine='hooks:
  post_llm_call:
  - command: make lint'
printf '%s\n' "$mine" >"$config"
"$setup" remove >"$tmp/remove.out" 2>"$tmp/remove.err"
[ "$(cat "$config")" = "$mine" ] || fail "the user's own hooks were edited: $(cat "$config")"
[ ! -s "$tmp/remove.err" ] || fail "unexpected stderr: $(cat "$tmp/remove.err")"
grep -q "removed funes's own shell hooks" "$tmp/remove.out" && fail "reported an edit that did not happen"
# Already absent remains a successful no-op.
"$setup" remove >/dev/null 2>&1

# A hermes whose `mcp add` takes no environment registers funes without one.
: >"$FUNES_TEST_CLI_LOG"
FAKE_HERMES_NO_MCP_ENV=1 "$setup" add >/dev/null 2>&1 || fail "add failed on a hermes with no \`mcp add --env\`"
grep -qx 'mcp add funes --command funes --args mcp' "$FUNES_TEST_CLI_LOG" || fail "hermes was asked:
$(cat "$FUNES_TEST_CLI_LOG")"
echo "hermes setup: ok"
