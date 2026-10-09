import js from "@eslint/js";
import tseslint from "typescript-eslint";

export default tseslint.config(
  {
    ignores: [
      "**/node_modules/**",
      "**/dist/**",
      "**/.wrangler/**",
      "**/coverage/**",
      // Expo build output. Never source, never committed, and the linter has no
      // business reading generated bundles.
      "**/.expo/**",
      "**/expo-env.d.ts",
      // Secrets. `supabase_keys` holds a service-role key that bypasses RLS on
      // every table, and the Firebase file holds a private key. Both are gitignored
      // for the same reason: NEVER `git add -f` either one.
      "marketak-eg-firebase-adminsdk-fbsvc-c7293a9dfd.json",
      "supabase_keys",
      ".dev.vars",
      ".dev.vars.*",
      "client_secret_*.json",
    ],
  },
  js.configs.recommended,
  ...tseslint.configs.recommendedTypeChecked,

  // ── Config files and Node-only CI scripts ─────────────────────────────────
  // These belong to no tsconfig, so the typed presets above cannot parse them.
  // This block MUST come after `recommendedTypeChecked`: in a flat config a later
  // block overrides an earlier one, and `projectService: false` is what actually
  // disarms the project-aware parser. `disableTypeChecked` alone leaves the
  // service on and you get "was not found by the project service".
  {
    files: [
      "eslint.config.js",
      "vitest.config.ts",
      "scripts/**/*.mjs",
      "**/*.config.js",
      "**/*.config.cjs",
      "**/*.cjs",
      "**/*.d.ts",
      ".dependency-cruiser.cjs",
    ],
    extends: [tseslint.configs.disableTypeChecked],
    languageOptions: {
      parserOptions: {
        project: false,
        projectService: false,
      },
      ecmaVersion: 2023,
      sourceType: "module",
      globals: {
        console: "readonly",
        process: "readonly",
        module: "writable",
        require: "readonly",
        __dirname: "readonly",
        __filename: "readonly",
        exports: "writable",
      },
    },
    rules: {
      "@typescript-eslint/no-require-imports": "off",
    },
  },

  // ── Source ────────────────────────────────────────────────────────────────
  {
    files: [
      "packages/*/src/**/*.ts",
      "apps/*/src/**/*.ts",
      "apps/*/src/**/*.tsx",
      "apps/*/app/**/*.ts",
      "apps/*/app/**/*.tsx",
      "functions/*/src/**/*.ts",
    ],
    languageOptions: {
      // `projectService` as an object, not `true`: the `allowDefaultProject` list is
      // what lets a test file be parsed when no tsconfig includes it.
      //
      // Test files are deliberately excluded from every tsconfig so that `tsc -b`
      // never emits them into `dist` - a test in a published bundle is dead weight
      // that still gets type-checked by every consumer. The cost is that the project
      // service cannot find them, and without this list every test file fails to
      // parse, which silently stops linting the one kind of file that asserts
      // behaviour.
      parserOptions: {
        // The globs must not begin with `**`: typescript-eslint rejects that as too
        // wide, because a bare `**/*.test.ts` would put every file in the repo on
        // the default project and quietly slow every lint run down. One concrete
        // segment is the point - it names exactly the trees that hold tests.
        //
        // Test files are deliberately excluded from every tsconfig so that
        // `tsc -b` never emits them into `dist`. The cost is that the project
        // service cannot find them, and without this list every test file fails to
        // parse, which silently stops linting the one kind of file that asserts
        // behaviour.
        projectService: {
          allowDefaultProject: [
            "packages/*/src/*.test.ts",
            "packages/*/src/*.test.tsx",
            "apps/*/src/*.test.ts",
            "apps/*/src/*.test.tsx",
            "functions/*/src/tests/*.test.ts",
          ],
          // Every test file resolves against `tsconfig.test.json`, which includes
          // all of them and nothing else, and carries the union of the libs the
          // three runtimes need. Pointing this at the root solution file instead
          // leaves `Request` and `fetch` unresolved, which is how a whole test
          // directory ends up reporting 'could not be resolved' on every call.
          defaultProject: "./tsconfig.test.json",
        },
        tsconfigRootDir: import.meta.dirname,
      },
    },
    rules: {
      // Constitution rule 1. `any` is how money arithmetic silently becomes
      // string concatenation two releases later. The unsafe-* family is the
      // same rule seen from the other side: an `any` that nobody wrote down.
      "@typescript-eslint/no-explicit-any": "error",
      "@typescript-eslint/no-unsafe-assignment": "error",
      "@typescript-eslint/no-unsafe-member-access": "error",
      "@typescript-eslint/no-unsafe-call": "error",
      "@typescript-eslint/no-unsafe-return": "error",
      "@typescript-eslint/no-unsafe-argument": "error",

      // Constitution rule 10. Dead code is deleted, not left as a disabled rule.
      "@typescript-eslint/no-unused-vars": [
        "error",
        { argsIgnorePattern: "^_", varsIgnorePattern: "^_" },
      ],

      // A `catch` that silently swallows is how a drain stops draining and nobody
      // notices until the backlog alarm has been red for a week.
      "no-empty": ["error", { allowEmptyCatch: false }],
      eqeqeq: ["error", "always", { null: "ignore" }],
      "no-console": "off",

      // Architecture rule 8: `start`/`end`, not `left`/`right`. React Native maps
      // start/end onto the reading direction, so a `left` is a bug waiting for the
      // first LTR screenshot to be taken in an RTL app.
      "no-restricted-properties": [
        "error",
        {
          object: "StyleSheet",
          property: "flatten",
          message:
            "StyleSheet.flatten loses the start/end distinction when it merges. Not used; compose tokens instead.",
        },
      ],
      "no-restricted-syntax": [
        "error",
        {
          selector:
            "Property[key.name='left'], Property[key.name='right'], Property[key.name='marginLeft'], Property[key.name='marginRight'], Property[key.name='paddingLeft'], Property[key.name='paddingRight']",
          message:
            "Use start/end (marginStart, marginEnd, insetInlineStart…) so RTL works. `left`/`right` is architecture rule 8.",
        },
        {
          selector:
            "Property[key.name='marginHorizontal'], Property[key.name='paddingHorizontal']",
          message:
            "marginHorizontal/paddingHorizontal is direction-agnostic and safe. Prefer start/end only when one side differs.",
        },
      ],
    },
  },

  // ── Tests ─────────────────────────────────────────────────────────────────
  // Tests may be looser about `any` in fixtures, never about behaviour.
  {
    files: ["**/*.test.ts", "**/*.test.tsx", "**/tests/**/*.ts"],
    rules: {
      "@typescript-eslint/no-unsafe-assignment": "off",
      "@typescript-eslint/no-unsafe-member-access": "off",
      "@typescript-eslint/no-unsafe-argument": "off",
    },
  },

  // ── Architecture rules 2 and 3, mechanically ──────────────────────────────
  // Rule 2: customer and rider never import each other. Shared code lives in
  // features/shared and imports from neither zone.
  // Rule 3: exactly one module calls Supabase - services/supabase/client.ts
  // creates it, services/rpc/call.ts is the only caller of `supabase.rpc`.
  //
  // Both are enforced twice on purpose. This block catches a forbidden import at
  // the statement; `apps/mobile/.dependency-cruiser.cjs` catches one laundered
  // through a re-export in an `index.ts`, which is exactly the trick a
  // feature-folder boundary is supposed to stop. ESLint's native
  // `no-restricted-imports` is used because a published
  // `eslint-plugin-dependency-cruiser` is a 0.x package exposing no such rule.
  //
  // A rule that only lives in a reviewer's memory is a rule that decays.
  {
    files: ["apps/mobile/src/**/*.ts", "apps/mobile/src/**/*.tsx", "apps/mobile/app/**/*.tsx"],
    rules: {
      "no-restricted-imports": [
        "error",
        {
          patterns: [
            {
              group: ["**/features/customer/**", "!**/features/customer/index.ts"],
              message:
                "A rider or shared file may not import from features/customer. Shared code lives in features/shared and imports from neither zone (rule 2).",
            },
            {
              group: ["**/features/rider/**", "!**/features/rider/index.ts"],
              message:
                "A customer or shared file may not import from features/rider. Shared code lives in features/shared and imports from neither zone (rule 2).",
            },
            {
              group: ["@marketak/shared/**"],
              message:
                "Import from the package root ('@marketak/shared'). A deep path bypasses its public surface (rule 11).",
            },
            {
              group: ["**/services/rpc/call", "**/services/rpc/dto"],
              message:
                "Call through services/rpc/api.ts. The call/dto modules are internals of the data layer (rule 3).",
            },
            {
              group: ["@supabase/supabase-js"],
              message:
                "The Supabase client is created once, in services/supabase/client.ts. Nothing else may import it (rule 3).",
            },
          ],
        },
      ],
    },
  },
);
