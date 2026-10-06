/**
 * `components/PageSkeleton` - the loading state.
 *
 * ## Why a skeleton and not a spinner
 *
 * `admin-console-screens.md` §5 rule 5 requires a designed loading state on every screen, and the difference
 * is what the operator learns from it. A spinner says "something is happening". A skeleton at the shape of
 * the page says "this is what you are about to get" - the difference between an operator waiting and an
 * operator going to get coffee.
 *
 * ## Why the layout is in CSS and not in a `style` prop
 *
 * `AGENTS.md` rule 2. The grid and the gap are `metric-grid` and `metric-card` from `global.css`, whose
 * values are `var(--space-*)` references to tokens. This file contains no literal spacing and no colour,
 * which is checkable by grepping it for `px` and `#`.
 */

import { Skeleton } from "antd";
import type { ReactElement } from "react";
import { useTranslation } from "react-i18next";

/** Placeholder count. Enough to fill a laptop viewport, few enough to leave the fold on a tablet. */
const CARD_COUNT = 4;

export function PageSkeleton(): ReactElement {
  const { t } = useTranslation();

  return (
    <div aria-busy="true">
      {/* A visually hidden string, not an empty `aria-live`: an empty live region announces nothing, and a
          screen-reader user would otherwise be left in silence while the page loads. */}
      <span className="visually-hidden">{t("app.loading")}</span>
      <Skeleton active title paragraph={{ rows: 1 }} />
      <div className="metric-grid">
        {Array.from({ length: CARD_COUNT }, (_unused, index) => (
          <div className="metric-card" key={index}>
            <Skeleton active title={{ width: "45%" }} paragraph={{ rows: 2 }} />
          </div>
        ))}
      </div>
    </div>
  );
}