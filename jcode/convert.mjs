#!/usr/bin/env node
// convert.mjs — convert jcode session journals into .funes.jsonl turns files.
//
//   convert.mjs <sessions-dir> <out-dir> [session-id]
//
// A session id converts that one session; without it, every journal under
// <sessions-dir> is converted. Each session lands at <out-dir>/<session id>.funes.jsonl,
// written to a temporary name and renamed into place — a re-emit overwrites its own file,
// and a file whose content has not changed is left untouched.
//
// jcode persists each session as ~/.jcode/sessions/<id>.journal.jsonl: an append-only log
// of {"meta": {...}, "append_messages": [...]} entries. Replaying the appends in order
// rebuilds the conversation; messages carry Anthropic-style content arrays. Sessions
// flagged is_debug or is_canary are jcode's own test harness and are skipped.

import { execFileSync } from "node:child_process";
import fs from "node:fs";
import path from "node:path";

const HARNESS = "jcode";
const ID_RE = /^[A-Za-z0-9_-]+$/;

function iso(ts) {
  const d = new Date(ts);
  return Number.isNaN(d.getTime()) ? null : d.toISOString();
}

// tool_result content arrives as a string or as blocks of {type, text}.
function resultText(content) {
  if (typeof content === "string") return content || null;
  if (Array.isArray(content)) {
    const text = content
      .map((c) => (typeof c === "string" ? c : c?.text ?? ""))
      .filter(Boolean)
      .join("\n");
    return text || null;
  }
  return content == null ? null : JSON.stringify(content);
}

function blocksOf(msg) {
  const blocks = [];
  const content = msg.content;
  if (typeof content === "string") {
    if (content) blocks.push({ block_type: "text", text: content });
    return blocks;
  }
  for (const c of Array.isArray(content) ? content : []) {
    if (c?.type === "text" && c.text) {
      blocks.push({ block_type: "text", text: c.text });
    } else if ((c?.type === "reasoning" || c?.type === "thinking") && c.text) {
      blocks.push({ block_type: "thinking", text: c.text });
    } else if (c?.type === "tool_use") {
      const input = c.input;
      blocks.push({
        block_type: "tool_use",
        text: typeof input === "string" ? input : JSON.stringify(input ?? {}),
        tool_name: c.name,
        tool_use_id: c.id,
      });
    } else if (c?.type === "tool_result") {
      const text = resultText(c.content ?? c.text);
      if (text !== null) {
        blocks.push({
          block_type: "tool_result",
          text,
          tool_name: c.name,
          tool_use_id: c.tool_use_id,
        });
      }
    }
  }
  return blocks;
}

const ROLE = { user: "user", assistant: "assistant" };

function convertJournal(file, sessionId, outDir) {
  const order = [];
  const messages = new Map(); // id → message; re-appends update in place
  let meta = {};
  for (const line of fs.readFileSync(file, "utf8").split("\n")) {
    if (!line.trim()) continue;
    let entry;
    try {
      entry = JSON.parse(line);
    } catch {
      continue;
    }
    if (entry.meta) meta = { ...meta, ...entry.meta };
    for (const m of entry.append_messages ?? []) {
      if (!m?.id) continue;
      if (!messages.has(m.id)) order.push(m.id);
      messages.set(m.id, m);
    }
  }
  if (meta.is_debug === true || meta.is_canary === true) return false;
  if (order.length === 0) return false;

  const cwd = typeof meta.working_dir === "string" ? meta.working_dir : undefined;
  const lines = [];
  let seq = 0;
  let prev = null;
  for (const id of order) {
    const m = messages.get(id);
    const ts = iso(m.timestamp) ?? iso(meta.updated_at) ?? iso(meta.last_active_at);
    if (!ts) continue;
    const turn = {
      format: 1,
      session_id: sessionId,
      turn_uuid: m.id,
      seq: seq++,
      ts,
      role: ROLE[m.role] ?? "system",
      harness: HARNESS,
      ...(cwd ? { cwd } : {}),
      ...(prev ? { parent_uuid: prev } : {}),
      blocks: blocksOf(m),
    };
    lines.push(JSON.stringify(turn));
    prev = m.id;
  }
  if (lines.length === 0) return false;

  const body = lines.join("\n") + "\n";
  const out = path.join(outDir, `${sessionId}.funes.jsonl`);
  try {
    if (fs.readFileSync(out, "utf8") === body) return false;
  } catch {}
  const tmp = path.join(outDir, `.${sessionId}.tmp`);
  fs.writeFileSync(tmp, body);
  fs.renameSync(tmp, out);
  return true;
}

const [sessionsDir, outDir, only] = process.argv.slice(2);
if (!sessionsDir || !outDir) {
  console.error("usage: convert.mjs <sessions-dir> <out-dir> [session-id]");
  process.exit(2);
}
fs.mkdirSync(outDir, { recursive: true });

const journalOf = (id) => path.join(sessionsDir, `${id}.journal.jsonl`);

let files;
if (only) {
  if (!ID_RE.test(only) || !fs.existsSync(journalOf(only))) {
    console.log("converted 0 session(s), 0 file(s) written");
    process.exit(0);
  }
  files = [journalOf(only)];
} else {
  files = fs
    .readdirSync(sessionsDir)
    .filter((n) => n.endsWith(".journal.jsonl"))
    .map((n) => path.join(sessionsDir, n))
    .sort();
}

let converted = 0;
let written = 0;
for (const f of files) {
  const id = path.basename(f).replace(/\.journal\.jsonl$/, "");
  if (!ID_RE.test(id)) continue;
  try {
    const order0 = fs.statSync(f);
    if (!order0.isFile()) continue;
    converted++;
    if (convertJournal(f, id, outDir)) written++;
  } catch (e) {
    console.error(`convert ${id}: ${e.message}`);
  }
}
console.log(`converted ${converted} session(s), ${written} file(s) written`);
