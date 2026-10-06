/**
 * `features/operations/OperationsSections` - the reusable pieces of the operations board.
 *
 * Split out of `DashboardPage` because that file was over the 300-line ceiling in `AGENTS.md` rule 5 the moment
 * the attention queue and the order queue went in, and because the queue is worth testing on its own.
 *
 * ## Why lists and not cards
 *
 * The rule this file exists to apply: **a card can hold one number and a label; anything with attributes needs
 * a row.** An order has a number, a status, a merchant count, a promise and an amount - five things to
 * compare across orders, which is exactly what a single-column card cannot do. Cards force the operator to
 * read boxes one at a time instead of scanning a column.
 */

import { useTranslation } from "react-i18next";
import type { TFunction } from "i18next";
import { Link } from "react-router-dom";
import type { ReactElement, ReactNode } from "react";

import { Money } from "../../components/Money.js";
import { StatusTag } from "../../components/StatusTag.js";
import type { Tone } from "../../components/StatusTag.js";
import { intlTagFor } from "../../i18n/index.js";
import { useLocale } from "../../i18n/use-locale.js";
import { type OrderStatus } from "../../lib/order-status.js";
import type { AttentionItem, LiveOrder, PendingVendorRow } from "../../lib/queries/operations.js";

/**
 * The translation function, as `react-i18next` types it.
 *
 * Aliased rather than re-declared as `(key: string, options?) => string`. That hand-written shape is *not*
 * supertype-compatible with i18next's `TFunction`, whose key parameter is generic, so passing a real `t` into a
 * helper typed that way fails to compile - the type system correctly refusing to let us pretend the two are
 * interchangeable. Using the library's own type keeps the helpers honest and still testable: a test passes a
 * `TFunction` shaped stub.
 */
export type Translate = TFunction;

/** One thing that is wrong right now, and where to go about it. */
export interface AttentionEntry {
  readonly key: string;
  readonly tone: "danger" | "warning" | "info";
  readonly title: string;
  readonly detail: string;
  readonly action: { readonly label: string; readonly href: string };
}

/**
 * The attention list.
 *
 * Rendered only when something is wrong. An always-present section that is usually empty is noise, and noise
 * trains people to stop reading it - for the section to be worth anything its presence has to mean something.
 */
export function AttentionSection({
  entries,
}: {
  readonly entries: readonly AttentionEntry[];
}): ReactElement {
  const { t } = useTranslation();

  return (
    <section className="attention" aria-labelledby="attention-heading">
      <h2 className="attention__heading" id="attention-heading">
        {t("attention.title")}
        <span className="attention__count">{entries.length}</span>
      </h2>
      <ul className="attention__list">
        {entries.map((entry) => (
          <li key={entry.key} className={`attention__item attention__item--${entry.tone}`}>
            <div className="attention__text">
              <strong className="attention__item-title">{entry.title}</strong>
              <span className="attention__detail">{entry.detail}</span>
            </div>
            <a className="attention__action" href={entry.action.href}>
              {entry.action.label}
            </a>
          </li>
        ))}
      </ul>
    </section>
  );
}

/** Shown instead of the attention list when nothing needs attention. Quiet by design - see `global.css`. */
export function AllClear(): ReactElement {
  const { t } = useTranslation();

  return (
    <div className="all-clear">
      <span className="all-clear__mark" aria-hidden="true">
        ✓
      </span>
      <div>
        <strong>{t("attention.clearTitle")}</strong>
        <p className="all-clear__body">{t("attention.clearBody")}</p>
      </div>
    </div>
  );
}

/**
 * How urgent a live order is.
 *
 * A separate axis from the stored status: "Delivering, 12 min late" and "Delivering, on time" are the same
 * status and very different rows, so the stored status alone cannot drive the visual weight. Three levels
 * rather than more, because every additional level is one more thing an operator has to learn.
 */
export type OrderUrgency = "overdue" | "soon" | "ontime";

/**
 * An order due within this many minutes reads as "soon" rather than merely "not yet late".
 *
 * Exported so the boundary itself can be asserted in tests. A threshold that decides whether an order gets an
 * alarm edge is a business rule, and a rule whose exact edge cannot be tested is a rule that will be moved by
 * accident.
 */
export const SOON_WINDOW_MS = 15 * 60_000;

/**
 * Classify urgency from the promise.
 *
 * `picked_up` with no promise cannot be late - nobody has been given a time yet - so it is "soon" rather than
 * a false reassurance. That state is called out separately by `awaitingPickup`.
 */
