/**
 * `features/dashboard/DashboardPage` - the first screen (A3).
 *
 * ## What is here now, and what is not
 *
 * This is the shell: the page frame, the three required states wired up, and the metric grid reading real
 * numbers from `get_admin_metrics_v1`. It is **not** finished. What is missing is named in
 * `admin-dashboard-plan.md` A3 and is not stubbed here - an unfinished metric is absent, not rendered as a
 * zero, because a zero on a dashboard is a claim and a placeholder is not.
 *
 * ## `variance_variance` is rendered, not filtered
 *
 * constitution I.10, and the RPC's own comment: `float_variance` is surfaced deliberately and never
 * filtered to zero. A dashboard that greys out an unexplained variance destroys the signal it exists to
 * raise. `VarianceAlert` shows even a zero variance, because "zero" and "not computed" must not look alike.
 */

import { Card, Col, Row, Statistic } from "antd";
import { useQuery } from "@tanstack/react-query";
import type { ReactElement } from "react";
import { useTranslation } from "react-i18next";

import { formatRateBps } from "@marketak/shared";

import { PageSkeleton } from "../../components/PageSkeleton.js";
import { EmptyState, ErrorState } from "../../components/StateBlock.js";
import { Money } from "../../components/Money.js";
import { toFriendlyError } from "../../lib/errors.js";
import { intlTagFor } from "../../i18n/index.js";
import { useLocale } from "../../i18n/use-locale.js";

export default function DashboardPage(): ReactElement {
  const { t } = useTranslation();
  const locale = useLocale();

  const metrics = useQuery({
    queryKey: ["admin-metrics"],
    queryFn: async () => {
      const { getAdminMetrics } = await import("../../lib/queries/metrics.js");
      return await getAdminMetrics();
    },
  });

  if (metrics.isPending) {
    return <PageSkeleton />;
  }

  if (metrics.isError) {
    return <ErrorState error={toFriendlyError(metrics.error)} onRetry={() => void metrics.refetch()} />;
  }

  const payload = metrics.data;

  if (payload === null) {
    return (
      <EmptyState
        title={t("empty.noResults")}
        hint={t("empty.noResultsHint")}
        action={{ label: t("app.retry"), onClick: () => void metrics.refetch() }}
      />
    );
  }

  const currency = payload.revenue.currency;
  const orders = payload.orders;
  const vendors = payload.vendors;

  return (
    <div className="page">
      <header className="page__header">
        <h1>{t("dashboard.title")}</h1>
      </header>

      {/* Named once, not restated per card. The operator should never have to guess which timezone a
          dashboard is in - `get_admin_metrics_v1` derives its day boundary from `cities.timezone`. */}
      <p className="metric-card__hint">{t("dashboard.timezoneNote", { timezone: payload.timezone })}</p>

      <section aria-label={t("nav.orders")}>
        <Row gutter={[16, 16]}>
          <Col xs={12} md={6}>
            <Metric label={t("dashboard.ordersPlaced")} value={orders.placed} />
          </Col>
          <Col xs={12} md={6}>
            <Metric label={t("dashboard.ordersDelivered")} value={orders.delivered} />
          </Col>
          <Col xs={12} md={6}>
            <Metric label={t("dashboard.ordersCancelled")} value={orders.cancelled} />
          </Col>
          <Col xs={12} md={6}>
            <Metric label={t("dashboard.ordersOpen")} value={orders.open} />
          </Col>
        </Row>
      </section>

      <section aria-label={t("nav.merchants")}>
        <Row gutter={[16, 16]}>
          <Col xs={12} md={6}>
            <Metric label={t("dashboard.vendorsActive")} value={vendors.active_approved} />
          </Col>
          <Col xs={12} md={6}>
            <Metric label={t("dashboard.vendorsOpen")} value={vendors.open_now} />
          </Col>
          <Col xs={12} md={6}>
            <Metric label={t("dashboard.vendorsPending")} value={vendors.pending_approval} />
          </Col>
          <Col xs={12} md={6}>
            <Metric label={t("dashboard.ridersOnline")} value={payload.riders.online_now} />
          </Col>
        </Row>
      </section>

      <Card title={t("variance.title")}>
        <Row gutter={[16, 16]}>
          <Col xs={12} md={8}>
            <Statistic
              title={t("variance.cashExpected")}
              valueRender={() => <Money amount={payload.revenue.cash_expected} currency={currency} />}
            />
          </Col>
          <Col xs={12} md={8}>
            <Statistic
              title={t("variance.cashRemitted")}
              valueRender={() => <Money amount={payload.revenue.cash_remitted} currency={currency} />}
            />
          </Col>
          <Col xs={12} md={8}>
            {/* constitution I.10. Rendered whatever it says, including zero. */}
            <Statistic
              title={t("variance.variance")}
              valueRender={() => (
                <Money amount={payload.revenue.float_variance} currency={currency} />
              )}
            />
          </Col>
        </Row>
      </Card>

      <Card title={t("dashboard.commissionRate")}>
        {/* A rate, from basis points. `formatRateBps` from `packages/shared` exists so `8425` renders as
            "84.3%" and never as "8425" - the same mistake as rendering `multiplier_bps` raw. It lives in
            the shared package because the rider app reads the same columns. */}
        <Statistic valueRender={() => formatRateBps(orders.completion_rate_bps, intlTagFor(locale)) ?? "—"} />
      </Card>
    </div>
  );
}

function Metric({ label, value }: { readonly label: string; readonly value: number }): ReactElement {
  return (
    <div className="metric-card">
      <span className="metric-card__label">{label}</span>
      <span className="metric-card__value">{value.toLocaleString()}</span>
    </div>
  );
}