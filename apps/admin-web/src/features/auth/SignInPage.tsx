/**
 * `features/auth/SignInPage` - the only way into the console.
 *
 * ## One button, and there will not be a second
 *
 * `signInWithGoogle()` takes no arguments, so email, password and phone OTP are not one flag away - they are
 * absent from the codebase. That is constitution rule 18 as scoped for internal staff: this is an operator
 * tool, and the credentials it needs are identities that already exist, not ones the console creates.
 *
 * ## Why the page explains itself before the button
 *
 * constitution rule 18 also says the gate must hold "in the RPC, in RLS, and in the app - one layer is not
 * enough". The RPC and RLS layers already reject a non-admin regardless of what this page does. So the page's
 * job is not to be the security boundary - it is to tell an operator *why* a signed-in person landed on a
 * 403, which is the one thing the server cannot explain.
 *
 * ## No form, no email field
 *
 * There is deliberately nothing to type. A sign-in form invites the reader to think they can authenticate
 * with an email and a password, which is both untrue here and the single most common way an admin console
 * becomes a phishing target.
 */

import { Button, Result, Typography } from "antd";
import { useQueryClient } from "@tanstack/react-query";
import GoogleOutlined from "@ant-design/icons/GoogleOutlined";
import type { ReactElement } from "react";
import { useState } from "react";
import { useTranslation } from "react-i18next";
import { Navigate } from "react-router-dom";

import { EmptyState, ErrorState } from "../../components/StateBlock.js";
import { LocaleSwitch } from "../../components/LocaleSwitch.js";
import { AUTH_CALLBACK_PATH, authError, signInWithGoogle } from "../../lib/auth.js";
import { SESSION_QUERY_KEY, useAuthStatus } from "../../lib/use-auth.js";

/**
 * The URL Google returns to.
 *
 * Built from `window.location.origin` rather than hard-coded to `localhost:5173`, because the same build is
 * served from a preview domain and a production domain and a hard-coded origin sends the operator to
 * someone else's machine after sign-in. It must still be on Supabase's allowlist for that origin.
 */
function callbackUrl(): string {
  return `${window.location.origin}${AUTH_CALLBACK_PATH}`;
}

export default function SignInPage(): ReactElement {
  const { t } = useTranslation();
  const status = useAuthStatus();
  const queryClient = useQueryClient();
  const [failure, setFailure] = useState<unknown>(null);
  const [submitting, setSubmitting] = useState(false);

  // Already signed in and an admin: nothing to do here. Without this the page is reachable from the address
  // bar and shows a button that would sign you out and back in for no reason.
  if (status === "admin") {
    return <Navigate to="/" replace />;
  }

  // Signed in but not an admin. Explaining it HERE rather than letting the guard bounce them to /403 and back
  // is deliberate: this is the only place that can say "your Google account works, it just is not an admin".
  if (status === "not-admin") {
    return (
      <Result
        status="403"
        title={t("errors.forbiddenTitle")}
        subTitle={t("errors.forbiddenBody")}
      />
    );
  }

  const onSignIn = async (): Promise<void> => {
    setSubmitting(true);
    setFailure(null);
    try {
      await signInWithGoogle(callbackUrl());
      // No navigation here. `signInWithOAuth` sends the browser to Google; when it comes back the provider
      // writes the session into the cache and this page re-renders. Touching the cache directly would
      // render an operator a spinner that never resolves.
      await queryClient.invalidateQueries({ queryKey: SESSION_QUERY_KEY });
    } catch (error) {
      setFailure(error);
    } finally {
      setSubmitting(false);
    }
  };

  if (status === "signed-out" && failure !== null) {
    return <ErrorState error={authError(failure)} onRetry={() => void onSignIn()} />;
  }

  return (
    <div className="sign-in">
      <div className="sign-in__panel">
        {/*
          The language switcher, here as well as in the shell.

          It was originally only in the shell, which meant the FIRST screen an operator ever sees was
          English-only — and Arabic is a launch language. An operator whose only working language is Arabic
          hits a wall before reaching the control that would fix it. `main.tsx` does read `navigator.language`,
          so a browser set to Arabic is served Arabic automatically; the switcher is what covers everyone else.
        */}
        <div className="sign-in__lang">
          <LocaleSwitch />
        </div>

        <Typography.Title level={2}>{t("app.console")}</Typography.Title>
        <Typography.Paragraph type="secondary">{t("auth.signInIntro")}</Typography.Paragraph>

        {status === "signed-out" ? null : <p className="metric-card__hint">{t("app.loading")}</p>}

        <Button
          type="primary"
          size="large"
          icon={<GoogleOutlined />}
          onClick={() => void onSignIn()}
          loading={submitting}
          disabled={status !== "signed-out"}
          className="row-action sign-in__button"
        >
          {t("auth.signInWithGoogle")}
        </Button>

        {/* Rule 5: the failure and the empty state are designed, not implied. */}
        {status === "signed-out" ? (
          <p className="sign-in__note">{t("auth.signInNote")}</p>
        ) : (
          <EmptyState title={t("app.loading")} hint={t("auth.signInChecking")} />
        )}
      </div>
    </div>
  );
}