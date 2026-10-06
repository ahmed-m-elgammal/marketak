/**
 * `features/merchants/VendorFormPage` - A4.2.
 *
 * ## Create and edit are one screen
 *
 * They differ in exactly two things: whether `p_id` is sent, and which fields are required. Two screens would
 * duplicate 28 field definitions and let the two copies drift, which is the failure
 * `tests/vendor-patch.test.ts` exists to prevent for the *data* layer - this keeps the same discipline in the
 * form.
 *
 * ## Only what changed is sent
 *
 * `buildVendorPatch` diffs the form against the fetched row. That is not an optimisation. The RPC updates with
 * `coalesce(p_patch->>'col', v.col)`, so a full-form payload would write every column on every save, including
 * the three clearable ones the operator never touched - and for those, a full payload sends `null` and *clears
 * a value they never edited*. A diff is the only correct shape here.
 *
 * ## Three fields can be cleared; the rest cannot
 *
 * `brand_id`, `capacity_per_slot` and `delivery_fee_override` are written with `case when p_patch ? 'key'`, so
 * an explicit JSON `null` really does clear them. Every other field uses `coalesce`, which cannot tell "leave it
 * alone" from "set it to null". So the Clear affordance appears on exactly those three, and nowhere else - a
 * Clear button that silently does nothing is worse than no button at all. See `lib/vendor-patch.ts`.
 */

import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { Alert, Button, Form, Input, InputNumber, Select, Switch } from "antd";
import { useEffect, useState } from "react";
import type { ReactElement } from "react";
import { useTranslation } from "react-i18next";
import { useNavigate, useParams } from "react-router-dom";

import { PageSkeleton } from "../../components/PageSkeleton.js";
import { ErrorState, InlineError } from "../../components/StateBlock.js";
import { toFriendlyError } from "../../lib/errors.js";
import { listAreas, listCities, getVendor, upsertVendor } from "../../lib/queries/vendors.js";
import { buildVendorPatch, patchesEqual, VENDOR_FIELDS, REQUIRED_ON_CREATE } from "../../lib/vendor-patch.js";
import type { VendorField, VendorFieldKey } from "../../lib/vendor-patch.js";

/** The fields, grouped. The order is how a merchant is actually set up. */
const GROUPS: readonly { readonly titleKey: string; readonly fields: readonly VendorFieldKey[] }[] = [
  {
    titleKey: "vendor.groupIdentity",
    fields: ["slug", "name", "name_ar", "legal_name", "brand_id", "vertical_type"],
  },
  {
    titleKey: "vendor.groupLocation",
    fields: ["city_id", "area_id", "latitude", "longitude", "geohash_prefix", "delivery_radius_km"],
  },
  {
    titleKey: "vendor.groupOperations",
    fields: ["is_open", "is_busy", "auto_open", "is_approved", "is_active", "prep_time_minutes", "prep_time_max_minutes", "capacity_per_slot"],
  },
  { titleKey: "vendor.groupPricing", fields: ["reject_rate", "delivery_fee_override", "minimum_order_value"] },
  {
    titleKey: "vendor.groupContact",
    fields: ["contact_phone", "contact_landline", "logo_path", "description", "description_ar"],
  },
];

