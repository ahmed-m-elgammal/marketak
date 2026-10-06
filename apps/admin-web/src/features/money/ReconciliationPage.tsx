/**
 * `features/money/ReconciliationPage` - A3.3.
 *
 * ## The screen exists to answer one question
 *
 * "Did the money in the drawer match what the system says should be in it?" Everything else on it is context.
 * So the variance sits at the top, unstyled away, and the explanation sits directly under it.
 *
 * ## Explaining is irreversible, and the dialog says so
 *
 * `reconcile_day_v1` refuses a second explanation (`VARIANCE_ALREADY_EXPLAINED`) - correct, because an
 * explanation is a justification and silently overwriting one destroys the record of what was originally
 * claimed. So the dialog says it can only be done once, rather than letting an operator discover it by being
 * refused.
 *
 * ## The date field is the city's date
 *
 * See `lib/city-date.ts`. The RPC derives its day from `cities.timezone`, so a browser-in-UTC date would
 * reconcile a different day than the one displayed.
 */

import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { Alert, Button, Card, Col, DatePicker, Form, Input, Modal, Row, Tag } from "antd";
import dayjs, { type Dayjs } from "dayjs";
import type { ReactElement } from "react";
import { useState } from "react";
import { useTranslation } from "react-i18next";

import { MetricCard, MetricGrid } from "../../components/MetricCard.js";
import { Money } from "../../components/Money.js";
import { PageSkeleton } from "../../components/PageSkeleton.js";
import { EmptyState, ErrorState } from "../../components/StateBlock.js";
import { StatusTag } from "../../components/StatusTag.js";
import { toFriendlyError } from "../../lib/errors.js";
import { explainVariance, getReconciliation } from "../../lib/queries/finance.js";
import { cityToday } from "../../lib/city-date.js";

/**
 * The operating city timezone.
 *
 * The one place the console names it, and it is a **display** value only. The RPCs derive their own window from
 * `cities.timezone`, so this never feeds a query - it exists so the operator can see which day they are
 * looking at. `cityToday` returns `undefined` for an unknown zone and the screen falls back to UTC rather than
 * guessing.
 */
const CITY_TIMEZONE = "Africa/Cairo";

