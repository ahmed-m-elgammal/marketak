/**
 * `features/merchants/VendorListPage` - A4.1.
 *
 * ## Server-side filter and pagination
 *
 * Every filter and the page number go to PostgREST, and `count: "exact"` makes the total a real count rather
 * than a planner's estimate. The plan rejected a client-side slice explicitly, and the reason still holds: a
 * browser cannot page past the first few hundred rows, and transferring the whole table to display twenty of
 * them is how a merchant list becomes unusable once the city grows.
 *
 * ## Why a table and not the dashboard's row style
 *
 * A screen whose job is *finding one record among many* wants columns that line up and sort by clicking them.
 * That is a table. The dashboard's compact rows work for scanning a handful of live orders, where the shape is
 * known in advance; here the operator is searching an unknown set, so the columns do the work.
 *
 * ## Debounced search
 *
 * 300 ms, because every keystroke is a round trip and typing "souq al sharkia" would otherwise fire eleven
 * queries. The request is also cancelled on unmount and whenever the filters change, so a slow response for an
 * abandoned search cannot overwrite the results of a newer one.
 */

import { keepPreviousData, useQuery } from "@tanstack/react-query";
import { Button, Input, Select, Table } from "antd";
import type { ColumnsType } from "antd/es/table";
import type { ReactElement } from "react";
import { useTranslation } from "react-i18next";
import { useSearchParams } from "react-router-dom";

import { PageSkeleton } from "../../components/PageSkeleton.js";
import { EmptyState, ErrorState } from "../../components/StateBlock.js";
import { StatusTag } from "../../components/StatusTag.js";
import { intlTagFor } from "../../i18n/index.js";
import { useLocale } from "../../i18n/use-locale.js";
import { toFriendlyError } from "../../lib/errors.js";
import { ALL, DEFAULT_PAGE_SIZE, listVendors, type VendorRow } from "../../lib/queries/vendors.js";

/** Vertical types, from the `vertical_type` CHECK constraint. Kept beside the label keys. */
const VERTICALS = ["food", "grocery", "pharmacy", "flowers", "bakery", "others"] as const;

type Vertical = (typeof VERTICALS)[number];

/**
 * "No filter" is a *select option value*, not a filter value.
 *
 * Typed as `typeof ALL` rather than the literal `"all"`. When the option type widened to `Vertical | "all"`
 * TypeScript could not prove it excluded `"all"` when assigning it to the `Vertical`-typed filter, because the
 * string literal `"all"` widens on one side and narrows on the other. Naming the constant keeps the option type
 * and the filter type provably disjoint.
 */
type ApprovalFilter = "all" | "yes" | "no";
type StateFilter = "active" | "deleted" | "all";
type VerticalOption = Vertical | typeof ALL;

