/**
 * Wrapper inventory (F-06 output, DESIGN §9).
 *
 * Every reusable wrapper a screen may use, mapped to exactly one source:
 * the Tamagui kit component it styles (`tamagui/root-export` names,
 * verified against the installed `tamagui@2.7.7` types), a hand-built
 * primitive where no kit provides one (`custom`, DESIGN §9.2/§9.9/§9.10),
 * or `expo-image` for cached photography (`expo-image`-backed, §9.7/§13.4).
 *
 * This is data, not components: the wrappers land with the screens that
 * first need them (a folder is created by the file that needs it), and this
 * table is what keeps two screens from building the same button twice.
 * The map (§10) is out of v1 scope and has no entry by intent.
 */
export type WrapperSource =
  | { readonly kind: "tamagui"; readonly component: string }
  | { readonly kind: "custom" }
  | { readonly kind: "expo-image" };

export interface WrapperEntry {
  readonly wrapper: string;
  /** DESIGN subsection the wrapper implements, e.g. "9.2". */
  readonly designRef: string;
  readonly source: WrapperSource;
  readonly notes?: string;
}

export const UI_INVENTORY: readonly WrapperEntry[] = [
  { wrapper: "primary-action", designRef: "9.1", source: { kind: "tamagui", component: "Button" } },
  { wrapper: "secondary-action", designRef: "9.1", source: { kind: "tamagui", component: "Button" } },
  { wrapper: "danger-action", designRef: "9.1", source: { kind: "tamagui", component: "Button" } },
  {
    wrapper: "emergency-control",
    designRef: "9.1",
    source: { kind: "custom" },
    notes: "Press-and-hold with linear fill progress; no kit provides it.",
  },
  {
    wrapper: "slide-rail",
    designRef: "9.2",
    source: { kind: "custom" },
    notes: "90% + 250ms commit, 160ms snap-back, handle-only touches, screen-reader button alternative.",
  },
  { wrapper: "status-badge", designRef: "9.3", source: { kind: "tamagui", component: "Text" } },
  {
    wrapper: "vertical-badge",
    designRef: "9.3",
    source: { kind: "tamagui", component: "Text" },
    notes: "24 visual height, 1px border in the text color, leading 20 glyph, label always present; hit area extends to 48 when tappable.",
  },
  { wrapper: "dispatch-row", designRef: "9.4", source: { kind: "tamagui", component: "ListItem" } },
  { wrapper: "manifest-row", designRef: "9.4", source: { kind: "tamagui", component: "ListItem" } },
  { wrapper: "checkbox", designRef: "9.5", source: { kind: "tamagui", component: "Checkbox" } },
  {
    wrapper: "radio",
    designRef: "9.5",
    source: { kind: "custom" },
    notes: "Chamfered top-trailing corner (§6.1) needs an SVG mask; the kit radio cannot take one.",
  },
  {
    wrapper: "switch",
    designRef: "9.5",
    source: { kind: "custom" },
    notes: "Rectangular track + square thumb + always-visible ON/OFF text; native Switch is banned (§15).",
  },
  { wrapper: "text-input", designRef: "9.6", source: { kind: "tamagui", component: "Input" } },
  {
    wrapper: "scanner-field",
    designRef: "9.6",
    source: { kind: "tamagui", component: "Input" },
    notes: "Input plus a 48 trailing scanner button; manual entry always present.",
  },
  { wrapper: "hud-card", designRef: "9.7", source: { kind: "tamagui", component: "Card" } },
  {
    wrapper: "product-card",
    designRef: "9.7",
    source: { kind: "tamagui", component: "Card" },
    notes: "Card chrome only; the photo slot is photo-image.",
  },
  {
    wrapper: "quantity-stepper",
    designRef: "9.7",
    source: { kind: "tamagui", component: "Button" },
    notes: "Two square buttons + mono count; long-press repeat lives in the widget.",
  },
  {
    wrapper: "photo-image",
    designRef: "9.7",
    source: { kind: "expo-image" },
    notes: "Menu/vendor photography: fixed 4:3 or 1:1 aspect, cached, skeleton while loading, glyph block when missing, unfiltered.",
  },
  {
    wrapper: "avatar-image",
    designRef: "9.7",
    source: { kind: "expo-image" },
    notes: "Square 48/32; initials in label-lg on fallback.",
  },
  {
    wrapper: "top-bar",
    designRef: "9.8",
    source: { kind: "tamagui", component: "Stacks" },
    notes: "56 bar, title text, leading 48 action; content respects the top inset.",
  },
  { wrapper: "tab-bar", designRef: "9.8", source: { kind: "tamagui", component: "Group" } },
  { wrapper: "nav-rail", designRef: "9.8", source: { kind: "tamagui", component: "Group" } },
  {
    wrapper: "bottom-sheet",
    designRef: "9.9",
    source: { kind: "tamagui", component: "Sheet" },
    notes: "Peek/45%/full snaps, no scrim, no spring.",
  },
  { wrapper: "dialog", designRef: "9.9", source: { kind: "tamagui", component: "Dialog" } },
  { wrapper: "toast", designRef: "9.9", source: { kind: "tamagui", component: "Toast" } },
  {
    wrapper: "banner",
    designRef: "9.9",
    source: { kind: "tamagui", component: "Stacks" },
    notes: "48 bar under the top bar: glyph + label + age; not dismissible while the condition persists.",
  },
  {
    wrapper: "square-loader",
    designRef: "9.9",
    source: { kind: "custom" },
    notes: "Three 8px squares, 160ms sequence; static LOADING text under reduced motion. Round spinners are banned.",
  },
  {
    wrapper: "skeleton",
    designRef: "9.9",
    source: { kind: "tamagui", component: "Stacks" },
    notes: "Raster-1 rectangles; optional 1200ms scanline, static under reduced motion.",
  },
  {
    wrapper: "empty-state",
    designRef: "9.9",
    source: { kind: "tamagui", component: "Stacks" },
    notes: "32 glyph, heading stating what is empty, muted next-step line, one action.",
  },
  {
    wrapper: "scanner-overlay",
    designRef: "9.10",
    source: { kind: "custom" },
    notes: "Corner-bracket reticle, scanline, torch toggle, manual entry; camera permission denied renders empty state + settings action.",
  },
  {
    wrapper: "signature-pad",
    designRef: "9.10",
    source: { kind: "custom" },
    notes: "160-min canvas, CLEAR/CONFIRM, white-bg/black-ink export for the record.",
  },
  {
    wrapper: "proof-photo",
    designRef: "9.10",
    source: { kind: "custom" },
    notes: "Square shutter, RETAKE/USE PHOTO, timestamp+coords metadata. The camera dependency lands with the first use (R-05).",
  },
  {
    wrapper: "message-block",
    designRef: "9.11",
    source: { kind: "tamagui", component: "Stacks" },
    notes: "Rectangular blocks, max 80% pane width; outgoing carries the 4px high-beam leading bar.",
  },
  {
    wrapper: "dispatch-alert",
    designRef: "9.11",
    source: { kind: "tamagui", component: "Dialog" },
    notes: "Full-screen takeover on compact; segmented amber countdown; expiry auto-declines with a record.",
  },
  {
    wrapper: "route-stepper",
    designRef: "9.12",
    source: { kind: "custom" },
    notes: "Square nodes carry the meaning (SVG); lines are decorative. Nodes are not tappable.",
  },
];
