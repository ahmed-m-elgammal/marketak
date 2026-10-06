/**
 * `scripts/check-no-hardcoded-colors.mjs` - enforces AGENTS.md rule 2 mechanically.
 *
 * ## Why this script exists
 *
 * The rule says no hardcoded colours or spacing in a component. A rule that lives in a reviewer's memory is a
 * rule that decays: the fortieth screen gets a `#1890ff` because someone wanted a blue and did not want to
 * read the token file. That is also, precisely, the failure mode the token module was introduced to prevent -
 * Ant Design's defaults are below WCAG AA for `colorError`, so a component taking an untracked colour is a
 * component that fails contrast.
 *
 * So the rule is a build step. This script fails `npm run verify`.
 *
 * ## What counts
 *
 * | Match | Why |
 * |---|---|
 * | `#abc` / `#aabbcc` / `#aabbccdd` | hex literals |
 * | `rgb(` / `rgba(` / `hsl(` / `hsla(` | functional colour notations |
 * | antd colour props (`color=`, `bg=`, `borderColor=`) | the smuggling route |
 *
 * ## Where it is allowed
 *
 * - `packages/ui/src/theme/colors.ts` - the token definitions themselves
 * - `global.css` - but only `var(--...)` references, checked separately below
 * - test files, which assert on specific hexes by necessity
 *
 * ## The CSS rule
 *
 * `global.css` is allowed to reference tokens but never to define a colour. That is a stricter rule than the
 * one on TSX, and it is the one that matters: a stylesheet is where a hardcoded hex survives longest, because
 * nobody reads a stylesheet during a code review of a component.
 */

import { execSync } from "node:child_process";
import { readFileSync } from "node:fs";

/** The one file allowed to define colours. */
const TOKEN_FILE = "packages/ui/src/theme/colors.ts";

/** Files allowed to reference colour at all, provided they only use `var(--...)`. */
const CSS_FILES = new Set(["apps/admin-web/src/app/styles/global.css"]);

const ROOTS = ["apps", "packages", "functions"];

/** `it("...", ...)` fixtures legitimately assert on a specific colour, so tests are exempt. */
function isTestFile(path) {
  return /\.(test|spec)\.[cm]?[jt]sx?$/u.test(path) || path.includes(`${"src"}tests/`);
}

function isThemeFile(path) {
  return path === TOKEN_FILE || path.startsWith("packages/ui/src/theme/");
}

function stagedFiles() {
  try {
    const out = execSync("git ls-files --cached --others --exclude-standard", {
      encoding: "utf8",
      maxBuffer: 50 * 1024 * 1024,
    });
    return out.split("\n").filter((line) => line.trim().length > 0);
  } catch {
    return [];
  }
}

const COLOR_PATTERNS = [
  { label: "hex", regex: /#[0-9a-f]{3,8}\b/giu },
  { label: "rgb", regex: /\brgba?\s*\(/giu },
  { label: "hsl", regex: /\bhsla?\s*\(/giu },
  // antd prop names that take a colour. `\b` before, and the value is not a `var(`.
  { label: "antd colour prop", regex: /\b(?:color|bg|borderColor|fill|borderColorSecondary|bgContainer)\s*=\s*["'](?!var\()/giu },
];

const violations = [];

for (const path of stagedFiles()) {
  if (!ROOTS.some((root) => path.startsWith(`${root}/`))) {
    continue;
  }
  if (isTestFile(path) || isThemeFile(path)) {
    continue;
  }

  let content;
  try {
    content = readFileSync(path, "utf8");
  } catch {
    continue;
  }

  for (const { label, regex } of COLOR_PATTERNS) {
    regex.lastIndex = 0;
    for (const match of content.matchAll(regex)) {
      const line = content.slice(0, match.index).split("\n").length;
      violations.push(`  ${path}:${String(line)}  [${label}] ${match[0]}`);
    }
  }
}

// --- the CSS rule: a stylesheet may reference a token, never define one ---

for (const path of CSS_FILES) {
  let content;
  try {
    content = readFileSync(path, "utf8");
  } catch {
    continue;
  }
  for (const { label, regex } of COLOR_PATTERNS) {
    if (label === "antd colour prop") {
      continue;
    }
    regex.lastIndex = 0;
    for (const match of content.matchAll(regex)) {
      const line = content.slice(0, match.index).split("\n").length;
      violations.push(`  ${path}:${String(line)}  [css ${label}] ${match[0]} - use var(--color-*)`);
    }
  }
}

if (violations.length > 0) {
  console.error(
    `no-hardcoded-colors FAILED: ${String(violations.length)} colour(s) outside ${TOKEN_FILE}.\n` +
      `AGENTS.md rule 2: every colour comes from the token module. Add one to\n` +
      `packages/ui/src/theme/colors.ts if it is missing, then reference it.\n\n` +
      `${violations.join("\n")}\n`,
  );
  process.exit(1);
}

console.log(`no-hardcoded-colors OK: every colour resolves through ${TOKEN_FILE}.`);