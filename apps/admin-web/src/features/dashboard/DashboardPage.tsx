/**
 * `features/dashboard/DashboardPage` - A3.1 and A3.2.
 *
 * ## What one RPC returns
 *
 * `get_admin_metrics_v1` builds a single jsonb with six blocks - funnel, orders, revenue, cancellation, eta
 * accuracy, vendors, riders - and already derives its day boundary from `cities.timezone`. So this screen is
 * **one** request and no date picker: sending a date would override the RPC's own definition and could
 * disagree with it. `lib/city-date.ts` exists for the screens that *do* let an operator choose a day.
 *
 * ## `float_variance` is rendered whatever it says
 *
 * constitution I.10, and the RPC's own comment: the variance is surfaced deliberately and never filtered to
 * zero. The obvious dashboard behaviour - grey out a zero variance, show a colour only when non-zero - destroys
 * the signal the number exists to raise, because an operator can no longer tell "no difference" from "not
 * computed". So it is always shown, always labelled, and gets the warning tone whenever it is non-zero.
 */

import { useQuery } from "@tanstack/react-query";
import { Alert, Card, Col, Row } from "antd";
import { formatRateBps } from "@marketak/shared";
import type { ReactElement } from "react";
import { useTranslation } from "react-i18next";

import { MetricCard, MetricGrid } from "../../components/MetricCard.js";
import { Money } from "../../components/Money.js";
import { PageSkeleton } from "../../components/PageSkeleton.js";
import { EmptyState, ErrorState } from "../../components/StateBlock.js";
import { StatusTag } from "../../components/StatusTag.js";
import { intlTagFor } from "../../i18n/index.js";
import { useLocale } from "../../i18n/use-locale.js";
import { toFriendlyError } from "../../lib/errors.js";
import { getAdminMetrics } from "../../lib/queries/metrics.js";