export function orderUrgency(
  order: Pick<LiveOrder, "status" | "promised_delivery_at">,
  now: number,
): OrderUrgency {
  const promised = order.promised_delivery_at;
  if (promised === null) {
    return "soon";
  }
  const due = Date.parse(promised);
  if (due < now) {
    return "overdue";
  }
  return due - now <= SOON_WINDOW_MS ? "soon" : "ontime";
}

/**
 * The live board, with the row that needs the operator most promoted.
 *
 * The oldest-waiting order is rendered as a **focus card** - larger type, its own status, a clear action - and
 * the rest follow as compact rows beneath it. Every live order was already equally weighted in the previous
 * version, so an order about to breach its promise looked identical to one with an hour to run.
 *
 * Whole-row clickable via `react-router`'s `Link` rather than a small button: the row is the target, and a 32px
 * affordance in a 64px row is a miss on a tablet. Keyboard and screen-reader behaviour come free from `Link`,
 * which a click handler on a `div` would not.
 */
export function OrderQueue({ orders }: { readonly orders: readonly LiveOrder[] }): ReactElement {
  const { t } = useTranslation();
  const intl = intlTagFor(useLocale());
  const now = Date.now();
  const time = new Intl.DateTimeFormat(intl, { hour: "2-digit", minute: "2-digit" });

  // `orders` arrives oldest-first from the query, so the first row is the longest wait.
  const [focus, ...rest] = orders;

  if (focus === undefined) {
    return <p className="section__empty">{t("dashboard.activeEmpty")}</p>;
  }

  return (
    <div className="board">
      <FocusOrder order={focus} time={time} now={now} />

      {rest.length === 0 ? null : (
        <ul className="queue">
          {rest.map((order) => {
            const urgency = orderUrgency(order, now);
            return (
              <li key={order.id} className={`queue__row queue__row--${urgency}`}>
                <Link className="queue__link" to={`/orders/${order.id}`}>
                  <span className="queue__number">{order.order_number}</span>
                  <StatusTag label={t(`orderStatus.${order.status}`)} tone={orderTone(order.status)} />
                  <span className="queue__meta">{orderMeta(order, t)}</span>
                  <span className="queue__eta">{dueLabel(order, t, time, now)}</span>
                  <span className="queue__amount">
                    <Money amount={order.total} currency={order.currency} />
                  </span>
                </Link>
              </li>
            );
          })}
        </ul>
      )}
    </div>
  );
}

/**
 * The single most urgent live order, given room to breathe.
 *
 * The only place on the screen with a large figure and a visible action, which is what makes it the focal
 * point without needing a colour or a shadow to announce itself.
 */
function FocusOrder({
  order,
  time,
  now,
}: {
  readonly order: LiveOrder;
  readonly time: Intl.DateTimeFormat;
  readonly now: number;
}): ReactElement {
  const { t } = useTranslation();
  const urgency = orderUrgency(order, now);

  return (
    <Link className={`focus focus--${urgency}`} to={`/orders/${order.id}`}>
      <div className="focus__head">
        <span className="focus__number">{order.order_number}</span>
        <StatusTag label={t(`orderStatus.${order.status}`)} tone={orderTone(order.status)} />
        <span className={`focus__urgency focus__urgency--${urgency}`}>{urgencyLabel(order, urgency, t)}</span>
      </div>

      <div className="focus__body">
        {/*
          The promise is the largest text on the row because it is the deadline the customer was given, and
          it is the number an operator is actually working against.
        */}
        <span className="focus__promise">{dueLabel(order, t, time, now)}</span>
        <span className="focus__meta">{orderMeta(order, t)}</span>
      </div>

      <span className="focus__amount">
        <Money amount={order.total} currency={order.currency} />
      </span>
    </Link>
  );
}

function orderMeta(order: LiveOrder, t: Translate): string {
  const vendors = t("dashboard.vendorsCount", { count: order.vendor_count });
  return order.payment_method === "cash" ? `${vendors} · ${t("orderStatus.cash")}` : vendors;
}

function dueLabel(
  order: Pick<LiveOrder, "promised_delivery_at">,
  t: Translate,
  time: Intl.DateTimeFormat,
  now: number,
): string {
  const promised = order.promised_delivery_at;
  if (promised === null) {
    return "—";
  }
  // Compared as timestamps, not as formatted strings. `"10:30" < "09:00"` is false even when 10:30 is later,
  // because the strings sort lexically - which is the same class of bug as comparing money as strings.
  const dueAt = Date.parse(promised);
  return dueAt < now
    ? t("attention.lateBy", { minutes: lateMinutes(promised, now) })
    : t("dashboard.dueBy", { time: time.format(new Date(dueAt)) });
}

