/**
 * Bidi isolation (DESIGN section 13.5).
 *
 * Order IDs, pickup codes, coordinates and amounts embedded in RTL text are
 * wrapped in a left-to-right isolate (U+2066 LRI ... U+2069 PDI) so they never
 * reorder. The markers are backslash-u escapes, not literals: an invisible
 * literal in source is how an isolate goes missing in review.
 */
export const BIDI_OPEN = "\u2066";
export const BIDI_CLOSE = "\u2069";

export function isolateBidi(text: string): string {
  return BIDI_OPEN + text + BIDI_CLOSE;
}
