#!/usr/bin/env node
/**
 * scripts/check-policies.mjs
 *
 * Reads the LIVE database and fails on the three things `tasks.md` T0.1c names:
 *
 *   1. a bare `auth.uid()` inside a policy  (data-model.md §13.2)
 *   2. `set search_path = public` in a `security definer` function (§13.2)
 *   3. an unindexed foreign key (§14.2)
 *
 * ## Exit codes, and why there are three
 *
 * | Code | Meaning |
 * |---|---|
 * | 0 | every check passed |
 * | 1 | a check RAN and FAILED — the database violates the rule |
 * | 2 | the checks did not run at all — no connection string |
 *
 * Exit 2 exists so that a missing `SUPABASE_DB_URL` can never look like a pass. The failure mode this
 * script exists to prevent is a green `verify` on a database nobody checked; making "I could not look"
 * a distinct exit code means CI can tell the difference and refuse to treat it as green.
 *
 * ## Why the Node script and not only the SQL
 *
 * The bare-`auth.uid()` and `search_path` rules are ALREADY enforced in the database, by assertions in
 * migrations 020 and 022. Those are the real enforcement and they run on every migration. This script is
 * the report a developer and a CI job can read without applying anything: it answers "is the live
 * project still clean" rather than "would this migration be rejected".
 *
 * The unindexed-FK rule had no such enforcement. It was a paragraph in data-model.md §14.2 and a query
 * to run by hand. It is now mechanical — and on its first run against `erxxsebcqqcpkipzcdhg` it found
 * three, in a schema documented as having zero.
 *
 * ## Configuration
 *
 *   SUPABASE_DB_URL   postgres://user:pass@db.<ref>.supabase.co:5432/postgres
 *   DATABASE_URL      same, read as a fallback
 *
 * A `.env` in the repo root is loaded if it exists (Node's `process.loadEnvFile()`), which is the
 * convention the repo's `.gitignore` already supports via `!.env.example`. `.env` itself is ignored,
 * so a developer's connection string never reaches a commit and `.env.example` carries the name.
 *
 * `npm run verify` runs this step, so **verify requires SUPABASE_DB_URL**. That is deliberate rather
 * than an oversight: the alternative is a `verify` that reports green while having skipped the only
 * check that reads the live database, which is the exact failure mode this script exists to prevent.
 * Exit 2 says "unchecked" and is distinct from exit 0 "clean".
 *
 * The direct connection (port 5432) is IPv6-only on Supabase. If the network is IPv4, use the pooler
 * host on port 6543 — same string, different host and port, and `pg` needs `ssl: { rejectUnauthorized:
 * false }` for it, which this script sets unconditionally.
 */

import pg from "pg";

// Loaded from `.env` only when that file exists. `loadEnvFile` is Node 20.12+; the guard keeps the
// script working on anything older rather than throwing on a file that may legitimately be absent.
try {
  process.loadEnvFile();
} catch {
  // No `.env`, or a Node without `loadEnvFile`. Either way the variables below are simply unset,
  // and the script exits 2 with instructions rather than pretending it ran.
}

const URL = process.env.SUPABASE_DB_URL ?? process.env.DATABASE_URL ?? "";

if (URL === "") {
  console.error(
    [
    "check-policies: NOT CONFIGURED — exit 2, checks did not run.",
    "",
    "This script reads the live database and `npm run verify` runs it, so verify needs a",
    "Postgres connection string. Supply it in a root `.env` (gitignored) or the environment:",
    "",
    "  SUPABASE_DB_URL=postgres://... npm run check:policies",
    "",
    "It is deliberately NOT wired to pass when unconfigured. A policy check that cannot reach the",
    "database must not report green; exit 2 tells the difference between 'clean' and 'unchecked'.",
    "",
    "The SQL it would have run is in this file, inlines, and is safe to paste into the Supabase",
    "SQL editor or an MCP session if you would rather run it once by hand.",
    ].join("\n"),
  );
  process.exit(2);
}

const { Pool } = pg;
const pool = new Pool({
  connectionString: URL,
  ssl: { rejectUnauthorized: false },
  // The pooler does not support prepared statements in transaction mode, and a session-scoped
  // statement timeout is the more useful guard here anyway: a policy scan that hangs is a bug in
  // the scan, not a reason to hang a CI job.
  statement_timeout: 30_000,
});

const failures = [];
const passes = [];

function report(title, rows, describe) {
  if (rows.length === 0) {
    passes.push(`${title}: 0 violations.`);
    return;
  }
  failures.push(`${title}: ${rows.length} violation(s).`);
  for (const row of rows) {
    console.error(`  FAIL  ${describe(row)}`);
  }
}

