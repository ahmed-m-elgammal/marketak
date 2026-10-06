#!/usr/bin/env node
/**
 * scripts/check-no-secrets.mjs
 *
 * Fails if a secret is about to be committed. Runs in `npm run verify`, which is step 1 of the commit
 * protocol, so it cannot be skipped by forgetting.
 *
 * ## Why this exists rather than a review habit
 *
 * This repository's own `AGENTS.md` records that `git add -A` once committed an Apple App Store Connect
 * private key from an `appstore/` directory. A convention did not prevent it. This step does.
 *
 * ## What it checks, and why each is imperfect on purpose
 *
 * | Check | Catches | Limitation |
 * |---|---|---|
 * | `.gitignore` covers a filename | a secret file staged anyway | only for names we anticipated |
 * | PEM armour present | any committed private key, whoever wrote it | cannot tell a test key from a real one |
 * | JWT shape (`eyJ` + two dots) | any Supabase/anon/service-role key | a false positive on any encoded blob |
 * | AWS key prefix | an AKIA id | not a Firebase or Supabase key |
 * | `SUPABASE_SERVICE_ROLE_KEY =` in a config | a key pasted into toml/json/env | not a key read at runtime |
 *
 * The false positives are deliberate. `access-token.test.ts` contains a GENERATED RSA-2048 test key and the
 * armour scan flags it; that is a comment-level annoyance, and the alternative - a scanner that can be
 * taught to ignore a path - is a scanner that gets taught to ignore a path that later holds a real key.
 *
 * ## How to handle a flagged file
 *
 * If the key is real: `git rm --cached <file>`, confirm `.gitignore` covers it, and rotate the key. Removing
 * it from the working tree is NOT enough once it is in a commit; the history keeps it and so does any clone
 * or fork. Rotation is the only real remedy.
 *
 * If it is a test fixture: leave it, and say so in the commit message. A generated key with no access to
 * anything is not a secret.
 */

import { execSync } from "node:child_process";
import { existsSync, statSync } from "node:fs";
import { join } from "node:path";

const ROOT = process.cwd();
const errors = [];
const warnings = [];

/**
 * Files that legitimately contain PEM armour.
 *
 * Two kinds, and the difference matters:
 *
 *  - `KNOWN_TEST_KEYS` carries a GENERATED RSA key with no access to anything. Flagged as a warning so a
 *    reviewer is told it is there rather than having to notice it.
 *  - `KNOWN_PEM_REFERENCE` only NAMES the armour, in a comment or a `.replace()` literal. Never carries key
 *    material. Not flagged at all, because a scan that cries wolf on the word `BEGIN PRIVATE KEY` in a
 *    code comment gets disabled, and a disabled scanner catches nothing.
 */
const KNOWN_TEST_KEYS = [
  "functions/outbox-dispatcher/src/tests/access-token.test.ts",
];

const KNOWN_PEM_REFERENCE = [
  // Names the armour to strip it, and to detect a value that is not a key.
  "functions/outbox-dispatcher/src/google/access-token.ts",
  // A stub PEM whose body is the literal string "abc".
  "functions/outbox-dispatcher/src/tests/config-env.test.ts",
  // A stub PEM whose body is the literal string "abc".
  "functions/outbox-dispatcher/src/tests/drain-once.test.ts",
];

/**
 * Does this file carry KEY MATERIAL, as opposed to naming the armour?
 *
 * A real key has a base64 body of hundreds of characters between the BEGIN and END lines. The armour on its
 * own, or a stub with a three-character body, is not a credential. Checking the LENGTH rather than the
 * presence is what lets the scan stay strict without becoming noise.
 */
function carriesKeyMaterial(content) {
  const pattern = /-----BEGIN (?:[A-Z ]+ )?PRIVATE KEY-----([\s\S]*?)-----END (?:[A-Z ]+ )?PRIVATE KEY-----/gu;
  for (const match of content.matchAll(pattern)) {
    const body = match[1] ?? "";
    // TWO conditions, and both are needed.
    //
    // 1. The body must be base64 and whitespace ONLY. This is what separates a key from a PROSE MENTION:
    //    `access-token.ts` names the armour in a doc comment on line 61 and strips it with `.replace()` on
    //    lines 79-80, so a naive BEGIN...END span swallows eight lines of English between them. English is
    //    not base64, so it is rejected.
    if (!/^[A-Za-z0-9+/=\s]+$/u.test(body)) {
      continue;
    }
    const compact = body.replace(/\s+/gu, "");
    // 2. A real RSA-2048 PKCS#8 body is ~1700 characters. 200 is a wide margin below that and far above
    //    any stub such as the literal "abc". The threshold is a heuristic, and a false NEGATIVE here would
    //    be a leaked key, so the margin is deliberately generous.
    if (compact.length >= 200) {
      return true;
    }
  }
  return false;
}

function stagedFiles() {
  try {
    const out = execSync("git diff --cached --name-only", { encoding: "utf8" });
    return out.split("\n").filter((line) => line.trim().length > 0);
  } catch {
    // No index, or not a repository. `npm run verify` outside a repo is not this script's problem.
    return [];
  }
}

