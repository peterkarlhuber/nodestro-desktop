#!/usr/bin/env node
// Print the license texts of the npm packages built into the studio interface (release notices).
//
//   node scripts/npm_licenses.mjs <frontend-dir>
//
// Reads <frontend-dir>/package-lock.json and takes every runtime (non-dev) package, then prints its name, version,
// declared license and the text of each LICENSE, LICENCE, COPYING or NOTICE file in its installed directory
// (<frontend-dir>/node_modules/..., so `npm ci` must have run). A package without such a file is listed with
// "no license file", so a release reviewer sees it. Shared by nodestro-desktop and nodestro-server.
import { readFileSync, readdirSync, existsSync } from "node:fs";
import { join } from "node:path";

const frontend = process.argv[2];
if (!frontend) {
  console.error("usage: npm_licenses.mjs <frontend-dir>");
  process.exit(2);
}
const lock = JSON.parse(readFileSync(join(frontend, "package-lock.json"), "utf8"));
const files = /^(licen[cs]e|copying|notice)(\.|-|$)/i;
const out = [];
let missing = 0;
const entries = Object.entries(lock.packages ?? {})
  .filter(([path, entry]) => path && !entry.dev && !entry.devOptional)
  .sort(([a], [b]) => a.localeCompare(b));
for (const [path, entry] of entries) {
  const name = entry.name ?? path.split("node_modules/").pop();
  const dir = join(frontend, path);
  const texts = existsSync(dir)
    ? readdirSync(dir)
        .filter((f) => files.test(f))
        .sort()
        .map((f) => readFileSync(join(dir, f), "utf8").trim())
    : [];
  out.push("=".repeat(80), `${name} ${entry.version ?? ""} (npm) — ${entry.license ?? "no declared license"}`, "");
  if (texts.length === 0) {
    missing += 1;
    out.push(existsSync(dir) ? "(no license file in the package)" : "(package not installed on this platform)", "");
  }
  for (const text of texts) out.push(text, "");
}
process.stdout.write(out.join("\n") + "\n");
console.error(`npm licenses: ${entries.length} packages, ${missing} without a license file`);