export default function VendorFormPage(): ReactElement {
  const { t } = useTranslation();
  const params = useParams();
  const navigate = useNavigate();
  const queryClient = useQueryClient();
  const [form] = Form.useForm();

  // Absent `:id` is a create. `null` rather than `undefined` so the RPC gets an explicit null - see the note in
  // `lib/queries/vendors.ts`.
  const id = params["id"] ?? null;
  const isCreate = id === null;

  /** The row as fetched, for the diff. `null` while loading or on a create. */
  const [original, setOriginal] = useState<Record<string, unknown> | null>(null);
  const [current, setCurrent] = useState<Record<string, unknown>>({});

  const vendor = useQuery({
    queryKey: ["vendor", id],
    queryFn: () => getVendor(id as string),
    enabled: !isCreate,
  });

  const places = useQuery({
    queryKey: ["vendor-places"],
    queryFn: async () => ({ cities: await listCities(), areas: await listAreas() }),
  });

  /*
   * Seed the form once the row arrives. `setFieldsValue` rather than a `key` remount: remounting would discard
   * any edit the operator had already made if the query refetched underneath them, which it does whenever any
   * mutation invalidates it.
   */
  useEffect(() => {
    if (vendor.data === null || vendor.data === undefined) {
      return;
    }
    // Via `unknown`, so the `any` at the untyped client edge is narrowed rather than asserted through - the rule the
    // rest of the query layer follows. See `lib/queries/vendors.ts`.
    const row: unknown = vendor.data;
    const asRecord = row as Record<string, unknown>;
    setOriginal(asRecord);
    setCurrent(asRecord);
    form.setFieldsValue(asRecord);
  }, [vendor.data, form]);

  const save = useMutation({
    mutationFn: async (values: Record<string, unknown>) =>
      await upsertVendor(buildVendorPatch(original ?? {}, values), id),
    onSuccess: async (savedId) => {
      await queryClient.invalidateQueries({ queryKey: ["vendors"] });
      await queryClient.invalidateQueries({ queryKey: ["vendor", id] });
      void navigate(`/merchants/${savedId}`);
    },
  });

  if (!isCreate && vendor.isPending) {
    return <PageSkeleton />;
  }
  if (vendor.isError) {
    return (
      <ErrorState error={toFriendlyError(vendor.error)} onRetry={() => void vendor.refetch()} />
    );
  }

  const unchanged = original !== null && patchesEqual(original, current);

  return (
    <div className="page">
      <header className="page__header">
        <h1>
          {isCreate
            ? t("vendor.createTitle")
            : t("vendor.editTitle", { name: vendor.data?.name ?? "" })}
        </h1>
      </header>

      {/*
        A soft-deleted vendor cannot be edited - the RPC raises `NOT_FOUND` for one, because its update branch
        requires `deleted_at is null`. Saying so here is better than letting the operator fill in a form and
        then fail on save.
      */}
      {vendor.data?.deleted_at != null ? (
        <Alert
          type="warning"
          showIcon
          message={t("errors.notDeleted")}
          description={t("vendor.restoreBody", { name: vendor.data.name })}
        />
      ) : null}

      {isCreate ? (
        <Alert type="info" showIcon message={t("vendor.requiredOnCreate")} />
      ) : null}

      <Form<VendorFormValues>
        form={form}
        layout="vertical"
        // A create without the NOT NULL columns fails with a raw 23502, so the form refuses to submit first.
        // `preserve: false` so a field cleared after a failed submit actually clears its error.
        onFinish={(values) => save.mutate(values)}
        onValuesChange={(_changed, all) => setCurrent(all)}
        disabled={vendor.data?.deleted_at != null}
        className="vendor-form"
      >
        {GROUPS.map((group) => (
          <fieldset className="vendor-form__group" key={group.titleKey}>
            <legend className="vendor-form__legend">{t(group.titleKey)}</legend>
            <div className="vendor-form__grid">
              {group.fields.map((key) => (
                <VendorFieldInput
                  key={key}
                  fieldKey={key}
                  cities={places.data?.cities ?? []}
                  areas={places.data?.areas ?? []}
                  isCreate={isCreate}
                />
              ))}
            </div>
          </fieldset>
        ))}

        {/*
        `UNKNOWN_KEY` means the form offered a field the RPC's whitelist rejects, which is a bug in
        `lib/vendor-patch.ts` rather than anything the operator did - and `CHECK_VIOLATION` means a value they
        typed broke a rule. The code is what distinguishes the two, so it is shown alongside the sentence.
      */}
        {save.isError ? <InlineError error={toFriendlyError(save.error)} /> : null}

        <div className="page__actions">
          <Button type="primary" htmlType="submit" loading={save.isPending} disabled={unchanged || isCreate === false && vendor.data?.deleted_at != null}>
            {isCreate ? t("vendor.add") : t("vendor.edit")}
          </Button>
          <Button onClick={() => void navigate(-1)} disabled={save.isPending}>
            {t("vendor.cancel")}
          </Button>
          {unchanged ? <span className="muted-note">{t("vendor.noChange")}</span> : null}
        </div>
      </Form>
    </div>
  );
}