try {
  // ---------------------------------------------------------------------------
  // 1. A bare auth.uid() in a policy.
  //
  // The rule, in one sentence: `auth.uid()` must be immediately preceded by `select`, because that
  // makes it a scalar subquery the planner caches as an InitPlan. The bare form is STABLE, evaluated
  // once per row — which compares one user's id against every row on every scan.
  //
  // The alias, the spacing and the nesting are irrelevant to that question, so the pattern ignores
  // them. `( SELECT auth.uid() AS uid)`, `(select auth.uid())` and
  // `private.vendor_ids_for(( SELECT auth.uid() AS uid))` all pass; `user_id = auth.uid()` fails.
  // ---------------------------------------------------------------------------
  const bareUid = await pool.query(`
    select tablename, policyname
      from pg_policies
     where schemaname = 'public'
       and (
         (coalesce(qual, '')        ~* 'auth\\.uid\\(\\)' and coalesce(qual, '')        !~* 'select\\s+auth\\.uid\\(\\)')
      or (coalesce(with_check, '') ~* 'auth\\.uid\\(\\)' and coalesce(with_check, '') !~* 'select\\s+auth\\.uid\\(\\)')
       )
     order by tablename, policyname
  `);
  report("bare auth.uid() in a policy", bareUid.rows, (r) => `public.${r.tablename} policy "${r.policyname}"`);

  // ---------------------------------------------------------------------------
  // 2. An unpinned search_path on a security definer function.
  //
  // `search_path = ''` is the strongest form and the only one that passes: every object is then
  // schema-qualified inside the body, so nothing can be shadowed. `search_path = public` FAILS,
  // because `public` is attacker-writable here — an unprivileged user can create objects in it and
  // have a definer function resolve to the wrong one. A MISSING proconfig entry also fails: the
  // default search_path is then in play.
  // ---------------------------------------------------------------------------
  const unpinned = await pool.query(`
    select n.nspname as schema, p.proname,
           coalesce(array_to_string(p.proconfig, ', '), '(no proconfig)') as config
      from pg_proc p
      join pg_namespace n on n.oid = p.pronamespace
     where p.prosecdef
       and n.nspname in ('public', 'private')
       and coalesce(array_to_string(p.proconfig, ', '), '') !~ 'search_path\\s*=\\s*""'
     order by n.nspname, p.proname
  `);
  report(
    "security definer function without search_path = \"\"",
    unpinned.rows,
    (r) => `${r.schema}.${r.proname}  [${r.config}]`,
  );

  // ---------------------------------------------------------------------------
  // 3. An unindexed foreign key.
  //
  // Postgres does not index a referencing column. Without one, every JOIN through the FK is a
  // sequential scan, and every ON DELETE on the parent is a full scan of the CHILD — which matters
  // here because all three offenders are `ON DELETE SET NULL` and two of them point at
  // `menu_item_sizes`. `order_items` is the largest table in the schema and is never pruned, so
  // deleting one size row forces a seq scan over every order line ever written.
  //
  // The column has to appear anywhere in the index (`attnum = any(indkey)`), not just lead it: a
  // composite index with the FK second still serves the constraint check.
  // ---------------------------------------------------------------------------
  const unindexedFk = await pool.query(`
    select c.conrelid::regclass as table_name,
           a.attname as fk_column,
           c.conname,
           c.confrelid::regclass as references,
           case c.confdeltype
             when 'c' then 'CASCADE'
             when 'n' then 'SET NULL'
             when 'r' then 'RESTRICT'
             else 'NO ACTION'
           end as on_delete
      from pg_constraint c
      join pg_attribute a on a.attrelid = c.conrelid and a.attnum = any(c.conkey)
     where c.contype = 'f'
       and c.connamespace = 'public'::regnamespace
       and not exists (
             select 1 from pg_index i
              where i.indrelid = c.conrelid
                and a.attnum = any(i.indkey)
           )
     order by 1, 2
  `);
  report(
    "unindexed foreign key",
    unindexedFk.rows,
    (r) => `${r.table_name}.${r.fk_column} -> ${r.references} ON DELETE ${r.on_delete}  [${r.conname}]`,
  );
} catch (error) {
  const message = error instanceof Error ? error.message : String(error);
  console.error(`check-policies: could not query the database — exit 2 (not a pass).\n  ${message}`);
  console.error(
    "\n  A refused connection is a network or credential problem, not a policy verdict. The checks",
    "\ndid not run, so nothing here says the schema is clean."
  );
  await pool.end().catch(() => {});
  process.exit(2);
}

await pool.end();

for (const line of passes) {
  console.log(`ok    ${line}`);
}

if (failures.length > 0) {
  console.error(`\ncheck-policies FAILED: ${failures.length} of 3 rule(s) violated.`);
  console.error(
    "\n  Fix in a migration. Do not weaken the check to make it pass: data-model.md §13.2 and",
    "\n§14.2 are the rules and this script only reports them."
  );
  process.exit(1);
}

console.log(`\ncheck-policies OK: all 3 rule(s) pass against ${new URL(URL).host}.`);
