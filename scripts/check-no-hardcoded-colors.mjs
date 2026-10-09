/**
 * `scripts/check-no-hardcoded-colors.mjs` - enforces architecture rule 8 mechanically.
 *
 * ## Why this script exists
 *
 * The rule says no hardcoded colours in a component. A rule that lives in a reviewer's memory is a
 * rule that decays: the fortieth screen gets a `#1890ff` because someone wanted a blue and did not
 * want to read the token file.
 *
 * So the rule is a build step. This script fails `npm run verify`.
 *
 * ## What counts
 *
 * | Match | Why |
 * |---|---|
 * | `#abc` / `#aabbcc` / `#aabbccdd` | hex literals |
 * | `rgb(` / `rgba(` / `hsl(` / `hsla(` | functional colour notations |
 *
 * ## Where it is allowed
 *
 * - `apps/mobile/src/theme/tokens.ts` - the token definitions themselves
 * - `apps/mobile/src/theme/typography.ts` - the type scale, which carries no colour
 * - **native configuration**, which has no other way to express a colour:
 *   - `app.json` - the splash background and the adaptive icon background are read by the
 *     native build, which cannot `import` a TypeScript token
 *   - any `Info.plist`, `AndroidManifest.xml`, `google-services.json`, build gradle
 * - test files, which assert on specific hexes by necessity
 *
 * The design is warm paper `#F6F1E7`, so the native splash colour MUST match the token or the
 * splash flashes a different colour from the screen behind it. That is why app.json is exempt
 * rather than wrong - but it is also why the splash token is the one colour an agent must change
 * in two places, and the comment in `tokens.ts` says so.
 *
 * ## What changed from the first version of this file
 *
 * It pointed at `packages/ui/src/theme/colors.ts`, a path from a layout that no longer exists.
 * A gate whose allow-list names a deleted directory silently permits every colour in the repo.
 * The token file is now the app's own, and the exemption list is written out below rather than
 * inferred from a directory name.
 */

import { execSync } from "node:child_process";

/** The one file allowed to define colours. */
const TOKEN_FILE = "apps/mobile/src/theme/tokens.ts";

/** Files that define a colour and cannot do otherwise. */
const NATIVE_COLOUR_FILES = new Set([
  "apps/mobile/app.json",
  "apps/mobile/ios/**/Info.plist",
  "apps/mobile/android/app/src/main/AndroidManifest.xml",
]);

/** Path prefixes that are configuration or generated, not source. */
const CONFIG_PREFIXES = [
  "node_modules/",
  "apps/mobile/.expo/",
  "apps/mobile/android/",
  "apps/mobile/ios/",
  "functions/outbox-dispatcher/dist/",
];

const ROOTS = ["apps", "packages", "functions"];

/** `it("...", ...)` fixtures legitimately assert on a specific colour, so tests are exempt. */
function isTestFile(path) {
  return /\.(test|spec)\.[cm]?[jt]sx?$/u.test(path) || path.includes("/tests/");
}

/** The theme directory owns every colour definition in the project. */
function isThemeFile(path) {
  return path === TOKEN_FILE || path.startsWith("apps/mobile/src/theme/");
}

/** True when the path matches one of the allowed native configuration files. */
function isNativeConfig(path) {
  const bare = path.replaceAll("\\", "/");
  if (NATIVE_COLOUR_FILES.has(bare)) return true;
  for (const pattern of NATIVE_COLOUR_FILES) {
    if (pattern.includes("*")) {
      const regex = new RegExp(`^${pattern.replaceAll(".", "\\.").replaceAll("*", "[^/]+")}$`);
      if (regex.test(bare)) return true;
    }
  }
  return false;
}

function isConfig(path) {
  const bare = path.replaceAll("\\", "/");
  return CONFIG_PREFIXES.some((prefix) => bare.startsWith(prefix));
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
];

const violations = [];

for (const path of stagedFiles()) {
  if (!ROOTS.some((root) => path.startsWith(`${root}/`))) continue;
  if (isTestFile(path) || isThemeFile(path) || isNativeConfig(path) || isConfig(path)) continue;

  const { readFileSync } = await import("node:fs");
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

if (violations.length > 0) {
  console.error(
    `no-hardcoded-colors FAILED: ${String(violations.length)} colour(s) outside ${TOKEN_FILE}.\n` +
      `Architecture rule 8: every colour comes from the token module. Add one to\n` +
      `${TOKEN_FILE} if it is missing, then reference it by token name.\n\n` +
      `${violations.join("\n")}\n`,
  );
  process.exit(1);
}

console.log(`no-hardcoded-colors OK: every colour resolves through ${TOKEN_FILE}.`);