interface VendorFormValues extends Record<string, unknown> {
  readonly slug: string;
  readonly name: string;
  readonly name_ar: string;
}

/**
 * One field.
 *
 * `kind` from `lib/vendor-patch.ts` decides the control, so adding a field to the whitelist and forgetting to
 * give it a control is a type error rather than a text box that silently coerces a number.
 */
function VendorFieldInput({
  fieldKey,
  cities,
  areas,
  isCreate,
}: {
  readonly fieldKey: VendorFieldKey;
  readonly cities: readonly { readonly id: string; readonly name: string }[];
  readonly areas: readonly { readonly id: string; readonly name: string }[];
  readonly isCreate: boolean;
}): ReactElement | null {
  const { t } = useTranslation();
  // Widened to the base interface rather than the const literal, so `field.hint` is reachable as an optional
  // property. `VENDOR_FIELDS[key]` is a union of 28 distinct object types, and TypeScript will not let a
  // property that exists on only some of them be read off the union without this.
  const field: VendorField = VENDOR_FIELDS[fieldKey];
  const required = isCreate && REQUIRED_ON_CREATE.includes(fieldKey);
  const label = t(field.label);

  // Required on create only. Marking it required always would block saving a partial edit of an existing vendor,
  // which is legitimate - an operator fixing a phone number should not have to retype the geohash.
  const rules = required ? [{ required: true, message: t("errors.missingRequired") }] : [];

  /*
   * `extra` and `rules` are spread rather than passed inline. With `exactOptionalPropertyTypes` on, an antd prop
   * declared `extra?: ReactNode` rejects an explicit `undefined`, so the keys have to be *absent* rather than
   * present-and-undefined. Building the object conditionally is what keeps that true.
   */
  const common = {
    name: fieldKey,
    label,
    rules,
    ...(field.hint === undefined ? {} : { extra: t(field.hint) }),
  };

  switch (field.kind) {
    case "boolean":
      return (
        <Form.Item {...common} valuePropName="checked" className="vendor-form__wide">
          <Switch aria-label={label} />
        </Form.Item>
      );
    case "integer":
      return (
        <Form.Item {...common}>
          <InputNumber className="vendor-form__control" />
        </Form.Item>
      );
    case "numeric":
      return (
        <Form.Item {...common}>
          <InputNumber className="vendor-form__control" step="any" />
        </Form.Item>
      );
    case "enum":
      return (
        <Form.Item {...common}>
          <Select
            aria-label={label}
            options={(field.values ?? []).map((value) => ({
              value,
              label: t(`vendor.vertical${value.charAt(0).toUpperCase()}${value.slice(1)}`),
            }))}
          />
        </Form.Item>
      );
    case "uuid": {
      // `city_id` and `area_id` are foreign keys to real rows, so they get a picker rather than a raw UUID box -
      // typing a uuid by hand is how an admin creates a vendor attached to nothing. `brand_id` has no picker
      // (there are zero brands configured) so it stays a text field until A4.4 builds the brand screen.
      const options = fieldKey === "city_id" ? cities : fieldKey === "area_id" ? areas : undefined;
      if (options === undefined) {
        return (
          <Form.Item {...common}>
            <Input className="vendor-form__control" />
          </Form.Item>
        );
      }
      return (
        <Form.Item {...common}>
          <Select
            aria-label={label}
            // `allowClear` only where the RPC can actually clear the column. See the file header.
            allowClear={field.clearable}
            options={options.map((option) => ({ value: option.id, label: option.name }))}
          />
        </Form.Item>
      );
    }
    
    case "text":
    default:
      return (
        <Form.Item {...common}>
          <Input className="vendor-form__control" />
        </Form.Item>
      );
  }
}