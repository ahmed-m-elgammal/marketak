/**
 * `i18n/sync-catalogue` - merges `additions.ts` into the JSON catalogues.
 *
 * A script, not a runtime import, for one reason: the catalogues are `.json` because i18next loads them
 * synchronously at startup and because a missing key is a *rendering* failure. Importing a `.ts` module to get
 * the strings would mean the build needs a TS-aware loader in the browser path, and it would move the source of
 * truth for translations into a file no editor validates as JSON.
 *
 * So `additions.ts` is the authoring surface for new keys and the JSON files are the shipped artefact, and this
 * script is the one step between them. Run after editing `additions.ts`:
 *
 *     npm run i18n:sync --workspace @marketak/admin-web
 *
 * Merges rather than overwrites, so a key already present in the JSON is only replaced when `additions.ts`
 * declares it. Existing hand-written translations are never silently discarded.
 */

import { readFileSync, writeFileSync } from "node:fs";
import { fileURLToPath } from "node:url";

import { enAdditions } from "./additions.js";
import { arAdditions } from "./additions.js";

type Json = Record<string, unknown>;

/** Deep merge of `source` onto `target`. Arrays and scalars are replaced, not concatenated. */
function merge(target: Json, source: Json): Json {
  const out: Json = { ...target };
  for (const [key, value] of Object.entries(source)) {
    const existing = out[key];
    if (
      typeof value === "object" &&
      value !== null &&
      !Array.isArray(value) &&
      typeof existing === "object" &&
      existing !== null &&
      !Array.isArray(existing)
    ) {
      out[key] = merge(existing as Json, value as Json);
    } else {
      out[key] = value;
    }
  }
  return out;
}

function sync(file: string, additions: Json): void {
  const path = fileURLToPath(new URL(file, import.meta.url));
  const current = JSON.parse(readFileSync(path, "utf8")) as Json;
  const merged = merge(current, additions);

  // Two-space indent and a trailing newline, matching what the files already use so the diff is only the new
  // keys. `JSON.stringify` with a tab here would reformat the whole file and bury the change.
  writeFileSync(path, `${JSON.stringify(merged, null, 2)}\n`, "utf8");
}

sync("./en.json", enAdditions);
sync("./ar.json", arAdditions);

process.stdout.write("i18n catalogues synced\n");