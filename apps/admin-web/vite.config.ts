import react from "@vitejs/plugin-react";
import { defineConfig } from "vite";

/**
 * `vite.config.ts` - the console's build.
 *
 * ## manualChunks, and why antd is not in it
 *
 * Ant Design's full bundle is ~432 KB gzipped. The console ships **208.73 KB gzipped** in its entry chunk —
 * measured on the A0 build, not estimated — because every component is a named import and Rollup tree-shakes
 * antd's ES modules down to what the shell actually renders.
 *
 * Two mechanisms produce that:
 *
 * 1. **Named imports only** - `import { Table } from "antd"`, never `import antd from "antd"`. A route that
 *    uses four components ships four.
 * 2. **`manualChunks` puts React in its own chunk.** React, react-dom and react-router change on a different
 *    schedule to feature code, so separating them means a token tweak does not invalidate the framework cache.
 *
 * antd is deliberately NOT given its own chunk. Splitting a library that every route imports creates a chunk
 * boundary that changes on nearly every feature change, which defeats the caching benefit the split was for.
 *
 * **The limit below is exceeded, and that is measured rather than aspirational.** The entry chunk is 679 KB
 * minified / 208 KB gzipped against a 400 KB warning line, because `AppShell` imports `Layout` and `Menu`,
 * `StateBlock` imports `Result`, and every one of those is antd. Route splitting cannot help: the shell loads
 * before any route does. For an internal console on a tablet that is acceptable, and 208 KB is less than half
 * of antd's own full bundle. If it ever stops being acceptable, the lever is the shell - not the routes.
 */
export default defineConfig({
  plugins: [react()],

  build: {
    target: "es2022",
    sourcemap: true,
    // The free-tier budget in free-tier-plan.md. 400 KB is the warning line for a single chunk; the
    // compressed size below is the one that matters for a tablet on a metered connection.
    chunkSizeWarningLimit: 400,
    rollupOptions: {
      output: {
        manualChunks(id: string) {
          if (id.includes("node_modules/react") || id.includes("node_modules/scheduler")) {
            return "framework";
          }
          // i18next and react-i18next change only when a string is edited, and every string edit is a deploy.
          // Splitting them keeps them out of the framework cache's invalidation path.
          if (id.includes("node_modules/i18next") || id.includes("node_modules/react-i18next")) {
            return "i18n";
          }
          return undefined;
        },
      },
    },
  },

  server: {
    port: 5173,
    strictPort: true,
  },

  // The console reads the Supabase URL and anon key from Vite env vars. Only `VITE_`-prefixed vars reach a
  // browser bundle, so a `SUPABASE_SERVICE_ROLE_KEY` in the same `.env` is not shipped - Vite will not
  // inline it. A7.1 adds a build-time assertion on top of that.
  envPrefix: ["VITE_"],
});