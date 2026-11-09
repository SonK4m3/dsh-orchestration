#!/usr/bin/env node
// Print raw bytes around each hit of a literal string inside a packed app.asar.
//
//   node tools/asar-slice.js <path-to-app.asar> <needle> [before] [after] [limit]
//
// Why this exists: DSH ships as one ~180 MB asar archive, so the source of every
// runtime fact (model ids, skill roots, tool schemas) is a byte offset inside it.
// `rg -a` finds offsets but not readable context, and a windowed pattern such as
// `.{200}needle` silently fails whenever a newline falls inside the window. This
// prints the window directly, so newlines cannot break the search.
//
// Reading the archive with fs is safe: it is a plain file, not a mounted volume.

const fs = require("fs");

const [, , file, needle, beforeArg, afterArg, limitArg] = process.argv;
if (!file || !needle) {
  console.error("usage: node tools/asar-slice.js <app.asar> <needle> [before] [after] [limit]");
  process.exit(2);
}
if (!fs.existsSync(file)) {
  console.error("no such file: " + file);
  process.exit(2);
}

const before = Number(beforeArg || 300);
const after = Number(afterArg || 300);
const limit = Number(limitArg || 4);

// latin1 maps every byte to one char, so offsets stay meaningful and no byte is lost.
const text = fs.readFileSync(file).toString("latin1");

let at = text.indexOf(needle);
let shown = 0;
while (at !== -1 && shown < limit) {
  const start = Math.max(0, at - before);
  const slice = text.slice(start, at + needle.length + after);
  const clean = slice.replace(/[^\x09\x0a\x20-\x7e]/g, ".");
  console.log("---- hit " + (shown + 1) + " @byte " + at + " ----");
  console.log(clean);
  shown += 1;
  at = text.indexOf(needle, at + needle.length);
}

if (shown === 0) {
  console.log("no hit for " + JSON.stringify(needle));
  console.log("the archive may hold this string split across its index; try a shorter needle");
  process.exit(1);
}