/**
 * The urgency word, not a colour.
 *
 * `awaitingPickup` wins over `soon`: an order sitting in `picked_up` with no promise is a stalled handover
 * rather than a merely-upcoming delivery, and calling that "due soon" would hide the problem.
 */
function urgencyLabel(order: LiveOrder, urgency: OrderUrgency, t: Translate): string {
  if (order.status === "picked_up" && order.promised_delivery_at === null) {
    return t("dashboard.awaitingPickup");
  }
  switch (urgency) {
    case "overdue":
      return t("dashboard.overdue");
    case "soon":
      return t("dashboard.dueSoon");
    case "ontime":
      return t("dashboard.onTime");
  }
}

/**
 * A section: a heading with an optional count, then content.
 *
 * The heading carries a `meta` slot for a subordinate phrase. Sections previously blended into one another
 * because every heading was identical uppercase grey text - the reader had nothing to anchor on. A short
 * right-hand note ("product telemetry, not live operations") tells the reader why a section is quieter than
 * its neighbours, which is information the whitespace alone cannot carry.
 */
export function Section({
  title,
  count,
  meta,
  children,
}: {
  readonly title: string;
  readonly count?: number;
  readonly meta?: string | undefined;
  readonly children: ReactNode;
}): ReactElement {
  return (
    <section className="section">
      <div className="section__head">
        <h2 className="section__heading">
          {title}
          {count === undefined ? null : <span className="section__count">{count}</span>}
        </h2>
        {meta === undefined ? null : <span className="section__meta">{meta}</span>}
      </div>
      {children}
    </section>
  );
}

/**
 * One figure in the Today band.
 *
 * `emphasis` marks the figure an operator reads first - the open count, the number that says whether anyone
 * needs watching. It is a weight and a size change, not a colour: this band sits directly under the work
 * queues, and tinting figures here would compete with the attention block for the same visual channel.
 */
export function Stat({
  label,
  value,
  emphasis,
  tone = "default",
}: {
  readonly label: string;
  readonly value: ReactNode;
  readonly emphasis?: boolean | undefined;
  readonly tone?: "default" | "muted";
}): ReactElement {
  const classes = ["stat", emphasis === true ? "stat--emphasis" : "", tone === "muted" ? "stat--muted" : ""]
    .filter((c) => c !== "")
    .join(" ");

  return (
    <div className={classes}>
      <span className="stat__label">{label}</span>
      <span className="stat__value">{value}</span>
    </div>
  );
}

/**
 * A labelled group of measures - one side of the marketplace.
 *
 * Splitting merchants from riders is not cosmetic. In one flat list of six figures, a merchant count and a
 * rider count looked like neighbours, and the reader had to already know which was which.
 */
export function CapacityGroup({
  title,
  action,
  children,
}: {
  readonly title: string;
  readonly action: { readonly label: string; readonly href: string };
  readonly children: ReactNode;
}): ReactElement {
  return (
    <div className="group">
      <div className="group__head">
        <h3 className="group__title">{title}</h3>
        <Link className="group__action" to={action.href}>
          {action.label}
        </Link>
      </div>
      <dl className="measure-list">{children}</dl>
    </div>
  );
}

/**
 * One figure and its label.
 *
 * A cell in a row, not a card. A row of six reads as a summary line; six cards read as six widgets competing
 * for attention, which is the failure this redesign exists to remove.
 */
/**
 * A rate, its value, and what the number means.
 *
 * A definition-list row rather than a card because a card holds one number and a label, and a rate without its
 * caveat is a claim the operator has to verify somewhere else.
 */
export function Measure({
  label,
  value,
  hint,
  tone = "default",
  emphasis,
}: {
  readonly label: string;
  readonly value: ReactNode;
  /** Spelled `| undefined` rather than `?:` because `exactOptionalPropertyTypes` is on: with `?`, passing an
   * explicit `undefined` is a type error, and every caller here computes the hint conditionally. */
  readonly hint?: string | undefined;
  /** `warning` is reserved for a count that is a problem in itself - merchants awaiting approval. */
  readonly tone?: "default" | "warning";
  readonly emphasis?: boolean | undefined;
}): ReactElement {
  const classes = [
    "measure",
    tone === "warning" ? "measure--warning" : "",
    emphasis === true ? "measure--emphasis" : "",
  ]
    .filter((c) => c !== "")
    .join(" ");

  return (
    <div className={classes}>
      <dt className="measure__label">{label}</dt>
      <dd className="measure__value">
        {value}
        {hint === undefined ? null : <span className="measure__hint">{hint}</span>}
      </dd>
    </div>
  );
}

