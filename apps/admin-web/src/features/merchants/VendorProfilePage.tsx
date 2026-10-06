/**
 * `features/merchants/VendorProfilePage` - A4.1's other half.
 *
 * The list can open a merchant, so something has to be there. This is the summary plus the two destructive
 * actions; the catalog drill-down (menu, cuisine, schedule, staff) is A4.4–A4.6 and lands on this route as
 * tabs are added rather than as a rewrite.
 *
 * ## Where the delete and restore buttons live
 *
 * Only on the profile, never in the list. A list is for scanning and comparing, and a destructive control in
 * every row is how one gets clicked by accident on a tablet. A profile is a deliberate destination, which is
 * the right place to be able to delete something.
 */

import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { Alert, Button, Descriptions, Result, Space } from "antd";
import { useState } from "react";
import type { ReactElement } from "react";
import { useTranslation } from "react-i18next";
import { useNavigate, useParams } from "react-router-dom";

import { PageSkeleton } from "../../components/PageSkeleton.js";
import { StatusTag } from "../../components/StatusTag.js";
import { intlTagFor } from "../../i18n/index.js";
import { useLocale } from "../../i18n/use-locale.js";
import { getVendor, type VendorDetail } from "../../lib/queries/vendors.js";
import { VendorDeleteDialog, VendorRestoreDialog } from "./VendorDeleteDialog.jsx";

export default function VendorProfilePage(): ReactElement {
  const { t } = useTranslation();
  const intl = intlTagFor(useLocale());
  const params = useParams();
  const navigate = useNavigate();
  const queryClient = useQueryClient();
  const id = params["id"];

  const [dialog, setDialog] = useState<"delete" | "restore" | null>(null);

  const vendor = useQuery({
    queryKey: ["vendor", id],
    queryFn: () => getVendor(id as string),
    enabled: typeof id === "string",
  });

  const refresh = useMutation({
    mutationFn: async () => {
      await queryClient.invalidateQueries({ queryKey: ["vendor", id] });
    },
  });

  if (vendor.isPending) {
    return <PageSkeleton />;
  }

  // `vendor.data` is `VendorDetail | null | undefined` - React Query types the value as possibly undefined
  // even after `isPending` is false, because a disabled query never resolves. Narrowed here once so every use
  // below is on a defined row.
  const row: VendorDetail | null | undefined = vendor.data;
  if (row === null || row === undefined) {
    return (
      <Result
        status="404"
        title={t("errors.notFound")}
        subTitle={t("errors.notFoundHint")}
        extra={
          <Button type="primary" onClick={() => void navigate("/merchants")}>
            {t("vendor.title")}
          </Button>
        }
      />
    );
  }

  const deleted = row.deleted_at !== null;
  const date = new Intl.DateTimeFormat(intl, { dateStyle: "medium", timeStyle: "short" });

  return (
    <div className="page">
      <header className="page__header">
        <h1>{row.name}</h1>
        <Space>
          <Button href={`/merchants/${row.id}/edit`}>{t("vendor.edit")}</Button>
          {deleted ? (
            <Button danger={false} onClick={() => setDialog("restore")}>
              {t("vendor.restore")}
            </Button>
          ) : (
            <Button danger onClick={() => setDialog("delete")}>
              {t("vendor.delete")}
            </Button>
          )}
        </Space>
      </header>

      {deleted ? (
        // The state changes what is possible, so it is stated at the top rather than discovered on the first
        // failed save. `NOT_FOUND` from the upsert RPC is a confusing error for "you cannot edit a deleted row".
        <Alert
          type="warning"
          showIcon
          message={t("vendor.deleteTitle", { name: row.name })}
          description={`${t("vendor.deletedOn")} ${date.format(new Date(row.deleted_at))}`}
        />
      ) : null}

      <section className="section">
        <div className="section__head">
          <h2 className="section__heading">{t("vendor.groupIdentity")}</h2>
        </div>
        <Descriptions column={2} size="small" className="detail">
          {/*
            `dir="rtl"` on the *value*, not the `Descriptions.Item`: antd's item takes no `dir` prop, and putting
            it on the item does not reach the text node anyway. The Arabic name needs its own direction or it
            renders with the browser's bidi reordering and reads backwards.
          */}
          <Descriptions.Item label={t("vendor.nameAr")}>
            <span dir="rtl">{row.name_ar}</span>
          </Descriptions.Item>
          <Descriptions.Item label={t("vendor.slug")}>{row.slug}</Descriptions.Item>
          <Descriptions.Item label={t("vendor.legalName")}>{row.legal_name ?? "—"}</Descriptions.Item>
          <Descriptions.Item label={t("vendor.verticalType")}>{row.vertical_type}</Descriptions.Item>
        </Descriptions>
      </section>

      <section className="section">
        <div className="section__head">
          <h2 className="section__heading">{t("vendor.groupOperations")}</h2>
        </div>
        <Descriptions column={3} size="small" className="detail">
          <Descriptions.Item label={t("common.status")}>
            <Space size={4} wrap>
              <StatusTag
                label={row.is_approved ? t("status.approved") : t("status.pendingApproval")}
                tone={row.is_approved ? "success" : "warning"}
              />
              <StatusTag
                label={row.is_open ? t("status.open") : t("status.closed")}
                tone={row.is_open ? "info" : "neutral"}
              />
            </Space>
          </Descriptions.Item>
          <Descriptions.Item label={t("vendor.prepTimeMin")}>
            {row.prep_time_minutes}–{row.prep_time_max_minutes} min
          </Descriptions.Item>
          <Descriptions.Item label={t("vendor.deliveryRadius")}>{row.delivery_radius_km} km</Descriptions.Item>
        </Descriptions>
      </section>

      <section className="section">
        <div className="section__head">
          <h2 className="section__heading">{t("vendor.groupContact")}</h2>
        </div>
        <Descriptions column={2} size="small" className="detail">
          <Descriptions.Item label={t("vendor.contactPhone")}>{row.contact_phone ?? "—"}</Descriptions.Item>
          <Descriptions.Item label={t("vendor.contactLandline")}>{row.contact_landline ?? "—"}</Descriptions.Item>
          <Descriptions.Item label={t("vendor.description")} span={2}>
            {row.description ?? "—"}
          </Descriptions.Item>
        </Descriptions>
      </section>

      {dialog === "delete" ? (
        <VendorDeleteDialog
          vendor={row}
          open
          onClose={() => setDialog(null)}
        />
      ) : null}
      {dialog === "restore" ? (
        <VendorRestoreDialog
          vendor={row}
          open
          onClose={() => {
            setDialog(null);
            void refresh.mutateAsync();
          }}
        />
      ) : null}
    </div>
  );
}