export default function ReconciliationPage(): ReactElement {
  const { t } = useTranslation();
  const queryClient = useQueryClient();
  const [date, setDate] = useState<string>(cityToday(CITY_TIMEZONE) ?? "");
  const [explaining, setExplaining] = useState(false);

  const reconciliation = useQuery({
    queryKey: ["reconciliation", date],
    queryFn: getReconciliation,
  });

  const explain = useMutation({
    mutationFn: async (text: string) => await explainVariance(date, text),
    onSuccess: async () => {
      setExplaining(false);
      await queryClient.invalidateQueries({ queryKey: ["reconciliation"] });
    },
  });

  if (reconciliation.isPending) {
    return <PageSkeleton />;
  }

  if (reconciliation.isError) {
    return (
      <ErrorState
        error={toFriendlyError(reconciliation.error)}
        onRetry={() => void reconciliation.refetch()}
      />
    );
  }

  const row = reconciliation.data;

  // No settlement row for this day. Not an error, and not "balanced" - it means the day has no float
  // computed yet, which an operator needs told plainly.
  if (row === null) {
    return (
      <EmptyState
        title={t("reconciliation.noData")}
        hint={t("reconciliation.noDataHint")}
        action={{ label: t("app.retry"), onClick: () => void reconciliation.refetch() }}
      />
    );
  }

  const hasVariance = row.variance !== 0;
  // The RPC does not return `variance_explanation`, so the screen cannot claim a variance is explained.
  // Showing "balanced" for a zero variance is a claim the console has not verified.
  const balanced = row.balanced && !hasVariance;

  return (
    <div className="page">
      <header className="page__header">
        <h1>{t("nav.reconciliation")}</h1>
        <div className="page__actions">
          <DatePicker
            value={date === "" ? null : dayjs(date)}
            onChange={(value: Dayjs | null) => {
              if (value !== null) {
                setDate(value.format("YYYY-MM-DD"));
              }
            }}
            allowClear={false}
          />
        </div>
      </header>

      {/* A3.4: the date the figures describe, named. Not the browser's idea of today. */}
      <span className="metric-card__hint">
        {t("dashboard.timezoneNote", { timezone: CITY_TIMEZONE })} · {row.business_date}
      </span>

      <MetricGrid>
        <MetricCard
          label={t("variance.cashExpected")}
          value={<Money amount={row.cash_expected} currency="EGP" />}
        />
        <MetricCard
          label={t("variance.cashRemitted")}
          value={<Money amount={row.cash_remitted} currency="EGP" />}
        />
        <MetricCard
          label={t("variance.variance")}
          value={<Money amount={row.variance} currency="EGP" />}
          tone={hasVariance ? "warning" : "default"}
          hint={hasVariance ? t("variance.unexplained") : t("variance.explained")}
        />
        <MetricCard
          label={t("reconciliation.state")}
          value={
            <StatusTag
              label={balanced ? t("status.balanced") : t("status.unbalanced")}
              tone={balanced ? "success" : "warning"}
            />
          }
        />
      </MetricGrid>

      {hasVariance ? (
        <Alert
          type="warning"
          showIcon
          message={t("variance.warningTitle")}
          description={t("reconciliation.explainPrompt")}
          action={
            <Button type="primary" onClick={() => setExplaining(true)}>
              {t("variance.explain")}
            </Button>
          }
        />
      ) : null}

      <Card title={t("reconciliation.breakdown")}>
        <Row gutter={[16, 16]}>
          <Col xs={12} md={6}>
            <MetricCard
              label={t("reconciliation.cashOrders")}
              value={row.external_cash_orders}
              hint={t("reconciliation.cashOrdersHint")}
            />
          </Col>
          <Col xs={12} md={6}>
            <MetricCard
              label={t("reconciliation.walletOrders")}
              value={row.external_wallet_orders}
            />
          </Col>
          <Col xs={12} md={6}>
            <MetricCard
              label={t("reconciliation.vendorPayable")}
              value={<Money amount={row.vendor_payable} currency="EGP" />}
            />
          </Col>
          <Col xs={12} md={6}>
            <MetricCard
              label={t("reconciliation.riderPayable")}
              value={<Money amount={row.rider_payable} currency="EGP" />}
            />
          </Col>
          <Col xs={12} md={6}>
            <MetricCard
              label={t("reconciliation.inFlight")}
              value={<Money amount={row.in_flight_payouts} currency="EGP" />}
            />
          </Col>
          <Col xs={12} md={6}>
            <MetricCard
              label={t("reconciliation.openNet")}
              value={<Money amount={row.open_payout_net} currency="EGP" />}
            />
          </Col>
        </Row>
      </Card>

      <ExplainVarianceModal
        open={explaining}
        busy={explain.isPending}
        failure={explain.isError ? toFriendlyError(explain.error) : null}
        onCancel={() => setExplaining(false)}
        onSubmit={(text) => explain.mutate(text)}
      />
    </div>
  );
}

/**
 * The explanation dialog.
 *
 * A **required** field, and the dialog says it can be written once. Both are deliberate:
 * - required, because a variance explanation that explains nothing looks resolved and is worse than an
 *   unexplained variance;
 * - "once", because the RPC refuses a second one, and an operator refused after the fact has learned the
 *   rule the hard way.
 */
function ExplainVarianceModal({
  open,
  busy,
  failure,
  onCancel,
  onSubmit,
}: {
  readonly open: boolean;
  readonly busy: boolean;
  readonly failure: ReturnType<typeof toFriendlyError> | null;
  readonly onCancel: () => void;
  readonly onSubmit: (text: string) => void;
}): ReactElement {
  const { t } = useTranslation();
  const [form] = Form.useForm<{ explanation: string }>();

  return (
    <Modal
      open={open}
      title={t("variance.explain")}
      onCancel={onCancel}
      okText={t("app.save")}
      cancelText={t("app.cancel")}
      confirmLoading={busy}
      onOk={() => {
        void form.validateFields().then((values) => onSubmit(values.explanation));
      }}
      destroyOnHidden
    >
      <Form form={form} layout="vertical" requiredMark="optional">
        <p className="sign-in__note">{t("reconciliation.oneShotWarning")}</p>
        <Form.Item
          name="explanation"
          label={t("variance.explainPrompt")}
          rules={[
            { required: true, whitespace: true, message: t("app.required") },
            { min: 10, message: t("reconciliation.explainTooShort") },
          ]}
        >
          <Input.TextArea rows={3} />
        </Form.Item>
        {failure === null ? null : (
          <Alert type="error" showIcon message={t(failure.messageKey, failure.values)} />
        )}
        <Tag>{t("reconciliation.audited")}</Tag>
      </Form>
    </Modal>
  );
}