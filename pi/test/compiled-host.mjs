// The extension, loaded the way pi's Bun-compiled binary loads it: argv[1] is a path inside the
// executable (`/$bunfs/root/pi`) that no file system holds, and a child's stdin is a bare Writable
// with no `unref`. Either one, unhandled, fails the load or every tool. Node is made to look like
// that host; bun already is, but for argv[1]. Checks the tools `funes mcp` lists are registered.
//
//   node integrations/pi/test/compiled-host.mjs    (run.sh runs it)
import childProcess from "node:child_process";
import { chmodSync, cpSync, mkdirSync, mkdtempSync, writeFileSync } from "node:fs";
import module from "node:module";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

const HERE = dirname(fileURLToPath(import.meta.url));
delete process.env.FUNES_MEMORY;

const root = mkdtempSync(join(tmpdir(), "funes-pi-compiled-"));
const ext = join(root, "ext");
mkdirSync(ext);
for (const name of ["index.ts", "convert.mjs"]) cpSync(join(HERE, "..", name), join(ext, name));

// A `funes mcp` with one tool: an empty result to each request, but the tool list to `tools/list`.
const funes = join(root, "funes");
writeFileSync(
  funes,
  `#!/bin/sh
while IFS= read -r line; do
  id=$(printf '%s' "$line" | sed -n 's/.*"id":\\([0-9][0-9]*\\).*/\\1/p')
  [ -n "$id" ] || continue
  case $line in
  *'"tools/list"'*) printf '{"jsonrpc":"2.0","id":%s,"result":{"tools":[{"name":"recall","inputSchema":{"type":"object"}}]}}\\n' "$id" ;;
  *) printf '{"jsonrpc":"2.0","id":%s,"result":{}}\\n' "$id" ;;
  esac
done
`,
);
chmodSync(funes, 0o755);
process.env.FUNES_BIN = funes;

process.argv[1] = "/$bunfs/root/pi";
const spawn = childProcess.spawn;
childProcess.spawn = (...args) => {
  const child = spawn(...args);
  Object.defineProperty(child.stdin, "unref", { value: undefined });
  return child;
};
module.syncBuiltinESMExports?.();

const tools = [];
const pi = { registerTool: (tool) => tools.push(tool.name), on() {} };
const { default: activate } = await import(pathToFileURL(join(ext, "index.ts")).href);
await activate(pi);
if (tools.join() !== "recall") throw new Error(`expected the recall tool registered, got: ${JSON.stringify(tools)}`);
process.exit(0);