export default function VendorListPage(): ReactElement {
  const { t } = useTranslation();
  const intl = intlTagFor(useLocale());
  const [params, setParams] = useSearchParams();

  /*
   * Filters live in the URL, not in component state.
   *
   * Two reasons, both practical. An operator who filters to "not approved", copies the link and sends it to a
   * colleague now sends the *view* rather than a bare list. And the browser's back button steps out of a
   * filtered list, which is what everyone expects and what `useState` cannot do.
   */
  const search = params.get("q") ?? "";
  const vertical: VerticalOption = (params.get("vertical") as VerticalOption | null) ?? ALL;
  const approved = (params.get("approved") as ApprovalFilter | null) ?? "all";
  const state = (params.get("state") as StateFilter | null) ?? "active";
  const page = Math.max(0, Number.parseInt(params.get("page") ?? "0", 10) || 0);

  const update = (next: Record<string, string | null>): void => {
    const merged = new URLSearchParams(params);
    for (const [key, value] of Object.entries(next)) {
      if (value === null || value === "" || value === "all") {
        merged.delete(key);
      } else {
        merged.set(key, value);
      }
    }
    // Any filter change resets to the first page. Staying on page 7 of a new result set is how an operator
    // concludes a search returned nothing when it returned two hundred rows.
    if (!("page" in next)) {
      merged.delete("page");
    }
    setParams(merged, { replace: true });
  };

  const vendors = useQuery({
    queryKey: ["vendors", search, vertical, approved, state, page],
    queryFn: () =>
      listVendors({
        search: search === "" ? undefined : search,
        vertical: vertical === ALL ? undefined : vertical,
        approved,
        state,
        page,
        pageSize: DEFAULT_PAGE_SIZE,
      }),
    // Keeps the previous page's rows on screen while the next page loads, so the table does not collapse to a
    // skeleton and lose the operator's scroll position and column widths on every page change.
    placeholderData: keepPreviousData,
  });

  const columns: ColumnsType<VendorRow> = [
    {
      title: t("common.name"),
      dataIndex: "name",
      // The name is the row's identity and the only column that should dominate.
      render: (name: string, row) => (
        <span className="vendor-name">
          <span className="vendor-name__primary">{name}</span>
          {row.name_ar === null || row.name_ar === "" ? null : (
            <span className="vendor-name__secondary" dir="rtl">
              {row.name_ar}
            </span>
          )}
        </span>
      ),
    },
    {
      title: t("vendor.verticalType"),
      dataIndex: "vertical_type",
      width: 140,
      render: (value: Vertical) => <span className="muted-note">{t(`vendor.vertical${cap(value)}`)}</span>,
    },
    {
      title: t("common.status"),
      key: "status",
      width: 200,
      render: (_, row) => <VendorStatus row={row} />,
    },
    {
      title: t("vendor.prepTimeMin"),
      dataIndex: "prep_time_minutes",
      width: 120,
      align: "right",
      render: (minutes: number) => <span className="money">{minutes} min</span>,
    },
    {
      title: t("common.rating"),
      dataIndex: "rating_avg",
      width: 110,
      align: "right",
      // A rating with no reviews is not "0 stars" - it is unrated, and printing 0 would read as a bad merchant.
      render: (average: number, row) =>
        row.rating_count === 0 ? (
          <span className="muted-note">—</span>
        ) : (
          <span className="money">{average.toFixed(1)}</span>
        ),
    },
    {
      title: t("common.createdAt"),
      dataIndex: "created_at",
      width: 140,
      render: (value: string) => (
        <span className="muted-note">
          {new Intl.DateTimeFormat(intl, { dateStyle: "medium" }).format(new Date(value))}
        </span>
      ),
    },
  ];

  const total = vendors.data?.total ?? 0;
  const pages = Math.max(1, Math.ceil(total / DEFAULT_PAGE_SIZE));

  if (vendors.isError) {
    return (
      <ErrorState
        error={toFriendlyError(vendors.error)}
        onRetry={() => void vendors.refetch()}
      />
    );
  }

  return (
    <div className="page">
      <header className="page__header">
        <h1>{t("vendor.title")}</h1>
        <Button type="primary" href="/merchants/new">
          {t("vendor.add")}
        </Button>
      </header>

      {/*
        Filters in one row above the table, rather than in the table's toolbar. On a phone the toolbar collapses
        to an overflow menu that hides the filters, and an operator who cannot see why a list is short cannot
        widen it.
      */}
      <div className="filter-bar">
        <Input.Search
          allowClear
          value={search}
          placeholder={t("vendor.searchPlaceholder")}
          aria-label={t("vendor.searchPlaceholder")}
          onSearch={(value) => update({ q: value })}
          className="filter-bar__search"
        />
        <Select
          /*
            *No* generic here. antd infers the option union from the `value` prop's type, so annotating
            `onChange` with the narrower `Vertical` fights that inference and fails. The parameter is left to be
            inferred as `VerticalOption`, and the narrowing happens once at the `update` call.
          */
          value={vertical}
          aria-label={t("vendor.filterVertical")}
          onChange={(value) => update({ vertical: value === ALL ? null : value })}
          options={[
            { value: "all", label: t("vendor.verticalAll") },
            ...VERTICALS.map((value) => ({ value, label: t(`vendor.vertical${cap(value)}`) })),
          ]}
          className="filter-bar__select"
        />
        <Select
          value={approved}
          aria-label={t("vendor.filterApproved")}
          onChange={(value: ApprovalFilter) => update({ approved: value })}
          options={[
            { value: "all", label: t("vendor.approvedAll") },
            { value: "yes", label: t("vendor.approvedYes") },
            { value: "no", label: t("vendor.approvedNo") },
          ]}
          className="filter-bar__select"
        />
        <Select
          value={state}
          aria-label={t("vendor.filterState")}
          onChange={(value: StateFilter) => update({ state: value })}
          options={[
            { value: "active", label: t("vendor.stateActive") },
            { value: "deleted", label: t("vendor.stateDeleted") },
            { value: "all", label: t("vendor.stateAll") },
          ]}
          className="filter-bar__select"
        />
      </div>

      {vendors.isPending ? (
        <PageSkeleton />
      ) : (
        <Table<VendorRow>
          rowKey="id"
          columns={columns}
          dataSource={[...vendors.data.rows]}
          loading={vendors.isFetching}
          onRow={(row) => ({
            onClick: () => {
              window.location.assign(`/merchants/${row.id}`);
            },
          })}
          rowClassName="vendor-row"
          scroll={{ x: 720 }}
          pagination={false}
          locale={{
            emptyText: (
              <EmptyState
                title={t("vendor.empty")}
                hint={t("vendor.emptyHint")}
              />
            ),
          }}
        />
      )}

      {/*
        The pager states the range in absolute terms - "1–20 of 214" - because an operator cannot tell from a
        bare page number how many merchants exist. When there is exactly one page it renders nothing: an
        "1 of 1" pager on a short list is noise.
      */}
      {pages > 1 ? (
        <div className="pager">
          <span className="pager__range">
            {t("vendor.showingRange", {
              from: page * DEFAULT_PAGE_SIZE + 1,
              to: Math.min((page + 1) * DEFAULT_PAGE_SIZE, total),
              total,
            })}
          </span>
          <Button
            disabled={page === 0}
            onClick={() => update({ page: String(page - 1) })}
            className="row-action"
          >
            {t("vendor.previous")}
          </Button>
          <span className="pager__page">{t("vendor.pageOf", { page: page + 1, pages })}</span>
          <Button
            disabled={page >= pages - 1}
            onClick={() => update({ page: String(page + 1) })}
            className="row-action"
          >
            {t("vendor.next")}
          </Button>
        </div>
      ) : null}
    </div>
  );
}

/**
 * A vendor's state, as three independent facts.
 *
 * Approval and open/closed are separate columns in the database and separate decisions for an operator -
 * approving a merchant does not open it, and a merchant can be open and unapproved. Collapsing them into one
 * "status" is how a merchant ends up visible to customers while nobody approved it. Soft-deleted takes
 * precedence because it is the only state that is not about the merchant's own operation.
 */
function VendorStatus({ row }: { readonly row: VendorRow }): ReactElement {
  const { t } = useTranslation();

  if (row.deleted_at !== null) {
    return <StatusTag label={t("vendor.delete")} tone="danger" />;
  }

  return (
    <span className="vendor-status">
      <StatusTag
        label={row.is_approved ? t("status.approved") : t("status.pendingApproval")}
        tone={row.is_approved ? "success" : "warning"}
      />
      <StatusTag
        label={row.is_open ? t("status.open") : t("status.closed")}
        tone={row.is_open ? "info" : "neutral"}
      />
    </span>
  );
}

/** Uppercases the first letter so `vendor.vertical${cap(value)}` resolves. */
function cap(value: string): string {
  return value.charAt(0).toUpperCase() + value.slice(1);
}