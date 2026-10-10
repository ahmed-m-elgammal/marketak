/**
 * Tailwind config for NativeWind v4 (Tailwind v3 engine).
 *
 * Mirror of `src/theme/tokens.ts` - the procedure in
 * `src/theme/design-rules.md` governs which file changes first. Values live
 * here so utilities can use them; the token module is canonical.
 *
 * `borderRadius` and `boxShadow` core plugins are OFF: the design system has
 * zero radius (§6) and zero-blur hard shadows (§5). A `rounded-*` or `shadow-*`
 * class is a defect - review catches it, the engine must not produce it.
 */
/** @type {import('tailwindcss').Config} */
module.exports = {
  content: ["./app/**/*.{js,jsx,ts,tsx}", "./src/**/*.{js,jsx,ts,tsx}"],
  presets: [require("nativewind/preset")],
  theme: {
    extend: {
      colors: {
        "cobalt-electric": "#1D4ED8",
        "cobalt-high-beam": "#3B82F6",
        "cobalt-recessed": "#172554",
        "telemetry-cyan": "#00F0FF",
        "dispatch-amber": "#F59E0B",
        "alert-crimson": "#EF4444",
        "success-radar": "#10B981",
        "vertical-food": "#F97316",
        "vertical-grocery": "#84CC16",
        "vertical-pharmacy": "#06B6D4",
        "vertical-parcel": "#94A3B8",
        white: "#FFFFFF",
        "void-base": "#020408",
        "surface-raster-0": "#080C14",
        "surface-raster-1": "#0F172A",
        "surface-raster-2": "#1E293B",
        "row-alt": "#0B0F19",
        "text-primary": "#DFE2F1",
        "text-muted": "#94A3B8",
        "text-placeholder": "#7C8AA0",
        "text-disabled": "#64748B",
        "wire-border-dim": "rgba(255, 255, 255, 0.08)",
        "wire-border-mid": "rgba(255, 255, 255, 0.16)",
        "wire-border-control": "rgba(255, 255, 255, 0.40)",
        "wire-border-active": "#3B82F6",
        "focus-ring": "#3B82F6",
        scrim: "rgba(2, 4, 8, 0.72)",
        "tint-success": "rgba(16, 185, 129, 0.12)",
        "tint-pharmacy": "rgba(6, 182, 212, 0.12)",
        "tint-food": "rgba(249, 115, 22, 0.12)",
        "tint-grocery": "rgba(132, 204, 22, 0.12)",
        "tint-parcel": "rgba(148, 163, 184, 0.12)",
        "tint-amber": "rgba(245, 158, 11, 0.12)",
        "tint-crimson": "rgba(239, 68, 68, 0.12)",
      },
      spacing: {
        xs: 4,
        sm: 8,
        md: 16,
        lg: 24,
        xl: 32,
        "2xl": 40,
        "3xl": 48,
      },
      fontFamily: {
        display: ["SpaceGrotesk", "system-ui", "sans-serif"],
        body: ["JetBrainsMono", "monospace"],
        mono: ["JetBrainsMono", "monospace"],
      },
    },
  },
  corePlugins: {
    borderRadius: false,
    boxShadow: false,
  },
  plugins: [],
};
