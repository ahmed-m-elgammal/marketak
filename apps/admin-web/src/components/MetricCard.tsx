/**
 * `components/MetricCard` - one number with a label, and an optional delta line.
 *
 * ## Why it is not antd's `Statistic`
 *
 * `Statistic` renders its own padding, border and colour, all from the antd token set. The console's cards
 * need to match the surrounding card grid exactly, and the only way to guarantee that is to own the markup and
 * read `metric-card` from `global.css`. It also keeps the value in a `tabular-nums` span so a column of
 * amounts aligns on the decimal point.
 *
 * ## Why the hint is not optional in spirit
 *
 * `hint` exists for the case where a number is meaningless without a caveat — "in Africa/Cairo", "of 3 shops".
 * A bare figure on a dashboard is a claim, and the operator has no way to tell a claim from an accident.
 */

import type { ReactElement, ReactNode } from "react";

export interface MetricCardProps {
  readonly label: string;
  readonly value: ReactNode;
  /** The caveat that makes the number meaningful. Rendered small and grey beneath. */
  readonly hint?: string;
  /** Draws the card in the danger tone. Used only where a figure is a problem, never for decoration. */
  readonly tone?: "default" | "warning";
}

export function MetricCard({ label, value, hint, tone = "default" }: MetricCardProps): ReactElement {
  const valueClass =
    tone === "warning" ? "metric-card__value metric-card__value--warning" : "metric-card__value";

  return (
    <div className="metric-card">
      <span className="metric-card__label">{label}</span>
      <span className={valueClass}>{value}</span>
      {hint === undefined ? null : <span className="metric-card__hint">{hint}</span>}
    </div>
  );
}

/**
 * A row of cards.
 *
 * A grid rather than a row of flex children, so cards of differing content height still line up — the most
 * obvious visual failure on a metrics screen.
 */
export function MetricGrid({ children }: { readonly children: ReactNode }): ReactElement {
  return <div className="metric-grid">{children}</div>;
}