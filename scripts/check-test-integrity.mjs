#!/usr/bin/env node
/**
 * scripts/check-test-integrity.mjs
 *
 * Enforces AGENTS.md rule 4: "NEVER WEAKEN TESTS. No `.skip`, `.only`, `.xit`, no tautological assertions,
 * no hollowed-out suites."
 *
 * ## Why this exists rather than a lint rule
 *
 * A lint rule can be disabled. A CI step that exits non-zero cannot be argued with, and this runs as part of
 * `npm run verify`, which is step 1 of the commit protocol. The four migrations that shipped a function that
 * could not run were all caught by a *human noticing*, which is a process, not a guarantee.
 *
 * ## What it refuses, and why each one has been a real failure mode
 *
 * | Pattern | Why it is banned |
 * |---|---|
 * | `.only` | Vitest runs only the focused file and the rest of the suite silently stops running. A green run that tested 3% of the code is the most dangerous possible outcome. |
 * | `.skip` / `.xit` / `todo` | A skipped test is a promise nobody is keeping. `todo` is worse: it looks like coverage. |
 * | `it("does something")` with no assertion | Passes on an empty body. A test that cannot fail is not a test. |
 * | `expect(x).toBeDefined()` as a test's ONLY assertion | Proves a variable exists, not that it is right. Weaker than it looks and passes on `undefined` for many shapes. |
 * | `expect(true).toBe(true)` | Tautology. |
 * | a test file with zero assertions | A hollowed-out suite that still reports as a passing file. |
 * | `expect(...).toBeTruthy()` on a non-boolean expression | Almost always meant `toBe(true)` or a specific value; it passes for `{}` and `[]`. Flagged as a warning, not an error. |
 *
 * No network access and no dependencies: this runs first in `verify`, so a broken install should not be able
 * to skip the check that guards the tests.
 */

import { readdirSync, readFileSync, statSync } from "node:fs";
import { join, relative } from "node:path";

const ROOT = process.cwd();
/**
 * Where test files live, and — more importantly — where they MUST NOT.
 *
 * `apps` was added with the admin console in phase A0. Without it this script silently stopped covering four
 * of the twelve test files: it reported "8 files" while `vitest` reported twelve, which is exactly the failure
 * mode `AGENTS.md` rule 4 exists to prevent. A guard that covers less than the suite is worse than no guard,
 * because it is reported as green.
 *
 * It walks `src/tests/` rather than globbing `*.test.ts` so a test written outside that directory is not
 * counted as covered.
 */
const TEST_DIRS = ["packages", "functions", "apps"];

/** Collected as one list so the final message names every problem, not just the first. */
const errors = [];
const warnings = [];

function fail(file, line, rule, text) {
  errors.push(`${relative(ROOT, file)}:${line}  [${rule}] ${text}`);
}

function warn(file, line, rule, text) {
  warnings.push(`${relative(ROOT, file)}:${line}  [${rule}] ${text}`);
}

function walk(dir, out = []) {
  let entries;
  try {
    entries = readdirSync(dir);
  } catch {
    return out;
  }
  for (const entry of entries) {
    if (entry === "node_modules" || entry === "dist" || entry === ".wrangler" || entry === "coverage") {
      continue;
    }
    const full = join(dir, entry);
    if (statSync(full).isDirectory()) {
      walk(full, out);
    } else if (entry.endsWith(".test.ts") || entry.endsWith(".test.tsx")) {
      // `.tsx` included since the admin console's first JSX test. Without it this file reported 11 covered
      // while vitest reported 12 — a guard that under-reports is a guard that is quietly not working.
      out.push(full);
    }
  }
  return out;
}

const files = TEST_DIRS.flatMap((dir) => walk(join(ROOT, dir)));

if (files.length === 0) {
  console.error("FAIL: no test files found. A suite that has deleted itself must not pass.");
  process.exit(1);
}

