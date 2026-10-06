/**
 * `features/dashboard/DashboardPage` - operations-first, rebuilt in A3.4.
 *
 * ## What was wrong with the previous version
 *
 * It was twenty `MetricCard`s in five identical card groups. That shape has one fatal flaw: **every number had
 * the same visual weight**, so an order stuck for forty minutes looked exactly like a sign-up count. An
 * operator opening the console to answer "is anything on fire?" had to read twenty numbers and decide. That is
 * a report, and a report is the wrong artefact for the first thirty seconds of a shift.
 *
 * The fix is ordering by *urgency*, and matching each shape to its job:
 *
 * 1. **Needs attention** - only rows that are wrong right now, cash first. Absent when nothing is wrong,
 *    because an always-present red banner trains people to ignore it.
 * 2. **Active orders** - a work queue, oldest wait first, as rows so orders compare down a column.
 * 3. **Today** - the day's totals as one compact figure row, then rates as a definition list.
 * 4. **Capacity** - merchants and riders, same treatment. These are context for the queues above.
 * 5. **Analytics** - signups, logins, search. Product telemetry, last and collapsed.
 *
 * ## Two data sources, because they answer different questions
 *
 * `get_admin_metrics_v1` gives the day's counts and money as one jsonb. It cannot give the work: a count of
 * four late orders does not say which four. `getOperationsSnapshot` reads the rows behind those counts through
 * RLS. Both are awaited before anything renders - a half-loaded board would show zero pending merchants while
 * the query was in flight, which is a false all-clear on the one screen whose job is to raise alarms.
 *
 * ## What is deliberately absent
 *
 * **Unassigned riders.** The spec asks for it. The schema cannot support it - `orders` has no rider column,
 * `sub_orders` carries vendor and settlement data only, and there is no `order_deliveries` table. A row that
 * is permanently zero because nothing can feed it is worse than an absent row: it reads as reassurance.
 *
 * **Cash variance is in the attention block, not in a card.** constitution I.10 - surfaced deliberately, never
 * filtered to zero. It belongs with the late orders because to an operator it is the same class of thing:
 * something wrong right now that will not resolve itself.
 */

import { useQuery } from "@tanstack/react-query";
import { useTranslation } from "react-i18next";
import type { ReactElement } from "react";

import { Money } from "../../components/Money.js";
import { PageSkeleton } from "../../components/PageSkeleton.js";
import { EmptyState, ErrorState } from "../../components/StateBlock.js";
import { formatRateBps } from "@marketak/shared";
import { cityDate } from "../../lib/city-date.js";
import { intlTagFor } from "../../i18n/index.js";
import { useLocale } from "../../i18n/use-locale.js";
import { toFriendlyError } from "../../lib/errors.js";
import { getAdminMetrics, type MetricsPayload } from "../../lib/queries/metrics.js";
import { getOperationsSnapshot, type OperationsSnapshot } from "../../lib/queries/operations.js";

import {
  AllClear,
  AttentionSection,
  CapacityGroup,
  Measure,
  OrderQueue,
  Section,
  Stat,
  buildAttention,
  type Translate,
} from "../operations/OperationsSections.js";

