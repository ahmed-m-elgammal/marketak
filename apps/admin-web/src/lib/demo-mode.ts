/**
 * `lib/demo-mode` - the switch, isolated in its own module.
 *
 * ## Why it is its own file
 *
 * Because of how Vite works. `import.meta.env.VITE_DEMO` is **replaced with a literal at build time**, so the
 * condition in this file becomes `false` in a bundle built without the variable set - the variable name does
 * not survive into `dist/`. That is what makes `scripts/check-no-demo-in-build.mjs` a real gate rather than a
 * promise: it greps the built output for `VITE_DEMO`, and a production bundle that still contains the string
 * means someone wired the flag to something Vite could not inline, which is exactly the case where it would
 * silently be on in production.
 *
 * Keeping the check in one module rather than inline at each call site means there is one place to grep and
 * one place to delete when fixtures are retired.
 */

/** The env var that turns fixtures on. `"1"` and nothing else. */
export const DEMO_ENV_KEY = "VITE_DEMO";

/**
 * True only when the flag is exactly `"1"`.
 *
 * Not `import.meta.env.DEV` and not "any truthy value". `DEV` is true in every local build including the ones
 * a reviewer runs against a real project, which would silently feed them sample numbers while they believed
 * they were looking at the database. An explicit opt-in is one extra step and removes that whole class of
 * confusion.
 *
 * ## Why the key is a literal and not `import.meta.env[DEMO_ENV_KEY]`
 *
 * Because Vite replaces `import.meta.env.VITE_DEMO` with a literal at build time, and it can only do that for a
 * **syntactically literal** key. The computed form compiled happily, shipped the string `VITE_DEMO` into the
 * bundle, and left the flag live at runtime - which `scripts/check-no-demo-in-build.mjs` caught on its first run.
 *
 * `DEMO_ENV_KEY` is therefore a constant for tests and tooling to assert against, and never the thing read here.
 */
export function isDemoMode(): boolean {
  return import.meta.env.VITE_DEMO === "1";
}