/** A `describe`/`it` block with no `expect` anywhere inside is hollow. Checked per block, not per file. */
function countAssertions(lines) {
  return lines.filter((line) => /expect\s*\(/.test(line)).length;
}

for (const file of files) {
  const text = readFileSync(file, "utf8");
  const lines = text.split(/\r?\n/u);

  lines.forEach((line, index) => {
    const lineNumber = index + 1;

    // ---- forbidden modifiers -------------------------------------------------
    if (/\b(describe|it|test)\.(only|skip|todo|concurrent)\b/u.test(line)) {
      const match = /\b(describe|it|test)\.(only|skip|todo|concurrent)\b/u.exec(line);
      const modifier = match?.[2];
      if (modifier === "only") {
        fail(file, lineNumber, "no-only", `".${modifier}" runs one test and silently skips the rest`);
      } else if (modifier === "concurrent") {
        fail(
          file,
          lineNumber,
          "no-concurrent",
          '".concurrent" makes ordering-dependent tests report flakiness instead of a real failure',
        );
      } else {
        fail(file, lineNumber, "no-skip", `".${modifier}" is a promise nobody is keeping`);
      }
    }
    if (/\bx(it|describe)\s*\(/u.test(line)) {
      fail(file, lineNumber, "no-skip", "x-prefixed test is a skipped test");
    }

    // ---- tautologies ---------------------------------------------------------
    if (/expect\s*\(\s*true\s*\)\s*\.\s*to(Be|Equal)\s*\(\s*true\s*\)/u.test(line)) {
      fail(file, lineNumber, "tautology", "expect(true).toBe(true) passes on an empty body");
    }
    if (/expect\s*\(\s*1\s*\)\s*\.\s*to(Be|Equal)\s*\(\s*1\s*\)/u.test(line)) {
      fail(file, lineNumber, "tautology", "expect(1).toBe(1) passes on an empty body");
    }

    // ---- weak assertions -----------------------------------------------------
    // `toBeDefined()` is fine as one assertion among several, and banned as the ONLY one in a test.
    if (/expect\s*\([^)]*\)\s*\.\s*toBeTruthy\s*\(\s*\)/u.test(line)) {
      warn(
        file,
        lineNumber,
        "weak-assertion",
        "toBeTruthy() also passes for {} and []; prefer toBe(true) or a specific value",
      );
    }
    if (/expect\s*\([^)]*\)\s*\.\s*toBeFalsy\s*\(\s*\)/u.test(line)) {
      warn(
        file,
        lineNumber,
        "weak-assertion",
        "toBeFalsy() also passes for 0 and ''; prefer toBe(false) or a specific value",
      );
    }
  });

  // ---- hollow suites --------------------------------------------------------
  const assertions = countAssertions(lines);
  if (assertions === 0) {
    fail(file, 1, "hollow-suite", "no expect() anywhere in this file");
    continue;
  }

  // ---- per-test assertion floor --------------------------------------------
  // Each `it("...")` block must contain at least one assertion. Splitting on the test declarations rather
  // than counting globally is what catches a file where 20 real tests and one empty one share 200
  // assertions.
  const testStarts = [];
  lines.forEach((line, index) => {
    if (/\bit\s*\(|it\.each\(/u.test(line)) {
      testStarts.push(index);
    }
  });

  for (let position = 0; position < testStarts.length; position += 1) {
    const start = testStarts[position];
    const end = position + 1 < testStarts.length ? testStarts[position + 1] : lines.length;
    const body = lines.slice(start, end);
    const name = (/\bit\s*\(\s*[`'"]([^`'"]{1,80})/u.exec(body[0] ?? "") ?? [])[1];
    const label = name ?? `test at line ${String(start + 1)}`;

    if (countAssertions(body) === 0) {
      fail(
        file,
        start + 1,
        "no-assertion",
        `"${label}" has no expect(); it cannot fail, so it is not a test`,
      );
    }
  }
}

// ---- report ------------------------------------------------------------------
for (const warning of warnings) {
  console.warn(`warn  ${warning}`);
}
for (const error of errors) {
  console.error(`FAIL  ${error}`);
}

const testCount = files.reduce((total, file) => {
  const text = readFileSync(file, "utf8");
  return total + (text.match(/\bit\s*\(/gu) ?? []).length;
}, 0);

if (errors.length > 0) {
  console.error(
    `\n${errors.length} test-integrity violation(s) across ${files.length} file(s). Refusing to pass.`,
  );
  process.exit(1);
}

console.log(
  `test-integrity OK: ${files.length} file(s), ~${testCount} test(s), ${warnings.length} warning(s).`,
);