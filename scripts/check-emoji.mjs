/**
 * Emoji gate for tracked text files.
 * Fails on U+1F000-1FAFF, U+2600-27BF, U+2B00-2BFF, U+FE0F,
 * and the check or cross marks U+2705, U+2714, U+2716, U+274C, U+274E.
 * Arrows U+2190-21FF are allowed. Lockfiles, fonts, and vendored trees are skipped.
 */

import { execSync } from "node:child_process";
import { readFileSync } from "node:fs";

const banned =
  /[\u{1F000}-\u{1FAFF}\u{2600}-\u{27BF}\u{2B00}-\u{2BFF}\u{FE0F}\u{2705}\u{2714}\u{2716}\u{274C}\u{274E}]/u;

const skippedExtensions = new Set([
  ".png",
  ".jpg",
  ".jpeg",
  ".gif",
  ".webp",
  ".ico",
  ".pdf",
  ".zip",
  ".gz",
  ".woff",
  ".woff2",
  ".ttf",
  ".otf",
  ".eot",
]);

function isSkipped(path) {
  if (path === "scripts/check-emoji.mjs" || path === "scripts/check-claims.mjs") {
    return true;
  }
  const base = path.split("/").pop() ?? path;
  if (
    base === "package-lock.json" ||
    base === "yarn.lock" ||
    base === "pnpm-lock.yaml" ||
    base === "Package.resolved" ||
    base === "Podfile.lock" ||
    base === "Gemfile.lock"
  ) {
    return true;
  }
  if (
    path.startsWith("vendor/") ||
    path.startsWith("third_party/") ||
    path.startsWith("Pods/") ||
    path.startsWith(".build/") ||
    path.includes("/vendor/")
  ) {
    return true;
  }
  const dot = base.lastIndexOf(".");
  if (dot >= 0 && skippedExtensions.has(base.slice(dot).toLowerCase())) {
    return true;
  }
  return false;
}

const files = execSync("git ls-files --cached --others --exclude-standard", { encoding: "utf8" })
  .split("\n")
  .map((entry) => entry.trim())
  .filter((entry) => entry.length > 0 && !isSkipped(entry));

const findings = [];

for (const path of files) {
  const bytes = readFileSync(path);
  if (bytes.includes(0)) {
    continue;
  }
  const text = bytes.toString("utf8");
  const lines = text.split(/\r?\n/);
  for (let index = 0; index < lines.length; index += 1) {
    const line = lines[index];
    const match = banned.exec(line);
    if (match) {
      const code = match[0].codePointAt(0).toString(16).toUpperCase();
      findings.push(`${path}:${index + 1}: U+${code}`);
    }
  }
}

if (findings.length > 0) {
  for (const finding of findings) {
    console.error(finding);
  }
  console.error(`emoji gate: ${findings.length} hit(s)`);
  process.exit(1);
}

console.log(`emoji gate: 0 hits in ${files.length} files`);