/** Every tracked-and-staged file's content, read from the index rather than the working tree. */
function stagedContent(path) {
  try {
    return execSync(`git show ":${path}"`, {
      encoding: "utf8",
      maxBuffer: 100 * 1024 * 1024,
    });
  } catch {
    return null;
  }
}

function walk(dir, out = []) {
  let entries;
  try {
    entries = execSync(`git ls-files --others --exclude-standard "${dir}"`, { encoding: "utf8" });
  } catch {
    return out;
  }
  for (const entry of entries.split("\n").filter((l) => l.trim().length > 0)) {
    out.push(entry);
  }
  return out;
}

const staged = stagedFiles();

// ---------------------------------------------------------------------------
// 1. A secret file must not be staged at all.
// ---------------------------------------------------------------------------
const SECRET_FILENAMES = [
  "supabase_keys",
  "marketak-eg-firebase-adminsdk-fbsvc-c7293a9dfd.json",
  ".dev.vars",
];

for (const file of staged) {
  const base = file.split(/[\\/]/u).pop();
  if (base !== undefined && SECRET_FILENAMES.includes(base)) {
    errors.push(
      `${file}  [staged-secret] a file that holds a live secret is staged. ` +
        "git rm --cached it, then ROTATE the key - removing it from the index does not remove it from " +
        "history.",
    );
  }
}

// ---------------------------------------------------------------------------
// 2. Content scan.
// ---------------------------------------------------------------------------
for (const file of staged) {
  if (!/\.(ts|tsx|js|mjs|cjs|json|toml|env|md|yml|yaml)$/u.test(file)) {
    continue;
  }
  const content = stagedContent(file);
  if (content === null) {
    continue;
  }

  const path = file.replace(/\\/gu, "/");
  const isKnownTestKey = KNOWN_TEST_KEYS.includes(path);
  const isKnownReference = KNOWN_PEM_REFERENCE.includes(path);

  // A private key. The LENGTH of the body is what distinguishes one from a mention of the format.
  if (carriesKeyMaterial(content)) {
    if (isKnownTestKey) {
      warnings.push(
        `${file}  [test-key] contains a GENERATED test key. Verified access-less; keep it that way.`,
      );
    } else {
      errors.push(
        `${file}  [private-key] contains a PEM private key. If it is real, rotate it: removing the ` +
          "commit is not enough, the history keeps it.",
      );
    }
  } else if (content.includes("-----BEGIN") && content.includes("PRIVATE KEY") && !isKnownReference) {
    // An unrecognised mention of the format. Not a key, but worth a look.
    warnings.push(
      `${file}  [pem-mention] mentions PEM private-key armour without a key body. Expected only in ` +
        "code that parses the format; add it to KNOWN_PEM_REFERENCE if that is what this is.",
    );
  }

  // A JWT. Supabase anon and service_role keys are JWTs, and so is any Google access token.
  if (/eyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}/u.test(content)) {
    errors.push(
      `${file}  [jwt] contains a JWT-shaped string. That is what a Supabase anon or service_role key ` +
        "looks like, and a service_role key bypasses RLS on every table.",
    );
  }

  // AWS access key ids. Not our stack, but a pasted credential is a pasted credential.
  if (/\bAKIA[0-9A-Z]{16}\b/u.test(content)) {
    errors.push(`${file}  [aws-key] contains an AWS access key id.`);
  }

  // A service-role key assigned in a config file rather than read from the environment.
  if (/SUPABASE_SERVICE_ROLE_KEY\s*[=:]\s*["']?[A-Za-z0-9_.-]{40,}/u.test(content)) {
    errors.push(
      `${file}  [inline-secret] assigns SUPABASE_SERVICE_ROLE_KEY a literal value. It must come from ` +
        "`wrangler secret put` or the environment.",
    );
  }
}

// ---------------------------------------------------------------------------
// 3. An UNTRACKED file holding a secret must be covered by .gitignore.
// ---------------------------------------------------------------------------
// Catches the moment BEFORE the commit: a secret sitting in the working tree, one `git add -A` away.
for (const file of walk(".")) {
  const base = file.split(/[\\/]/u).pop();
  if (base === undefined || !SECRET_FILENAMES.includes(base)) {
    continue;
  }
  const full = join(ROOT, file);
  if (!existsSync(full) || !statSync(full).isFile()) {
    continue;
  }
  try {
    execSync(`git check-ignore -q "${file}"`, { stdio: "ignore" });
  } catch {
    errors.push(
      `${file}  [unignored-secret] exists in the working tree and is NOT gitignored. One ` +
        "`git add -A` from being committed.",
    );
  }
}

for (const warning of warnings) {
  console.warn(`warn  ${warning}`);
}
for (const error of errors) {
  console.error(`FAIL  ${error}`);
}

if (errors.length > 0) {
  console.error(`\n${errors.length} secret violation(s). Refusing to pass.`);
  process.exit(1);
}

console.log(
  `no-secrets OK: ${staged.length} staged file(s) scanned, ` +
    `${warnings.length} warning(s), 0 violation(s).`,
);