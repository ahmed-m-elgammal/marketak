/**
 * `components/StatusTag` - a status, as a word plus a colour.
 *
 * ## The rule this component exists to enforce
 *
 * `admin-console-screens.md` §5 rule 10: **status is never colour alone.** A colour-blind operator, an
 * operator on a washed-out screen, or an operator printing the page to PDF must all be able to read the
 * state. So the label is mandatory and the colour is the reinforcement.
 *
 * That is why `label` has no default and `tone` is a closed union: "a sixth tone I invented" is a compile
 * error rather than an unstyled pill.
 *
 * ## Why the colour is a class and not a prop
 *
 * antd's `Tag` accepts a `color` string, so a caller could pass a raw hex here and smuggle a hardcoded
 * colour past `AGENTS.md` rule 2. The colours are applied by `status-tag--<tone>` from `global.css`, whose
 * values are `var(--color-status-*)` references. There is no prop through which a literal could arrive.
 */

import { Tag } from "antd";
import type { ReactElement } from "react";

/**
 * The five semantic tones.
 *
 * Deliberately not one per status value. `cancelled` and `rejected` are both "this did not happen" and both
 * render `danger`; `delivered` and `paid` are both "this succeeded". A tone per status value would be
 * fifteen colours, and the operator would have to learn fifteen instead of five.
 */
export type Tone = "success" | "warning" | "danger" | "info" | "neutral";

export interface StatusTagProps {
  /** The word. Required - see the note above. */
  readonly label: string;
  readonly tone: Tone;
}

export function StatusTag({ label, tone }: StatusTagProps): ReactElement {
  return <Tag className={`status-tag status-tag--${tone}`}>{label}</Tag>;
}