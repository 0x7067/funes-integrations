// edit-config.mjs — wire funes into jcode's two config files. Invoked by setup:
//
//   edit-config.mjs set|unset
//
// env: JCODE_HOME (default ~/.jcode), FUNES_BIN, FUNES_MEMORY, FUNES_BUNDLE (the installed
// bundle dir, holding hooks/funes.sh and previous/). set registers `funes mcp` in
// mcp.json's `servers` map and points [hooks] turn_end/session_end at the dispatcher,
// recording any hook it displaces under previous/<event> for chaining. unset reverses both,
// restoring displaced hooks.
//
// config.toml is edited line-wise inside the existing [hooks] table (or a new one appended):
// jcode accepts plain `key = "value"` entries, which is all this writes. A pre-existing
// hook command is captured verbatim from its line and replayed by the dispatcher.

import fs from "node:fs";
import path from "node:path";
import os from "node:os";

const op = process.argv[2];
const home = process.env.JCODE_HOME || path.join(os.homedir(), ".jcode");
const bundle = process.env.FUNES_BUNDLE;
const bin = process.env.FUNES_BIN || "funes";
const memory = process.env.FUNES_MEMORY || "";
const hook = `${bundle}/hooks/funes.sh`;
const EVENTS = ["turn_end", "session_end"];

// ---- mcp.json ----
const mcpFile = path.join(home, "mcp.json");
try {
  let cfg = { servers: {} };
  try {
    cfg = JSON.parse(fs.readFileSync(mcpFile, "utf8"));
  } catch (e) {
    if (e.code !== "ENOENT") {
      console.error(`funes: could not parse ${mcpFile} — add this under servers by hand:`);
      console.error(`  "funes": { "command": "${bin}", "args": ["mcp"], "shared": true }`);
      throw { handedit: true };
    }
  }
  cfg.servers = cfg.servers && typeof cfg.servers === "object" ? cfg.servers : {};
  if (op === "set") {
    cfg.servers.funes = {
      command: bin,
      args: memory ? ["mcp", memory] : ["mcp"],
      env: {},
      shared: true,
    };
  } else {
    delete cfg.servers.funes;
  }
  fs.writeFileSync(mcpFile, JSON.stringify(cfg, null, 2) + "\n");
  console.log(`funes: ${op === "set" ? "registered" : "removed"} MCP server in ${mcpFile}`);
} catch (e) {
  if (!e?.handedit) throw e;
}

// ---- config.toml [hooks] ----
const tomlFile = path.join(home, "config.toml");
const prevDir = path.join(bundle, "previous");

function tomlString(s) {
  return `"${s.replace(/\\/g, "\\\\").replace(/"/g, '\\"')}"`;
}
// Extract the string value of `key = "..."`; returns undefined when the entry is absent or
// not a plain string, in which case the line is left alone.
function tomlValue(line) {
  const m = line.match(/=\s*"((?:[^"\\]|\\.)*)"\s*(?:#.*)?$/);
  if (!m) return undefined;
  return m[1].replace(/\\"/g, '"').replace(/\\\\/g, "\\");
}

let lines = [];
try {
  lines = fs.readFileSync(tomlFile, "utf8").split("\n");
} catch (e) {
  if (e.code !== "ENOENT") throw e;
}

let start = lines.findIndex((l) => /^\s*\[hooks\]\s*$/.test(l));
let end = -1;
if (start !== -1) {
  end = lines.findIndex((l, i) => i > start && /^\s*\[/.test(l));
  if (end === -1) end = lines.length;
}

for (const ev of EVENTS) {
  const prevFile = path.join(prevDir, ev);
  const ours = `${ev} = ${tomlString(hook)}`;
  let idx = -1;
  if (start !== -1) {
    idx = lines.findIndex((l, i) => i > start && i < end && new RegExp(`^\\s*${ev}\\s*=`).test(l));
  }
  if (op === "set") {
    if (idx !== -1) {
      const cur = tomlValue(lines[idx]);
      if (cur === hook) continue; // already ours
      fs.mkdirSync(prevDir, { recursive: true });
      if (cur) fs.writeFileSync(prevFile, cur + "\n");
      lines[idx] = ours;
    } else {
      if (start === -1) {
        lines.push("", "[hooks]");
        start = lines.length - 1;
        end = lines.length;
      }
      lines.splice(start + 1, 0, ours);
      end++;
    }
  } else {
    if (idx === -1) continue;
    let restore = null;
    try {
      restore = fs.readFileSync(prevFile, "utf8").replace(/\n$/, "");
    } catch {}
    if (restore) {
      lines[idx] = `${ev} = ${tomlString(restore)}`;
    } else {
      lines.splice(idx, 1);
      end--;
    }
    try { fs.unlinkSync(prevFile); } catch {}
  }
}

fs.mkdirSync(home, { recursive: true });
fs.writeFileSync(tomlFile, lines.join("\n"));
console.log(`funes: ${op === "set" ? "wired" : "removed"} hooks in ${tomlFile}`);