export default function DashboardPage(): ReactElement {
  const { t } = useTranslation();
  const locale = useLocale();
  const intl = intlTagFor(locale);

  const metrics = useQuery({
    queryKey: ["admin-metrics"],
    queryFn: getAdminMetrics,
    // The board is a live operations surface, and its whole purpose is to be right *now*. Polling keeps it
    // current without a reload; 30 s is a deliberate ceiling on staleness rather than a reflex, because a
    // screen that refreshes every two seconds on a metered tablet connection costs more than it is worth.
    refetchInterval: 30_000,
  });
  const operations = useQuery({
    queryKey: ["admin-operations"],
    queryFn: getOperationsSnapshot,
    refetchInterval: 30_000,
  });

  // Both feeds are needed before anything renders. See the file header for why a half-loaded board is worse
  // than no board.
  if (metrics.isPending || operations.isPending) {
    return <PageSkeleton />;
  }

  const error = metrics.error ?? operations.error;
  if (error !== null && error !== undefined) {
    return (
      <ErrorState
        error={toFriendlyError(error)}
        onRetry={() => {
          void metrics.refetch();
          void operations.refetch();
        }}
      />
    );
  }

  // Checked together rather than as two branches. React Query types `data` as `T | undefined`, so testing only
  // `=== null` would leave `undefined` reaching a property read - and an undefined payload with no error is
  // exactly the "no settlement row" case the RPC models as `null`.
  const payload: MetricsPayload | null | undefined = metrics.data;
  if (payload === null || payload === undefined) {
    return (
      <EmptyState
        title={t("empty.noResults")}
        hint={t("empty.noResultsHint")}
        action={{ label: t("app.retry"), onClick: () => void metrics.refetch() }}
      />
    );
  }

  const { orders, revenue, vendors, riders, funnel, eta_accuracy, cancellation, timezone } = payload;
  // Non-null asserted through a named local rather than `!`. `operations.data` is only `undefined` while its
  // query is pending or errored, both of which returned above, so the invariant holds - and a named binding says
  // so where a `!` just asserts it silently.
  const board: OperationsSnapshot = operations.data as OperationsSnapshot;
  const liveOrders = board.liveOrders;

  const hasVariance = revenue.float_variance !== 0;

  /**
   * The city-local date the RPC measured.
   *
   * Recomputed here from the zone the RPC itself used rather than read from the tablet, so the variance row
   * names the same day the figures are about. `cityDate` returns `undefined` for an unusable zone, and an
   * unknown time cannot be formatted - so it is omitted from the sentence rather than printed as "undefined".
   */
  const businessDate = cityDate(new Date(), timezone);
  const piastres = (amount: number): string =>
    new Intl.NumberFormat(intl, {
      style: "decimal",
      minimumFractionDigits: 2,
      maximumFractionDigits: 2,
    }).format(amount / 100);

  const onTime = formatRateBps(eta_accuracy.on_time_rate_bps, intl);
  const cancelled = formatRateBps(cancellation.order_rate_bps, intl);

  /**
   * The work list, in the order an operator should work it.
   *
   * Cash first: a variance is money the platform cannot account for, and it is the one item here that does not
   * resolve by itself. Then orders past their promise, then merchants who have not accepted, then uncollected
   * cash, then unapproved merchants.
   */
  const attention = buildAttention({
    // `businessDate` is `string | undefined` because `cityDate` refuses to guess at an unusable zone. The
    // variance row is the one place a missing date would print "undefined" into a sentence an operator reads,
    // so the empty string is passed and i18next omits the clause.
    variance: {
      hasVariance,
      amount: revenue.float_variance,
      currency: revenue.currency,
      date: businessDate ?? "",
    },
    late: board.lateOrders,
    awaiting: board.awaitingVendors,
    unpaid: board.unpaidOrders,
    pendingVendors: board.pendingVendors,
    t,
    format: piastres,
  });


  return (
    <div className="page">
      <header className="page__header">
        <h1>{t("dashboard.title")}</h1>
        {/* Named once, not per figure: the RPC derived its window from `cities.timezone`, and an operator should
            never have to guess which day the screen describes. */}
        <span className="muted-note">{t("dashboard.timezoneNote", { timezone })}</span>
      </header>

      {attention.length > 0 ? <AttentionSection entries={attention} /> : <AllClear />}

      {/*
        The board. `Section` states the open count as a phrase rather than a bare number, so the heading reads
        "Active orders · 3 open" instead of a numeral that could be mistaken for a percentage or a rank.
      */}
      <Section
        title={t("dashboard.activeTitle")}
        count={liveOrders.length}
        meta={liveOrders.length === 0 ? undefined : t("dashboard.openOrdersCount", { count: liveOrders.length })}
      >
        <OrderQueue orders={liveOrders} />
      </Section>

      {/*
        Today, as one scannable band rather than a grid of cards.

        The count and its rate are the *same fact* at two scales, so they belong adjacent and share one
        visual unit - four order counts in a row, then the derived rates underneath. The earlier version put
        `Completed 0.0%` beside a hint reading `0.0% of today's orders`, which printed the number twice and
        made a completion rate look like two separate metrics.
      */}
      <Section title={t("dashboard.todayTitle")}>
        <div className="stat-band">
          <Stat label={t("dashboard.ordersPlaced")} value={orders.placed} />
          <Stat label={t("dashboard.ordersDelivered")} value={orders.delivered} />
          <Stat
            label={t("dashboard.ordersCancelled")}
            value={orders.cancelled}
            tone={orders.cancelled > 0 ? "muted" : "default"}
          />
          <Stat label={t("dashboard.ordersOpen")} value={orders.open} emphasis />
        </div>

        <dl className="measure-list">
          {/*
            Completion is stated as counts, not as a rate beside its own percentage. `0 of 1` is
            unambiguous where `0.0%` next to `0.0% of today's orders` reads as two disagreeing figures.
          */}
          <Measure
            label={t("dashboard.completedOfPlaced")}
            value={t("dashboard.completedOfPlacedValue", {
              delivered: orders.delivered,
              placed: orders.placed,
            })}
          />
          <Measure label={t("dashboard.onTimeRate")} value={onTime ?? "—"} />
          <Measure label={t("dashboard.cancellationRate")} value={cancelled ?? "—"} />
          <Measure
            label={t("dashboard.etaAverage")}
            value={etaMinutes(eta_accuracy.avg_signed_error_min, t)}
            hint={t("dashboard.etaAverageHint")}
          />
        </dl>

        <dl className="measure-list measure-list--split">
          <Measure
            label={t("dashboard.cashRemitted")}
            value={<Money amount={revenue.cash_remitted} currency={revenue.currency} />}
            hint={t("dashboard.cashRemittedHint")}
          />
          <Measure
            label={t("dashboard.riderTips")}
            value={<Money amount={revenue.rider_tips} currency={revenue.currency} />}
          />
          <Measure
            label={t("dashboard.cashExpected")}
            value={<Money amount={revenue.cash_expected} currency={revenue.currency} />}
          />
        </dl>
      </Section>

      {/*
        Merchants and riders, split into two labelled groups rather than one flat list of six.

        The flat version read as a single column of unrelated numbers, and mixing a merchant count with a
        rider count in one alphabetical-looking run made it impossible to tell which side of the marketplace
        a figure belonged to. Two groups with their own sub-headings say it without an icon.
      */}
      <Section title={t("dashboard.capacityTitle")}>
        <div className="pair">
          <CapacityGroup
            title={t("dashboard.merchantsTitle")}
            action={{ label: t("nav.merchants"), href: "/merchants" }}
          >
            <Measure label={t("dashboard.vendorsActive")} value={vendors.active_approved} />
            <Measure label={t("dashboard.vendorsOpen")} value={vendors.open_now} />
            <Measure label={t("dashboard.vendorsPaused")} value={vendors.paused} />
            <Measure
              label={t("dashboard.vendorsPending")}
              value={vendors.pending_approval}
              tone={vendors.pending_approval > 0 ? "warning" : "default"}
            />
          </CapacityGroup>

          <CapacityGroup
            title={t("dashboard.ridersTitle")}
            action={{ label: t("nav.riders"), href: "/riders" }}
          >
            <Measure label={t("dashboard.ridersOnline")} value={riders.online_now} emphasis />
            <Measure label={t("dashboard.ridersActive")} value={riders.active} />
            {/*
              Verified riders are stated as `2 of 3 online`. The earlier phrasing - a "Verified" pill beside
              the hint "1 verified and online now" - made a count look like a status, and the sentence
              described the same fact the number already showed.
            */}
            <Measure
              label={t("dashboard.ridersVerified")}
              value={t("dashboard.ridersVerifiedValue", {
                verified: riders.verified_online,
                online: riders.online_now,
              })}
            />
          </CapacityGroup>
        </div>
      </Section>

      {/*
        Analytics, last and collapsed.

        The `hint` is what makes it read as deliberate rather than unfinished: a bare collapsed `<details>`
        looks like something the developer forgot to finish. Saying these are product telemetry and not live
        operations tells the operator the section was demoted on purpose and there is nothing missing from it.
      */}
      <details className="analytics">
        <summary className="analytics__summary">
          <span className="analytics__title">{t("dashboard.analyticsTitle")}</span>
          <span className="analytics__hint">{t("dashboard.analyticsHint")}</span>
        </summary>
        <dl className="measure-list">
          <Measure label={t("dashboard.signups")} value={funnel.signups} />
          <Measure label={t("dashboard.logins")} value={funnel.logins} />
          <Measure label={t("dashboard.searches")} value={funnel.searches_with_clicks} />
          <Measure
            label={t("dashboard.zeroResultRate")}
            value={formatRateBps(funnel.zero_result_rate_bps, intl) ?? "—"}
          />
        </dl>
      </details>
    </div>
  );
}


/**
 * Signed error in minutes, with the unit.
 *
 * The value is *signed* by design - positive means arriving late, negative early - so it is rendered with a
 * leading `+` when positive. Dropping the sign would make "late by four minutes" and "early by four minutes"
 * print identically, which is the single most misleading thing this figure could do.
 */
function etaMinutes(
  value: number | null | undefined,
  t: Translate,
): string {
  if (value === null || value === undefined) {
    return "—";
  }
  return t("dashboard.etaSigned", { value: value > 0 ? `+${value}` : value });
}