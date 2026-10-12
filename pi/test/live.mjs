// `convertLive` over sessions as pi writes them, and as it does not: at every step it must write
// the turns file `convert` writes for the same bytes.
//
// Each session is grown a byte at a time, so a step ends mid-line and mid-character: the test
// session; one with what the line reader has to get right; one rewritten under the same name; and
// one with its session header after a turn, whose cwd then belongs on the turn already written.
//
// Usage: live.mjs <work-dir>; exits 1 at the first step that differs.
import { mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { convert, convertLive } from "../convert.mjs";

const [work] = process.argv.slice(2);
const here = dirname(fileURLToPath(import.meta.url));
mkdirSync(work, { recursive: true });
const session = join(work, "live.jsonl");

function step(bytes, what) {
  writeFileSync(session, bytes);
  const live = readFileSync(convertLive(session, join(work, "live")));
  const full = readFileSync(convert(session, join(work, "full")));
  if (!live.equals(full)) {
    console.error(`pi converter, live: ${what} — not what a whole conversion writes`);
    process.exit(1);
  }
}

function grow(bytes, what) {
  for (let end = 0; end <= bytes.length; end++) {
    step(bytes.subarray(0, end), `${what}, ${end} bytes in`);
  }
}

const test = Buffer.concat([
  readFileSync(join(here, "session.jsonl")),
  Buffer.from(`{"type":"message","id":"u2","timestamp":"t","message":{"role":"user","content":[{"type":"text","text":"café — ✓"}]}}\n`),
]);
grow(test, "the test session");

// `text` sits in a JSON string as given, escapes and all.
const said = (id, text) =>
  `{"type":"message","id":"${id}","timestamp":"t","message":{"role":"user","content":[{"type":"text","text":"${text}"}]}}`;
const result = (id, text) =>
  `{"type":"message","id":"${id}","timestamp":"t","message":{"role":"toolResult","toolCallId":"c","toolName":"bash","content":[{"type":"text","text":"${text}"}]}}`;
const awkward = Buffer.concat([
  Buffer.from(`\ufeff\n{"type":"session","cwd":"/home/café"}\r\n`), // a BOM, and a CRLF end
  // Unicode whitespace around it
  Buffer.from(` \u00a0${said("ws", "trimmed as Rust trims")}\u2028\n`),
  Buffer.from(`${said("lone", "half a pair \\ud800")}\n`), // a lone surrogate: the line is dropped
  Buffer.from(said("bad", "not UTF-8: ").slice(0, -5)), // up to the text's closing quote
  Buffer.from([0xff, 0xc3, 0x28]),
  Buffer.from(`"}]}}\n`),
  Buffer.from(`${said("wide", "é ✓ 😀 — two, three and four bytes")}\r\n`),
  Buffer.from(`${said("blank", "\u00a0\u3000\\u000b")}\n`), // blank only to Unicode: no block
  Buffer.from(`{"type":"message","id":"cut"\n`), // a line that is not JSON
  Buffer.from(`${result("r", "line one\\nline two")}\n`),
]);
grow(awkward, "an awkward session");

// Rewritten under the same name: shorter, then the same length with other bytes.
step(test.subarray(0, test.length >> 1), "the test session cut short");
const rewritten = Buffer.from(test.toString("latin1").replace(/how/g, "HOW"), "latin1");
step(rewritten, "the test session rewritten");

const turn = (id) => `${said(id, "hi")}\n`;
const late = Buffer.from(turn("a") + `{"type":"session","cwd":"/late"}\n` + turn("b"));
grow(late, "a session header after a turn");
