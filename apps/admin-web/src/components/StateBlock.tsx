/**
 * `components/StateBlock` - the empty and failure states.
 *
 * ## Why one component for both
 *
 * They have the same shape - a title, a sentence, one action - and a shared `state-block` class. What
 * differs is the action, so splitting them would produce two files that are 80% identical, and the 20% is
 * exactly where a bug hides.
 *
 * ## Rule 5, and the part that is easy to skip
 *
 * `admin-console-screens.md` §5 rule 5 says an empty state says *why* it is empty and what to do next. So
 * `EmptyState` requires a `hint` prop; there is no way to render a bare "No data". A list with nothing in it
 * is ambiguous - no orders ever placed, or a filter that excludes everything - and an operator who cannot
 * tell which is stuck looking at the filter.
 */

import { Alert, Button, Result } from "antd";
import type { ReactElement } from "react";
import { useTranslation } from "react-i18next";

import type { FriendlyError } from "../lib/errors.js";

export interface EmptyStateProps {
  /** What is missing, in the operator's words. Not "no data". */
  readonly title: string;
  /** Why it is missing and what to do. Required - see the note above. */
  readonly hint: string;
  /** Optional action. Omitted deliberately when there is nothing useful to do yet. */
  readonly action?: { readonly label: string; readonly onClick: () => void };
}

/**
 * The "nothing here" state.
 *
 * `role="status"` and not `role="alert"`: an empty list is not an error, and announcing it as one makes a
 * screen reader interrupt whatever the operator was doing.
 */
export function EmptyState({ title, hint, action }: EmptyStateProps): ReactElement {
  return (
    <div className="state-block" role="status">
      <p className="state-block__title">{title}</p>
      <p className="state-block__body">{hint}</p>
      {action === undefined ? null : (
        <Button type="primary" onClick={action.onClick} className="row-action">
          {action.label}
        </Button>
      )}
    </div>
  );
}

export interface ErrorStateProps {
  readonly error: FriendlyError;
  /** Re-runs the failed query. Optional so a page with no retry path can still render this. */
  readonly onRetry?: () => void;
}

/**
 * The failure state.
 *
 * ## Why the internal code is offered and not hidden
 *
 * `lib/errors.ts` keeps `FriendlyError.code` even though rule 14 says it must never be *rendered as the
 * message*. Those are different things. The operator gets a sentence in their language; a support engineer
 * gets the code, one click away. Dropping the code would make every support question unanswerable, and
 * showing it instead of the sentence would make the console unusable.
 *
 * So: the sentence by default, the code behind a disclosure.
 */
/**
 * A sentence and its code, for an error that happened **inside** a form or dialog rather than in place of a
 * whole screen.
 *
 * ## Why the code is rendered here
 *
 * `FriendlyError.messageKey` and `.values` produce the sentence; `.code` is the only way to tell
 * `UNKNOWN_KEY` (a form that offered a non-writable field - a bug) from `CHECK_VIOLATION` (a bad value) or
 * `ALREADY_DELETED` (the screen's state is stale). All three render as an `Alert`, and an operator who sees only
 * "This action was refused" cannot tell whether to fix their input or tell an engineer.
 *
 * The code is styled as secondary text rather than an alert title, because it is diagnostic detail next to a
 * sentence a human acts on - not the sentence itself.
 */
export function InlineError({ error }: { readonly error: FriendlyError }): ReactElement {
  const { t } = useTranslation();
  return (
    <Alert
      type="error"
      showIcon
      message={t(error.messageKey, error.values)}
      description={error.code}
      className="inline-error"
    />
  );
}

export function ErrorState({ error, onRetry }: ErrorStateProps): ReactElement {
  const { t } = useTranslation();
  const sentence = t(error.messageKey, error.values);

  return (
  <Result
  status="error"
  title={sentence}
  subTitle={t("app.retry")}
  extra={
  onRetry === undefined ? null : (
  <Button type="primary" onClick={onRetry} className="row-action">
  {t("app.retry")}
  </Button>
  )
      }
    >
      {error.known ? null : (
        <details className="state-block__body">
          {/* `known: false` means our catalogue did not recognise this failure. Surfacing that is more
              useful than hiding it, because it tells an engineer the console met a new code. */}
          <summary>{t("errors.unknownCode", { CODE: error.code })}</summary>
          <code>{error.code}</code>
        </details>
      )}
    </Result>
  );
}