/**
 * Boundary enforcement for apps/mobile.
 *
 * The rules below are the architecture in apps/mobile/README.md, made executable.
 * A violation is a build failure, not a review comment — that is what keeps the
 * feature slices from collapsing back into god files.
 *
 * Run: npx depcruise src app --config .dependency-cruiser.cjs
 */

/** @type {import('dependency-cruiser').IConfiguration} */
module.exports = {
  forbidden: [
    /* ── 1. no circular dependencies anywhere ─────────────────────── */
    {
      name: 'no-circular',
      severity: 'error',
      comment: 'A cycle means a slice has no owner. Break it with a barrel or a shared module.',
      from: {},
      to: { circular: true },
    },

    /* ── 2. features never import each other by path ──────────────── */
    {
      name: 'feature-to-feature',
      severity: 'error',
      comment:
        'Feature A must never reach into feature B. Import from another feature\'s barrel, ' +
        'or move the shared part to src/ first.',
      from: { path: '^src/features/([^/]+)/' },
      to: {
        path: '^src/features/([^/]+)/',
        pathNot: [
          // a slice may import itself
          '^src/features/\\1/',
        ],
      },
    },

    /* ── 3. only a route file may reach into a feature's internals ── */
    {
      name: 'no-deep-feature-import-from-outside',
      severity: 'error',
      comment: 'Import from the feature barrel: "@/features/<name>". Deep paths are private.',
      from: {
        pathNot: ['^app/', '^src/features/\\1/', '^src/features/[^/]+/(__tests__|screens)/'],
      },
      to: {
        path: '^src/features/[^/]+/(screens|components|sheets|hooks|api|mappers)/',
      },
    },

    /* ── 4. lib/ is pure ──────────────────────────────────────────── */
    {
      name: 'lib-is-pure',
      severity: 'error',
      comment:
        'src/lib/ must stay free of react and react-native so money, geo and schedule ' +
        'maths stay unit-testable without a renderer.',
      from: { path: '^src/lib/' },
      to: { path: '^(react|react-native|expo(-[a-z-]+)?)(/|$)' },
    },

    /* ── 5. theme and types import nothing ────────────────────────── */
    {
      name: 'leaf-modules',
      severity: 'error',
      comment: 'src/theme/ and src/types/ are leaves. Anything they import is a dependency of everything.',
      from: { path: '^(src/theme|src/types)/' },
      to: { path: '^src/' },
    },

    /* ── 6. services is the only network boundary ─────────────────── */
    {
      name: 'no-supabase-outside-services',
      severity: 'error',
      comment: 'No feature or component touches supabase, R2 or a device API directly.',
      from: { pathNot: ['^src/services/'] },
      to: {
        path: '^(@supabase/supabase-js|expo-file-system|expo-notifications|expo-location|expo-camera)(/|$)',
      },
    },

    /* ── 7. shared layers never reach back into features ──────────── */
    {
      name: 'shared-never-imports-features',
      severity: 'error',
      comment: 'components/, hooks/, lib/, stores/ are shared. Depending on a feature inverts the graph.',
      from: { path: '^src/(components|hooks|lib|stores|theme|types)/' },
      to: { path: '^src/features/' },
    },

    /* ── 8. no orphan files ───────────────────────────────────────── */
    {
      name: 'no-orphans',
      severity: 'warn',
      comment: 'An orphan is dead code by definition (repo rule 10). Delete it or wire it in.',
      from: {
        orphan: true,
        pathNot: [
          '\\.d\\.ts$',
          '^src/index\\.(ts|tsx)$',
          '(^|/)index\\.(ts|tsx)$',
          '\\.config\\.(js|cjs|mjs|ts)$',
        ],
      },
      to: {},
    },
  ],

  options: {
    doNotFollow: { path: 'node_modules' },
    includeOnly: '^(app|src)',
    tsPreCompilationDeps: true,
    tsConfig: { fileName: 'tsconfig.json' },
    enhancedResolveOptions: {
      exportsFields: ['exports'],
      conditionNames: ['import', 'require', 'default', 'react-native'],
      extensions: ['.js', '.jsx', '.ts', '.tsx', '.json'],
    },
    reporterOptions: {
      text: { highlightFocused: true },
    },
  },
};
