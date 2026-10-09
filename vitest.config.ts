import { defineConfig } from "vitest/config";

export default defineConfig({
  test: {
    // Every workspace test file is a unit test: money, status types, the quote
    // decoder, the error parser. There is no database in this repo's test run -
    // the database is verified by hand-run SQL, and `npm run verify` says so
    // rather than pretending a green suite covers it.
    environment: "node",
    include: ["packages/*/src/**/*.test.ts", "apps/*/src/**/*.test.ts", "apps/*/src/**/*.test.tsx"],
    exclude: ["**/node_modules/**", "**/dist/**", "**/.expo/**"],
    coverage: {
      provider: "v8",
      include: ["packages/shared/src/**/*.ts", "apps/mobile/src/services/**/*.ts"],
      // Money and the status vocabulary are the two modules where a silent
      // regression is a financial or a state-machine bug. They carry a floor.
      thresholds: {
        lines: 80,
        functions: 80,
        statements: 80,
        branches: 70,
      },
    },
  },
});
