/**
 * `features/settings/FlagsPage` - A3.5, the T6.2 surface.
 *
 * ## Read-only, and honest about being read-only
 *
 * There is no `admin_upsert_feature_flag` RPC — I checked the live schema, and the 48 `admin_*` functions cover
 * vendors, cities, areas, brands, cuisines, menus, staff, schedules, holidays and vouchers, but not flags. So
 * this screen **reads** flags and says so, rather than rendering switches that would do nothing when clicked.
 *
 * A toggle that silently fails is worse than a read-only list: an operator toggles a kill switch during an
 * incident, sees it flip, and believes the system changed. Toggling flags is a phase 6 task; this is the
 * visibility half of it.
 *
 * ## Why the raw value is shown next to the reading
 *
 * `value` is a targeting document — `{ "enabled": true, "roles": ["rider"], "min_app_version": "1.2.0" }`. The
 * screen renders it verbatim in a monospace block *and* renders the bits an operator acts on. The raw form is
 * what someone debugs with; the reading is what they decide with.
 */

import { useQuery } from "@tanstack/react-query";
import { Alert, Card, Table } from "antd";
import type { ReactElement } from "react";
import { useTranslation } from "react-i18next";

import { PageSkeleton } from "../../components/PageSkeleton.js";
import { EmptyState, ErrorState } from "../../components/StateBlock.js";
import { StatusTag } from "../../components/StatusTag.js";
import { toFriendlyError } from "../../lib/errors.js";
import { getFlags } from "../../lib/queries/finance.js";

export default function FlagsPage(): ReactElement {
  const { t } = useTranslation();

  const flags = useQuery({
    queryKey: ["feature-flags"],
    queryFn: getFlags,
  });

  if (flags.isPending) {
    return <PageSkeleton />;
  }

  if (flags.isError) {
    return <ErrorState error={toFriendlyError(flags.error)} onRetry={() => void flags.refetch()} />;
  }

  if (flags.data.length === 0) {
    return (
      <EmptyState
        title={t("flags.noFlags")}
        hint={t("flags.noFlagsHint")}
        action={{ label: t("app.retry"), onClick: () => void flags.refetch() }}
      />
    );
  }

  return (
    <div className="page">
      <header className="page__header">
        <h1>{t("nav.flags")}</h1>
      </header>

      {/* Said up front rather than left to be discovered, because a dead toggle during an incident is how an
          operator loses trust in the whole console. */}
      <Alert type="info" showIcon message={t("flags.readOnlyNotice")} />

      <Card>
        <Table
          rowKey="flag_key"
          dataSource={[...flags.data]}
          pagination={false}
          scroll={{ x: true }}
          columns={[
            {
              title: t("flags.key"),
              dataIndex: "flag_key",
              key: "flag_key",
              render: (key: string) => <code>{key}</code>,
            },
            {
              title: t("flags.state"),
              key: "state",
              render: (_value: unknown, row: (typeof flags.data)[number]) => (
                <StatusTag
                  label={row.value === true || isEnabled(row.value) ? t("status.active") : t("status.inactive")}
                  tone={row.value === true || isEnabled(row.value) ? "success" : "neutral"}
                />
              ),
            },
            {
              title: t("flags.value"),
              dataIndex: "value",
              key: "value",
              // The raw document, verbatim. An operator debugging targeting needs the shape that is actually
              // stored, not a summary that could be wrong in a way the stored value is not.
              render: (value: unknown) => (
                <code className="flags__value">{JSON.stringify(value, null, 2)}</code>
              ),
            },
          ]}
        />
      </Card>
    </div>
  );
}

/**
 * True when a flag's `value` document says it is on.
 *
 * Two shapes reach this screen: the bare boolean `true`, and a targeting document whose `enabled` field
 * carries the switch. Both are real - `feature_flags.value` is an unconstrained `jsonb` - so both are read,
 * and anything else is treated as off rather than guessed at.
 */
function isEnabled(value: unknown): boolean {
  if (typeof value === "object" && value !== null) {
    const enabled = (value as Record<string, unknown>)["enabled"];
    return enabled === true;
  }
  return false;
}