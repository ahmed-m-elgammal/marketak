/// <reference types="node" />

/**
 * `.dependency-cruiser.cjs` - architecture rules 2 and 3, mechanically.
 *
 * Architecture rule 2: customer and rider code never import each other. Code used
 * by both lives in a shared zone that imports from neither.
 *
 * Architecture rule 3: exactly one module calls Supabase. No screen or component
 * calls `supabase.rpc` directly.
 *
 * Both are import statements, so both are lintable. `eslint.config.js` covers
 * them with `no-restricted-imports` on the happy path; this file covers them on
 * the path ESLint does not reach - a re-export that launders a forbidden import
 * through an `index.ts`, which is exactly the trick a feature-folder boundary is
 * supposed to prevent.
 *
 * Run: `npm run deps:check` from `apps/mobile`.
 *
 * This file is a Node module that belongs to no tsconfig, which is why it is in
 * the `disableTypeChecked` block of the root eslint config.
 */

const path = require("node:path");

/** The two role zones. */
const CUSTOMER = path.join("src", "features", "customer");
const RIDER = path.join("src", "features", "rider");
const SHARED = path.join("src", "features", "shared");

/** The one data layer. */
const RPC = path.join("src", "services", "rpc");
const SUPABASE = path.join("src", "services", "supabase");

module.exports = {
  forbidden: [
    /* ── rule 2: role zones never cross ─────────────────────────────────── */
    {
      name: "no-customer-to-rider",
      comment:
        "Customer code may not import rider code. Shared code lives in features/shared and imports from neither zone.",
      severity: "error",
      from: { path: CUSTOMER },
      to: { path: RIDER, reachable: true },
    },
    {
      name: "no-rider-to-customer",
      comment:
        "Rider code may not import customer code. Shared code lives in features/shared and imports from neither zone.",
      severity: "error",
      from: { path: RIDER },
      to: { path: CUSTOMER, reachable: true },
    },
    {
      name: "shared-imports-neither-zone",
      comment:
        "The shared feature zone must import from neither role zone. If both roles need it, it is shared; if one does, it belongs to that role.",
      severity: "error",
      from: { path: SHARED },
      to: { path: [CUSTOMER, RIDER], reachable: true },
    },

    /* ── rule 3: one data layer ─────────────────────────────────────────── */
    {
      name: "no-supabase-outside-the-client",
      comment:
        "The Supabase client is created once, in services/supabase/client.ts. Nothing else may import it.",
      severity: "error",
      from: {
        path: "^src",
        pathNot: [SUPABASE, RPC],
      },
      to: { path: SUPABASE, reachable: true },
    },
    {
      name: "no-rpc-call-outside-the-wrapper",
      comment:
        "`supabase.rpc` is called only in services/rpc/call.ts. A feature calls the typed wrapper in services/rpc/api.ts.",
      severity: "error",
      from: {
        path: "^src",
        pathNot: [RPC, SUPABASE],
      },
      to: { path: RPC, reachable: true },
    },

    /* ── rule 11: no second implementation of a shared concern ──────────── */
    {
      name: "no-second-money-module",
      comment:
        "Money formatting lives in @marketak/shared. A lib/money.ts in the app is how one screen shows 29.50 and another shows ٢٩٫٥٠.",
      severity: "error",
      from: {},
      to: { path: "^(src|app)/(lib|utils)/(money|currency|price)" },
    },
    {
      name: "no-second-error-parser",
      comment:
        "One error parser, in services/errors. A second one is how the same failure is retried in one flow and shown in another.",
      severity: "error",
      from: {
        path: "^src",
        pathNot: [path.join("src", "services", "errors")],
      },
      to: { path: "^(src|app)/.*(app-error|parse-error|errors/index)" },
    },

    /* ── rule 1: no orphan modules ──────────────────────────────────────── */
    {
      name: "no-orphans",
      comment:
        "Nothing in src/ is unreachable. A folder with no importer is a placeholder slot, and a placeholder slot misleads the next reader. `.gitkeep` is exempt because a scheduled slot is allowed to exist empty.",
      severity: "error",
      from: { orphan: true, pathNot: ["\\.gitkeep$", "\\.d\\.ts$", "^(app)/"] },
      to: {},
    },

    /* ── rule 5: server data never enters a local store ─────────────────── */
    {
      name: "no-server-tables-in-a-store",
      comment:
        "The server owns carts, orders, addresses and menus. A zustand/redux store holding them is a second source of truth that drifts. Local state holds UI concerns only.",
      severity: "warn",
      from: {},
      to: { path: "^(src/state|src/store)" },
    },
  ],

  options: {
    doNotFollow: { path: "node_modules" },
    includeOnly: ["^(src|app)"],
    tsConfig: { fileName: "tsconfig.json" },
    tsPreCompilationDeps: true,
    enhancedResolveOptions: {
      exports: true,
      conditionNames: ["import", "require", "default", "react-native"],
      extensions: [".ts", ".tsx", ".js", ".jsx", ".json", ".svg"],
    },
    reporterOptions: {
      text: { highlightFocused: true },
    },
  },
};
