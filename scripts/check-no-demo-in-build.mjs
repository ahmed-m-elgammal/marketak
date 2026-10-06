/**
 * `check-no-demo-in-build` - fails if the demo fixture flag survives into a production bundle.
 *
 * ## Why this is a script and not a comment
 *
 * `isDemoMode()` reads `import.meta.env.VITE_DEMO`, and Vite **replaces that with a literal at build time**.
 * So a build made without the variable set contains `false` and no trace of the name - which is the desired
 * outcome. But it also means that if anything ever routes the flag through a path Vite cannot inline (a
 * computed key, a `process.env` shim, a runtime config fetch), the name *would* survive - and the demo would
 * quietly switch itself on in production, serving sample numbers to real operators who believe they are looking
 * at the database.
 *
 * That is a genuinely bad failure and it is invisible in review, because the code looks correct either way.
 * So it gets a gate: grep `dist/`, and if the flag name is in there, fail the build.
 *
 * ## Why it accepts an argument
 *
 * Defaults to `apps/admin-web/dist`. A path is accepted so the root `verify` can point it at whichever
 * workspace built, and so it is testable without running a production build.
 */

import { readdirSync, readFileSync, statSync } from "node:fs";
import { join, resolve } from "node:path";

/** Must match `DEMO_ENV_KEY` in `apps/admin-web/src/lib/demo-mode.ts`. */
const DEMO_FLAG = "VITE_DEMO";

const distDir = resolve(process.argv[2] ?? "apps/admin-web/dist");

/** Every file under `dir`, or `[]` when `dir` does not exist. */
function walk(dir) {
  let entries;
  try {
    entries = readdirSync(dir);
  } catch {
    return [];
  }
  return entries.flatMap((entry) => {
    const full = join(dir, entry);
    return statSync(full).isDirectory() ? walk(full) : [full];
  });
}

const files = walk(distDir).filter((file) => /\.(js|mjs|css|html|json)$/u.test(file));

if (files.length === 0) {
  process.stderr.write(`check-no-demo-in-build: no build output at ${distDir} - run the build first\n`);
  process.exit(1);
}

const offenders = files.filter((file) => readFileSync(file, "utf8").includes(DEMO_FLAG));

if (offenders.length > 0) {
  process.stderr.write(
    `check-no-demo-in-build: FAILED. The demo flag "${DEMO_FLAG}" survives into the build:\n` +
      `${offenders.map((file) => `  ${file}`).join("\n")}\n\n` +
      "Sample data must never reach production. Either the flag was inlined at build time (good, and this " +
      "string should be gone), or it was routed somewhere Vite cannot see - which means it is still live at " +
      "runtime. Check src/lib/demo-mode.ts.\n",
  );
  process.exit(1);
}

process.stdout.write(
  `check-no-demo-in-build OK: ${files.length} file(s) scanned, "${DEMO_FLAG}" absent from the build.\n`,
);
