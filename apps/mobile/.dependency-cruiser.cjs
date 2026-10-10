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
 * Paths are forward-slash literals, never `path.join` constants: `path.join`
 * compiles to backslash regexes that never match forward-slash cruised paths,
 * which left five rules inert on Windows (F-02 evidence, tasks.mf Q8).
 *
 * Run: `npm run deps:check` from `apps/mobile`.
 *
 * This file is a Node module that belongs to no tsconfig, which is why it is in
 * the `disableTypeChecked` block of the root eslint config.
 */

/** The two role zones. */
const CUSTOMER = "src/features/customer";
const RIDER = "src/features/rider";
const SHARED = "src/features/shared";

/** The one data layer. */
const RPC = "src/services/rpc";
const RPC_BARREL = "src/services/rpc/index.ts";
const SUPABASE = "src/services/supabase";
const SERVICES = "src/services";

/** The sanctioned UI store (mobile README §6): UI flags only, never server rows. */
const UI_STATE = "src/state/ui\\.ts$";

/** The one error layer. */
const ERRORS = "src/services/errors";

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
        "services/ is the only Supabase layer (R4): the client, Auth and direct table reads live there, and features/routes never import them. Direct-only by intent — reachability through the barrel (features → index → call → client) is the sanctioned chain, not a bypass, and flagging it would ban the architecture itself. Nothing re-exports the client, so no laundering path exists outside this rule plus the statement-level ESLint ban.",
      severity: "error",
      from: {
        path: "^(src|app)",
        pathNot: [SERVICES],
      },
      to: { path: SUPABASE },
    },
    {
      name: "rpc-entry-is-the-barrel-only",
      comment:
        "Features call the data layer through services/rpc/index.ts. A deep import (call.ts, schemas/) bypasses the barrel and the review that guards it. This replaces no-rpc-call-outside-the-wrapper, whose literal meaning banned the barrel itself — the one import mobile README §5 mandates.",
      severity: "error",
      from: {
        path: "^(src|app)",
        pathNot: [RPC, SUPABASE],
      },
      to: { path: RPC, pathNot: [RPC_BARREL] },
    },
    {
      name: "only-model-is-public",
      comment:
        "Within one role, feature-a may import feature-b/model. Never screens, widgets, or a barrel. $1 is the role, $2 is this feature's own name (mobile README §4).",
      severity: "error",
      from: { path: "src/features/(customer|rider)/([^/]+)/" },
      to: { path: "src/features/$1/(?:(?!$2/)[^/]+)/(screens|widgets|ui|index)" },
    },
    {
      name: "no-circular",
      comment:
        "Cross-feature model/ imports must not cycle back. A cycle between features is a layering violation with two authors.",
      severity: "error",
      from: {},
      to: { circular: true },
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
        pathNot: [ERRORS],
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
        "The server owns carts, orders, addresses and menus. A zustand/redux store holding them is a second source of truth that drifts. Local state holds UI concerns only. src/state/ui.ts is carved out: mobile README §6 mandates the sign-out reset and role-switch reads there — UI flags, never server rows (tasks.mf Q12).",
      severity: "warn",
      from: {},
      to: { path: "^(src/state|src/store)", pathNot: [UI_STATE] },
    },
  ],

  options: {
    doNotFollow: { path: "node_modules" },
    includeOnly: ["^(src|app)"],
    tsConfig: { fileName: "tsconfig.json" },
    tsPreCompilationDeps: true,
    enhancedResolveOptions: {
      exportsFields: ["exports"],
      conditionNames: ["import", "require", "default", "react-native"],
      extensions: [".ts", ".tsx", ".js", ".jsx", ".json", ".svg"],
    },
    reporterOptions: {
      text: { highlightFocused: true },
    },
  },
};
