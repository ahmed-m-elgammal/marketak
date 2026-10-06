/**
 * `features/merchants/VendorDeleteDialog` - A4.3.
 *
 * ## `p_reason` is required in the dialog, not just in the schema
 *
 * The RPC raises `REASON_REQUIRED` for an empty reason, so the schema already enforces it. But a dialog that
 * lets an operator type nothing and then shows an error *after* they have committed to deleting something is a
 * bad interaction - the moment of commitment is when the reason should be asked for and the reason field is
 * exactly that moment. So the field is validated here and the button is disabled until it has content.
 *
 * ## Restore needs a reason too
 *
 * The plan said "`p_reason` is mandatory" under the delete bullet, and read that as delete only.
 * `admin_restore_vendor_v1(p_id, p_reason)` requires it as well, and it is the same argument on the same audit
 * trail. Restoring is an editorial decision - someone judged a deletion to have been wrong - so the reason
 * matters at least as much.
 *
 * ## What each action actually does, stated in the dialog
 *
 * The two differ in a way that is easy to get wrong and expensive when you do. Deleting sets `deleted_at` and
 * `is_active = false`. Restoring clears `deleted_at` and sets `is_active = true` but **deliberately leaves
 * `is_approved` alone** - so a restored merchant is still invisible to customers until it is separately
 * approved. The restore dialog says so, because "restored" that leaves a merchant unpublished is a surprise.
 */

import { useMutation, useQueryClient } from "@tanstack/react-query";
import { Alert, Form, Input, Modal } from "antd";

import { InlineError } from "../../components/StateBlock.js";
import { useState } from "react";
import type { ReactElement } from "react";
import { useTranslation } from "react-i18next";

import { toFriendlyError } from "../../lib/errors.js";
import { deleteVendor, restoreVendor, type VendorRow } from "../../lib/queries/vendors.js";

export interface VendorDeleteDialogProps {
  readonly vendor: VendorRow;
  readonly open: boolean;
  readonly onClose: () => void;
}

export function VendorDeleteDialog({
  vendor,
  open,
  onClose,
}: VendorDeleteDialogProps): ReactElement {
  return (
    <VendorReasonDialog
      vendor={vendor}
      open={open}
      onClose={onClose}
      mode="delete"
      titleKey="vendor.deleteTitle"
      bodyKey="vendor.deleteBody"
      confirmKey="vendor.delete"
      run={async (reason: string) => await deleteVendor(vendor.id, reason)}
      danger
    />
  );
}

export function VendorRestoreDialog(props: VendorDeleteDialogProps): ReactElement {
  const { vendor, open, onClose } = props;
  return (
    <VendorReasonDialog
      vendor={vendor}
      open={open}
      onClose={onClose}
      mode="restore"
      titleKey="vendor.restoreTitle"
      bodyKey="vendor.restoreBody"
      confirmKey="vendor.restore"
      run={async (reason: string) => await restoreVendor(vendor.id, reason)}
      danger={false}
    />
  );
}

function VendorReasonDialog({
  vendor,
  open,
  onClose,
  mode,
  titleKey,
  bodyKey,
  confirmKey,
  run,
  danger,
}: VendorDeleteDialogProps & {
  readonly mode: "delete" | "restore";
  readonly titleKey: string;
  readonly bodyKey: string;
  readonly confirmKey: string;
  readonly run: (reason: string) => Promise<void>;
  readonly danger: boolean;
}): ReactElement {
  const { t } = useTranslation();
  const queryClient = useQueryClient();
  const [reason, setReason] = useState("");

  /*
   * Cleared when the dialog opens, not on close.
   *
   * Leaving the previous reason in the box is how "removed duplicate listing" ends up recorded against an
   * unrelated merchant, and the reason is the audit trail - it has to belong to the action it documents.
   */
  const [openedFor, setOpenedFor] = useState<string | null>(null);
  if (open && openedFor !== vendor.id) {
    setOpenedFor(vendor.id);
    setReason("");
  }

  const mutation = useMutation({
    mutationFn: run,
    onSuccess: async () => {
      await queryClient.invalidateQueries({ queryKey: ["vendors"] });
      await queryClient.invalidateQueries({ queryKey: ["vendor", vendor.id] });
      onClose();
    },
  });

  // Whitespace is not a reason. `btrim(p_reason) = ''` is what the RPC checks, so the button follows the same
  // rule rather than a stricter or looser one.
  const trimmed = reason.trim();
  const canSubmit = trimmed !== "" && !mutation.isPending;

  return (
    <Modal
      open={open}
      title={t(titleKey, { name: vendor.name })}
      okText={t(confirmKey)}
      okButtonProps={{ danger, disabled: !canSubmit }}
      cancelText={t("vendor.cancel")}
      // `confirmLoading` rather than a custom spinner: antd then disables both buttons, which stops a
      // double-submit from racing into `ALREADY_DELETED`.
      confirmLoading={mutation.isPending}
      onOk={() => mutation.mutate(trimmed)}
      onCancel={onClose}
      destroyOnHidden
    >
      <p className="dialog__body">{t(bodyKey, { name: vendor.name })}</p>

      {mode === "restore" ? (
        <Alert type="info" showIcon message={t("vendor.restoreBody", { name: vendor.name })} />
      ) : null}

      <Form layout="vertical" className="dialog__form">
        <Form.Item
          label={t("vendor.reasonLabel")}
          // Required in the form as well as on the button, so the operator is told *why* the button is disabled
          // rather than finding it unresponsive.
          required
          extra={t("vendor.reasonHint")}
        >
          <Input.TextArea
            value={reason}
            onChange={(event) => setReason(event.target.value)}
            placeholder={t("vendor.reasonPlaceholder")}
            aria-label={t("vendor.reasonLabel")}
            rows={3}
            autoFocus
          />
        </Form.Item>
      </Form>

      {/*
        `InlineError` rather than a hand-rolled Alert, so the code travels with the sentence in one place.
        It matters most for `ALREADY_DELETED` and `NOT_DELETED`: both mean this screen's state is stale, and an
        operator who sees only "something went wrong" will click the same button again.
      */}
      {mutation.isError ? <InlineError error={toFriendlyError(mutation.error)} /> : null}
    </Modal>
  );
}