/**
 * The attention queue, in the order an operator should work it.
 *
 * ## Why the ordering is business logic and not a rendering detail
 *
 * Cash first, because a variance is money the platform cannot account for and it is the one item here that
 * does not resolve by itself. Then orders past the promise the customer was given, then orders no merchant has
 * accepted, then cash not yet collected, then merchants awaiting approval.
 *
 * That sequence is why this is a separate exported function rather than inline JSX: it is the actual policy of
 * the screen, and inline JSX would make it untestable without standing up React, i18next and two queries.
 */
export function buildAttention(input: {
  readonly variance: {
    readonly hasVariance: boolean;
    readonly amount: number;
    readonly currency: string;
    readonly date: string;
  };
  readonly late: readonly AttentionItem[];
  readonly awaiting: readonly AttentionItem[];
  readonly unpaid: readonly AttentionItem[];
  readonly pendingVendors: readonly PendingVendorRow[];
  readonly t: Translate;
  /** Piastres to a bare grouped decimal, for prose. `Money` already names the currency. */
  readonly format: (amount: number) => string;
}): readonly AttentionEntry[] {
  const { variance, late, awaiting, unpaid, pendingVendors, t, format } = input;

  // Built by pushing into a typed array rather than spreading a literal. The spread version had to write
  // `as const` on every `tone` to stop TypeScript widening them to `string`, which is four annotations
  // carried by hand and one missing one away from a type error in a different file.
  const entries: AttentionEntry[] = [];

  if (variance.hasVariance) {
    entries.push({
      key: "variance",
      tone: "danger",
      title: t("attention.varianceTitle"),
      detail: t("attention.varianceDetail", {
        amount: format(variance.amount),
        currency: variance.currency,
        date: variance.date,
      }),
      action: { label: t("nav.reconciliation"), href: "/reconciliation" },
    });
  }

  for (const order of late) {
    entries.push({
      key: `late-${order.id}`,
      tone: "danger",
      title: t("attention.lateOrder", { number: order.order_number }),
      detail: t("attention.lateOrderDetail", {
        minutes: order.minutes_overdue,
        amount: format(order.total),
        currency: order.currency,
      }),
      action: { label: t("nav.orders"), href: "/orders" },
    });
  }

  for (const order of awaiting) {
    entries.push({
      key: `awaiting-${order.id}`,
      tone: "warning",
      title: t("attention.awaitingVendor", { number: order.order_number }),
      detail: t("attention.awaitingVendorDetail", { minutes: order.minutes_overdue }),
      action: { label: t("nav.orders"), href: "/orders" },
    });
  }

  for (const order of unpaid) {
    entries.push({
      key: `unpaid-${order.id}`,
      tone: "info",
      title: t("attention.unpaidOrder", { number: order.order_number }),
      detail: t("attention.unpaidOrderDetail", {
        amount: format(order.total),
        currency: order.currency,
      }),
      action: { label: t("nav.orders"), href: "/orders" },
    });
  }

  // Longest-waiting first, and the sort is here rather than left to the query's `order`. An approval queue read
  // newest-first sends an admin to the shop that applied two minutes ago while the one that applied this morning
  // waits - and the ordering is part of the screen's policy, so it is not left to whichever query produced it.
  for (const vendor of [...pendingVendors].sort((a, b) => b.waiting_minutes - a.waiting_minutes)) {
    entries.push({
      key: `vendor-${vendor.id}`,
      tone: "warning",
      title: t("attention.pendingVendor", { name: vendor.name }),
      detail: t("attention.pendingVendorDetail", { minutes: vendor.waiting_minutes }),
      // `/merchants`, not `/vendors`: that is the path in `app/routes.tsx`. A row is only actionable if its link
      // resolves, and `/vendors` was a 404 - the one dead link on the console's primary screen.
      action: { label: t("nav.merchants"), href: "/merchants" },
    });
  }

  // Every entry's key is prefixed by category, so two different categories about the same order - a late order
  // that is also awaiting a merchant - get distinct keys. React reusing one row for the other is how a
  // 40-minute-late order renders as a 2-minute one.
  return entries;
}

/** Status to tone. Terminal statuses never reach the board, but the switch is total rather than partial. */
function orderTone(status: OrderStatus): Tone {
  switch (status) {
    case "picked_up":
    case "delivering":
      return "info";
    case "ready":
    case "delivered":
      return "success";
    case "pending":
    case "partially_confirmed":
      return "warning";
    case "preparing":
      return "neutral";
    case "cancelled":
    case "partially_cancelled":
      return "danger";
  }
}

function lateMinutes(promised: string, now: number): number {
  return Math.max(0, Math.round((now - Date.parse(promised)) / 60_000));
}