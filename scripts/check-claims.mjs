/**
 * Banned-claims gate.
 * Lines 1-4 are case-insensitive, except the MD token, which is case-sensitive.
 * Line 5 is case-sensitive so ".md" and the display spelling "MaQkrs" do not match.
 *
 * Allow-list: repo slugs, paths, and bundle or product IDs. The gate skips a hit
 * only when the matched text sits inside one of these exact strings.
 */

import { execSync } from "node:child_process";
import { readFileSync } from "node:fs";

const allowExact = [
  "astrachan163/MaqkrsTutor-public",
  "MaqkrsTutor-public",
  "MaqkrsTutor.xcodeproj",
  "MaqkrsTutor.app",
  "MaqkrsTutorTests",
  "MaqkrsTutorUITests",
  "com.example.MaqkrsTutorTests",
  "com.example.MaqkrsTutorUITests",
  "com.example.MaqkrsTutor",
  "MaqkrsTutor",
];

const insensitivePatterns = [
  /Doctor of Medicine|\bM\.D\.|M\.D\. Candidate|four years of medical school|medical school graduate/gi,
  /federal licensing|two MSDH-licensed businesses|stood up two licensed|hired after licensing|required full FDA/gi,
  /Georgia[^.]{0,40}standards|aligned with [^.]{0,30}standards|\bGSE\b|Milestones aligned|30-day (free )?trial/gi,
  /God Mode|Cybersecurity Systems Engineer|Clearable|\bFellow\b|Pre-Vetted|Tier 5|His Name|seeking internships?/gi,
];

const sensitivePatterns = [
  /\bMD\b/g,
  /Apple ID|\bGBA\b|Game ?Boy|Nintendo|\bMaqkrs\b(?![-/._a-zA-Z0-9])|MaQkRs/g,
];

const scannedExtensions = new Set([
  ".md",
  ".swift",
  ".py",
  ".txt",
  ".html",
  ".css",
]);

function isScanned(path) {
  if (path === "scripts/check-claims.mjs" || path === "scripts/check-emoji.mjs") {
    return false;
  }
  if (
    path.endsWith("package-lock.json") ||
    path.endsWith("yarn.lock") ||
    path.endsWith("Package.resolved") ||
    path.endsWith("Podfile.lock")
  ) {
    return false;
  }
  if (
    path.startsWith("vendor/") ||
    path.startsWith("third_party/") ||
    path.startsWith("Pods/") ||
    path.includes("/vendor/")
  ) {
    return false;
  }
  const dot = path.lastIndexOf(".");
  if (dot < 0) {
    return false;
  }
  return scannedExtensions.has(path.slice(dot).toLowerCase());
}

function coveredByAllowList(line, matchIndex, matchLength) {
  const matchEnd = matchIndex + matchLength;
  return allowExact.some((allowed) => {
    let from = 0;
    while (from <= line.length) {
      const at = line.indexOf(allowed, from);
      if (at < 0) {
        return false;
      }
      const end = at + allowed.length;
      if (matchIndex >= at && matchEnd <= end) {
        return true;
      }
      from = at + 1;
    }
    return false;
  });
}

function scanText(path, text, patterns) {
  const findings = [];
  const lines = text.split(/\r?\n/);
  for (let index = 0; index < lines.length; index += 1) {
    const line = lines[index];
    for (const pattern of patterns) {
      pattern.lastIndex = 0;
      let match = pattern.exec(line);
      while (match) {
        if (!coveredByAllowList(line, match.index, match[0].length)) {
          findings.push({
            path,
            line: index + 1,
            match: match[0],
          });
        }
        if (match[0].length === 0) {
          pattern.lastIndex += 1;
        }
        match = pattern.exec(line);
      }
    }
  }
  return findings;
}

const files = execSync("git ls-files --cached --others --exclude-standard", { encoding: "utf8" })
  .split("\n")
  .map((entry) => entry.trim())
  .filter((entry) => entry.length > 0 && isScanned(entry));

const findings = [];
for (const path of files) {
  const text = readFileSync(path, "utf8");
  findings.push(...scanText(path, text, insensitivePatterns));
  findings.push(...scanText(path, text, sensitivePatterns));
}

if (findings.length > 0) {
  for (const finding of findings) {
    console.error(`${finding.path}:${finding.line}: ${finding.match}`);
  }
  console.error(`claims gate: ${findings.length} hit(s)`);
  process.exit(1);
}

console.log(`claims gate: 0 hits in ${files.length} files`);
