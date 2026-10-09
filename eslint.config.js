import js from "@eslint/js";
import tseslint from "typescript-eslint";

export default tseslint.config(
  {
    ignores: [
      "**/node_modules/**",
      "**/dist/**",
      "**/.wrangler/**",
      "**/coverage/**",
      // Secrets. These two filenames are gitignored precisely because they hold a
      // service-role key and a Firebase private key. Linting them would put their
      // contents in an editor cache and in any log the linter writes.
      "marketak-eg-firebase-adminsdk-fbsvc-c7293a9dfd.json",
      "supabase_keys",
      ".dev.vars",
    ],
  },
  js.configs.recommended,
  ...tseslint.configs.recommendedTypeChecked,

  // The root config files and the Node-only CI scripts belong to no tsconfig, so the typed presets above
  // cannot parse them. This block MUST come AFTER `recommendedTypeChecked`: in a flat config a later block
  // overrides an earlier one, so this is what actually disarms the project-aware parser for them.
  //
  // `parserOptions: { projectService: false }` is the part that matters. `disableTypeChecked` only switches
  // off the type-aware RULES; it leaves the project service switched on, which is what produces
  // "was not found by the project service" on a file with no tsconfig.
  {
    // Build-tool config files. `apps/admin-web/vite.config.ts` is here for the same reason as the others: it
    // is a Node module that happens to be TypeScript, it belongs to no application tsconfig the project
    // service could attach to, and the typed rules cannot run without type information it will never get.
    files: [
      "eslint.config.js",
      "vitest.config.ts",
      "scripts/**/*.mjs",
      "**/*.config.js",
      // `**/*.cjs` is not `**/*.config.js`. `apps/mobile/.dependency-cruiser.cjs` is a Node
      // module that belongs to no tsconfig, so the typed preset above cannot parse it — it
      // fails with "getParserServices ... was not found by the project service". It carries a
      // JSDoc `@type` annotation, which is what makes the TS parser pick it up in the first
      // place; without it ESLint would treat it as plain JS and skip the project service.
      "**/*.cjs",
      // Declaration files. `apps/mobile/types.d.ts` belongs to no tsconfig's source, so the typed
      // preset cannot attach parser services to it - same failure mode as the config files above.
      "**/*.d.ts",
      "apps/*/vite.config.ts",
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
        atob: "readonly",
        btoa: "readonly",
        // CommonJS module scope. `**/*.cjs` above pulls in `.cjs` files, which are CommonJS by
        // definition and cannot use `export` — so `module`, `require` and `__dirname` are real
        // bindings there, not undeclared globals. `eslint.config.js` does not need them (it is
        // ESM, `export default`), which is why declaring them here is harmless to it.
        module: "writable",
        require: "readonly",
        __dirname: "readonly",
        __filename: "readonly",
        exports: "writable",
      },
    },
    rules: {
      // `metro.config.js` and `babel.config.js` are Node CJS by convention — Expo generates and
      // reads them as `require()` modules. The rule is right for source and wrong here; turning
      // it off only in this block keeps it on everywhere it matters.
      "@typescript-eslint/no-require-imports": "off",
    },
  },

  {
    // The rules that matter, scoped to source. Scoping matters: without `files`, these would apply to
    // `eslint.config.js` too, and the type-aware ones would re-attach the parser this block exists to avoid.
    files: [
      "packages/*/src/**/*.ts",
      "functions/*/src/**/*.ts",
      // Expo Router routes live in `app/`, NOT `src/` - the app's own code is in `src/`. Both are
      // source, so both need the type-aware preset. Omitting `apps/*/app/**` is what produced
      // "don't have parserOptions set to generate type information for this file" on `app/index.tsx`.
      "apps/*/src/**/*.ts",
      "apps/*/src/**/*.tsx",
      "apps/*/app/**/*.ts",
      "apps/*/app/**/*.tsx",
    ],
    languageOptions: {
      // The project service is switched ON here and only here. The typed preset above turns the type-aware
      // rules on for every file, so source needs this to give those rules the type information they call
      // `getParserServices()` for. Config files are excluded by the block above and never reach it.
      parserOptions: {
        projectService: true,
        tsconfigRootDir: import.meta.dirname,
      },
    },
    rules: {
      // constitution rule 1, enforced. `any` is how money arithmetic silently becomes
      // string concatenation two releases later.
      "@typescript-eslint/no-explicit-any": "error",
      "@typescript-eslint/no-unsafe-assignment": "error",
      "@typescript-eslint/no-unsafe-member-access": "error",
      "@typescript-eslint/no-unsafe-call": "error",
      "@typescript-eslint/no-unsafe-return": "error",
      "@typescript-eslint/no-unsafe-argument": "error",

      // constitution rule 10. Dead code is deleted, not left as a disabled rule.
      "@typescript-eslint/no-unused-vars": [
        "error",
        { argsIgnorePattern: "^_", varsIgnorePattern: "^_" },
      ],

      // A `catch` that silently swallows is how a drain stops draining and nobody
      // notices until the backlog alarm has been red for a week.
      "no-empty": ["error", { allowEmptyCatch: false }],
      eqeqeq: ["error", "always", { null: "ignore" }],
      "no-console": "off",
    },
  },
  {
    // Tests are allowed to be less paranoid about `any` in fixtures, but not about
    // behaviour. Never relax `no-explicit-any` here - a fixture with `any` is how a
    // DTO loses a field without a compile error.
    files: ["**/*.test.ts", "**/*.test.tsx"],
    rules: {
      "@typescript-eslint/no-unsafe-assignment": "off",
      "@typescript-eslint/no-unsafe-member-access": "off",
      "@typescript-eslint/no-unsafe-argument": "off",
    },
  },
);