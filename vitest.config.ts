import { defineConfig } from "vitest/config";

/**
 * Vitest runs against Node, not workerd.
 *
 * The code under test is pure TypeScript with three injected boundaries - `fetch`, `Date.now` and the two
 * dependency objects - so it runs identically in both runtimes. `crypto.subtle` and `btoa`/`atob` exist in
 * Node 22, which is why the JWT tests sign for real rather than stubbing the signature.
 *
 * `src/tests/` is one directory, matched by a single glob, so "where are the tests" is answered by one
 * path and a new test file cannot end up outside the suite by accident.
 */
export default defineConfig({
  test: {
    include: [
      "packages/*/src/tests/**/*.test.ts",
      "functions/*/src/tests/**/*.test.ts",
      // The console has two kinds of test. Pure-logic ones - tokens, formatters, the error catalogue, the
      // route table - run in node exactly like the others. Component tests need a DOM and are added when
      // A2 brings the first renderable screen with behaviour worth asserting.
      "apps/*/src/tests/**/*.test.{ts,tsx}",
    ],
    // Not "node" globally. The token and error tests need no DOM, but any future component test does, and
    // a global node environment would fail on `document` rather than on the behaviour under test.
    environment: "node",
    environmentMatchGlobs: [["apps/*/src/tests/**", "jsdom"]],
    globals: false,
    // A failing test must not be able to be hidden behind a retry.
    retry: 0,
    coverage: {
      provider: "v8",
      include: ["packages/*/src/**/*.ts", "functions/*/src/**/*.ts"],
      exclude: ["**/tests/**", "**/index.ts", "**/*.d.ts"],
      // Floors chosen to fail on a deleted test rather than on an uncovered branch. These are not targets
      // to hit; they are floors that catch a whole module quietly going untested.
      thresholds: {
        lines: 80,
        functions: 80,
        statements: 80,
        branches: 70,
      },
    },
  },
});