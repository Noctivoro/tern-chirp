#!/usr/bin/env node
// Renders every preset mood in test/presets.luau to WAV files and, with
// --play, plays them in turn: a way to hear Chirp without waiting for an agent.
//   node bin/audition.mjs [--out DIR] [--play]
import { execFileSync } from "node:child_process";
import { mkdirSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const root = join(dirname(fileURLToPath(import.meta.url)), "..");
const args = process.argv.slice(2);
const outIndex = args.indexOf("--out");
const out = outIndex >= 0 ? args[outIndex + 1] : join(tmpdir(), "tern-chirp-audition");
const play = args.includes("--play");

mkdirSync(out, { recursive: true });
const lines = execFileSync("luau", ["--codegen", "test/presets.luau"], { cwd: root, maxBuffer: 64 * 1024 * 1024 })
  .toString()
  .trim()
  .split("\n");

for (const line of lines) {
  const [name, secs, ms, hex] = line.split("\t");
  const file = join(out, `${name}.wav`);
  writeFileSync(file, Buffer.from(hex, "hex"));
  console.log(`${name.padEnd(18)} ${secs}s  rendered in ${ms} ms  ${file}`);
  // 0.2 is Chirp's default volume, so this is how it sounds in Tern.
  if (play) execFileSync("afplay", ["-v", "0.2", file]);
}