export default function DashboardPage(): ReactElement {
  const { t } = useTranslation();
  const locale = useLocale();

  const metrics = useQuery({
    queryKey: ["admin-metrics"],
    queryFn: getAdminMetrics,
  });

  if (metrics.isPending) {
    return <PageSkeleton />;
  }

  if (metrics.isError) {
    return <ErrorState error={toFriendlyError(metrics.error)} onRetry={() => void metrics.refetch()} />;
  }

  const payload = metrics.data;

  // No settlement row yet for today. Distinct from an error and from "everything is zero" - an operator
  // looking at an empty day needs to be told the day has no data, not left staring at zeros.
  if (payload === null) {
    return (
      <EmptyState
        title={t("empty.noResults")}
        hint={t("empty.noResultsHint")}
        action={{ label: t("app.retry"), onClick: () => void metrics.refetch() }}
      />
    );
  }

  const { orders, revenue, vendors, riders, funnel, eta_accuracy, cancellation, timezone } = payload;
  const intl = intlTagFor(locale);
  const hasVariance = revenue.float_variance !== 0;

  return (
    <div className="page">
      <header className="page__header">
        <h1>{t("dashboard.title")}</h1>
        {/* Named once rather than repeated per card: an operator should never have to guess which timezone
            the screen is in, and the RPC derived its window from `cities.timezone`. */}
        <span className="metric-card__hint">{t("dashboard.timezoneNote", { timezone })}</span>
      </header>

      {/*
        The variance alert, shown whenever the figure is non-zero. It is an Alert rather than a metric card
        because it demands an action, and an operator scanning cards will not read a number that is quietly
        coloured.
      */}
      {hasVariance ? (
        <Alert
          type="error"
          showIcon
          message={t("variance.warningTitle")}
          description={t("variance.warningBody", {
            expected: formatShort(revenue.cash_expected, intl),
            remitted: formatShort(revenue.cash_remitted, intl),
            variance: formatShort(revenue.float_variance, intl),
          })}
        />
      ) : null}

      <section aria-label={t("nav.orders")}>
        <MetricGrid>
          <MetricCard label={t("dashboard.ordersPlaced")} value={orders.placed} />
          <MetricCard label={t("dashboard.ordersDelivered")} value={orders.delivered} />
          <MetricCard label={t("dashboard.ordersCancelled")} value={orders.cancelled} />
          <MetricCard
            label={t("dashboard.ordersOpen")}
            value={orders.open}
            hint={t("dashboard.completionRateHint", {
              rate: formatRateBps(orders.completion_rate_bps, intl) ?? "—",
            })}
          />
        </MetricGrid>
      </section>

      <Card title={t("variance.title")}>
        <Row gutter={[16, 16]}>
          <Col xs={12} md={6}>
            <MetricCard
              label={t("variance.cashExpected")}
              value={<Money amount={revenue.cash_expected} currency={revenue.currency} />}
            />
          </Col>
          <Col xs={12} md={6}>
            <MetricCard
              label={t("variance.cashRemitted")}
              value={<Money amount={revenue.cash_remitted} currency={revenue.currency} />}
            />
          </Col>
          <Col xs={12} md={6}>
            {/*
              constitution I.10. Always rendered, never filtered to zero, and toned whenever non-zero - so
              "no difference" and "not computed" cannot be mistaken for one another.
            */}
            <MetricCard
              label={t("variance.variance")}
              value={<Money amount={revenue.float_variance} currency={revenue.currency} />}
              tone={hasVariance ? "warning" : "default"}
              hint={hasVariance ? t("variance.unexplained") : t("variance.explained")}
            />
          </Col>
          <Col xs={12} md={6}>
            <MetricCard
              label={t("dashboard.riderTips")}
              value={<Money amount={revenue.rider_tips} currency={revenue.currency} />}
            />
          </Col>
        </Row>
      </Card>

      <Card title={t("dashboard.funnel")}>
        <Row gutter={[16, 16]}>
          <Col xs={12} md={6}>
            <MetricCard label={t("dashboard.signups")} value={funnel.signups} />
          </Col>
          <Col xs={12} md={6}>
            <MetricCard label={t("dashboard.logins")} value={funnel.logins} />
          </Col>
          <Col xs={12} md={6}>
            <MetricCard label={t("dashboard.searches")} value={funnel.searches_with_clicks} />
          </Col>
          <Col xs={12} md={6}>
            <MetricCard
              label={t("dashboard.zeroResultRate")}
              value={`${formatRateBps(funnel.zero_result_rate_bps, intl) ?? "—"}`}
            />
          </Col>
        </Row>
      </Card>

      <Card title={t("dashboard.eta")}>
        <Row gutter={[16, 16]}>
          <Col xs={12} md={6}>
            <MetricCard label={t("dashboard.onTimeRate")} value={formatRateBps(eta_accuracy.on_time_rate_bps, intl) ?? "—"} />
          </Col>
          <Col xs={12} md={6}>
            <MetricCard
              label={t("dashboard.etaAverage")}
              value={eta_accuracy.avg_signed_error_min ?? "—"}
              hint={t("dashboard.etaMinutes")}
            />
          </Col>
          <Col xs={12} md={6}>
            <MetricCard label={t("dashboard.etaMedian")} value={eta_accuracy.p50_signed_error_min ?? "—"} />
          </Col>
          <Col xs={12} md={6}>
            <MetricCard
              label={t("dashboard.cancellationRate")}
              value={formatRateBps(cancellation.order_rate_bps, intl) ?? "—"}
            />
          </Col>
        </Row>
      </Card>

      <Card title={t("dashboard.vendors")}>
        <Row gutter={[16, 16]}>
          <Col xs={12} md={6}>
            <MetricCard label={t("dashboard.vendorsActive")} value={vendors.active_approved} />
          </Col>
          <Col xs={12} md={6}>
            <MetricCard label={t("dashboard.vendorsOpen")} value={vendors.open_now} />
          </Col>
          <Col xs={12} md={6}>
            <MetricCard label={t("dashboard.vendorsPaused")} value={vendors.paused} />
          </Col>
          <Col xs={12} md={6}>
            <MetricCard
              label={t("dashboard.vendorsPending")}
              value={vendors.pending_approval}
              {...(vendors.pending_approval > 0 ? { hint: t("dashboard.vendorsPendingHint") } : {})}
            />
          </Col>
        </Row>
      </Card>

      <Card title={t("dashboard.riders")}>
        <Row gutter={[16, 16]}>
          <Col xs={12} md={8}>
            <MetricCard label={t("dashboard.ridersActive")} value={riders.active} />
          </Col>
          <Col xs={12} md={8}>
            <MetricCard label={t("dashboard.ridersOnline")} value={riders.online_now} />
          </Col>
          <Col xs={12} md={8}>
            <MetricCard
              label={t("dashboard.ridersVerified")}
              value={<StatusTag label={t("status.verified")} tone="success" />}
              hint={t("dashboard.ridersVerifiedHint", { count: riders.verified_online })}
            />
          </Col>
        </Row>
      </Card>
    </div>
  );
}

/**
 * A compact number for prose inside an Alert description.
 *
 * `Money` is right for a figure in a card and wrong inside a sentence - it returns the full localised currency
 * string, and the sentence already names the currency. This keeps the sentence readable.
 */
function formatShort(amount: number, intl: string): string {
  return new Intl.NumberFormat(intl, {
    style: "decimal",
    minimumFractionDigits: 2,
    maximumFractionDigits: 2,
  }).format(amount / 100);
}