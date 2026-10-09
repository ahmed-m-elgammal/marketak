/**
 * `scripts/check-status-types.mjs` - architecture rule 4, verified.
 *
 * The database has no Postgres enums. Every status column is `text` plus a
 * `CHECK` constraint, so a wrong string is a **runtime** failure and there is no
 * database type to catch it. The defence is `packages/shared/src/status.ts`, which
 * transcribes each vocabulary from the constraint. But a transcription that is
 * never checked is just documentation with extra steps: the day a migration adds
 * `flowers` to `vendors.vertical_type`, the union silently under-reports and the
 * first symptom is a vendor that renders as an unknown vertical.
 *
 * So this script reads the live constraints and compares them to the arrays. It
 * exits:
 *
 *   0  every vocabulary matches
 *   1  drift - a value was added, removed or renamed on either side
 *   2  unchecked - no `SUPABASE_DB_URL`, so the comparison never ran
 *
 * Exit 2 is "unchecked", never "clean". `npm run verify` treats it as a failure
 * for the same reason `scripts/check-policies.mjs` does: a gate that cannot run
 * must not report success, because the one time it matters is the time nobody
 * looked.
 */

import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const ROOT = join(dirname(fileURLToPath(import.meta.url)), "..");
const URL = process.env.SUPABASE_DB_URL ?? "";

/** Extracts the string literals from a constraint definition. */
function literalsFromConstraint(definition) {
  const found = [...definition.matchAll(/'([^']*)'/gu)].map((m) => m[1]);
  return found;
}

/**
 * Maps `table.column` to the constraint that guards it. The constraint name is not
 * trusted; the column it constrains is read from `pg_constraint.conkey`.
 */
function constraintsByColumn(rows) {
  const byColumn = new Map();
  for (const row of rows) {
    const values = literalsFromConstraint(row.definition);
    if (values.length === 0) continue;
    const key = `${row.table}.${row.column}`;
    const existing = byColumn.get(key) ?? [];
    existing.push({ name: row.name, values, definition: row.definition });
    byColumn.set(key, existing);
  }
  return byColumn;
}

async function loadVocabularies() {
  const distPath = join(ROOT, "packages/shared/dist/index.js");
  let module;
  try {
    module = await import(`file://${distPath.replace(/\\/gu, "/")}`);
  } catch {
    console.error(
      "check-status-types FAILED: cannot import packages/shared/dist/index.js.\n" +
        "Run `npm run typecheck` first - `tsc --build` emits the package this script reads.\n",
    );
    process.exit(2);
  }
  return module.STATUS_VOCABULARIES ?? {};
}

async function fetchConstraints(connectionString) {
  const { default: pg } = await import("pg").catch(() => {
    console.error(
      "check-status-types FAILED: the `pg` driver is not installed.\n" +
        "It is a root devDependency. Run `npm install` at the repo root.\n",
    );
    process.exit(2);
  });

  const client = new pg.Client({ connectionString });
  await client.connect();
  try {
    const result = await client.query(
      `select c.conname                              as name,
              c.conrelid::regclass::text             as table,
              (select a.attname
                 from unnest(c.conkey) with ordinality as k(attnum, ord)
                 join pg_attribute a on a.attrelid = c.conrelid and a.attnum = k.attnum
                order by k.ord
                limit 1)                            as column,
              pg_get_constraintdef(c.oid)           as definition
         from pg_constraint c
        where c.connamespace = 'public'::regnamespace
          and c.contype = 'c'
        order by c.conrelid::regclass::text, c.conname`,
    );
    return result.rows;
  } finally {
    await client.end();
  }
}

function compare(name, expected, constraints) {
  const guards = constraints.get(name);
  if (guards === undefined) {
    return { name, status: "missing", expected };
  }

  // A column may be guarded by more than one CHECK. The vocabulary is the union,
  // because the column accepts a value if any one constraint allows it.
  const actual = [...new Set(guards.flatMap((g) => g.values))].sort();
  const wanted = [...new Set(expected)].sort();

  const added = actual.filter((v) => !wanted.includes(v));
  const removed = wanted.filter((v) => !actual.includes(v));

  if (added.length === 0 && removed.length === 0) {
    return { name, status: "ok" };
  }
  return { name, status: "drift", added, removed, guards: guards.map((g) => g.name) };
}

if (URL.trim() === "") {
  console.error(
    "check-status-types UNCHECKED: SUPABASE_DB_URL is not set.\n" +
      "This gate compares the status unions in packages/shared against the live CHECK\n" +
      "constraints, and it cannot run without a direct connection. Exit 2 means the\n" +
      "comparison did not happen, not that it passed. Set SUPABASE_DB_URL in .env\n" +
      "(Project Settings > Database > Connection string > Session pooler).\n",
  );
  process.exit(2);
}

const vocabularies = await loadVocabularies();
const rows = await fetchConstraints(URL);
const byColumn = constraintsByColumn(rows);

const problems = [];
const unchecked = [];

for (const [name, vocabulary] of Object.entries(vocabularies)) {
  const values = Array.isArray(vocabulary) ? vocabulary : (vocabulary.list ?? []);
  if (!Array.isArray(values)) {
    unchecked.push(`${name} - not an array of values`);
    continue;
  }
  const result = compare(name, values, byColumn);
  if (result.status === "ok") continue;
  if (result.status === "missing") {
    problems.push(`${name}: no CHECK constraint found on that column`);
    continue;
  }
  const detail = [];
  if (result.added.length > 0) detail.push(`in the database but not in the union: ${result.added.join(", ")}`);
  if (result.removed.length > 0) detail.push(`in the union but not in the database: ${result.removed.join(", ")}`);
  problems.push(`${name} (guarded by ${result.guards.join(", ")})\n    ${detail.join("\n    ")}`);
}

if (problems.length > 0) {
  console.error(
    `check-status-types FAILED: ${String(problems.length)} vocabulary drift(s).\n\n` +
      problems.map((p) => `  ${p}`).join("\n\n") +
      "\n\nThe database has no enums, so this is the only thing standing between a\n" +
      "migration and a runtime failure. Update packages/shared/src/status.ts to match\n" +
      "the live constraint, or the constraint to match the union - and never edit a\n" +
      "test to make it pass.\n",
  );
  process.exit(1);
}

if (unchecked.length > 0) {
  console.error(`check-status-types UNCHECKED:\n  ${unchecked.join("\n  ")}\n`);
  process.exit(2);
}

console.log(
  `check-status-types OK: ${String(Object.keys(vocabularies).length)} vocabularies match the live CHECK constraints.`,
);
